#!/bin/bash

# Outline-v2ray Monitoring Script
# Provides real-time monitoring of users, quotas, and services

set -euo pipefail

# Configuration
CONFIG_DIR="/etc/shadowsocks-libev/config.d"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root"
    exit 1
fi

# Get quota usage for a port
get_quota_usage() {
    local port=$1
    
    # Get quota rules for this port
    local quota_rules=$(iptables -L INPUT -n -v --line-numbers | grep "dpt:$port" | grep quota)
    
    if [[ -z "$quota_rules" ]]; then
        echo "No quota rules found"
        return
    fi
    
    # Extract quota values and usage
    echo "$quota_rules" | while read line; do
        local line_num=$(echo "$line" | awk '{print $1}')
        local bytes=$(echo "$line" | awk '{print $2}')
        local quota=$(echo "$line" | grep -o 'quota [0-9]*' | awk '{print $2}')
        
        if [[ -n "$quota" ]]; then
            local used_gb=$((bytes / 1024 / 1024 / 1024))
            local total_gb=$((quota / 1024 / 1024 / 1024))
            local percentage=$((used_gb * 100 / total_gb))
            
            echo "Port $port: ${used_gb}GB / ${total_gb}GB (${percentage}%)"
        fi
    done
}

# Get service status for a port
get_service_status() {
    local port=$1
    
    if systemctl is-active --quiet "shadowsocks-libev@$port" 2>/dev/null; then
        echo -e "${GREEN}Active${NC}"
    elif systemctl is-failed --quiet "shadowsocks-libev@$port" 2>/dev/null; then
        echo -e "${RED}Failed${NC}"
    else
        echo -e "${YELLOW}Inactive${NC}"
    fi
}

# Get connection count for a port
get_connection_count() {
    local port=$1
    
    local count=$(ss -tuln | grep ":$port " | wc -l)
    echo "$count"
}

# Show detailed user information
show_user_details() {
    local port=$1
    
    echo -e "${CYAN}=== Port $port ===${NC}"
    
    # Service status
    echo -n "Service Status: "
    get_service_status $port
    
    # Quota usage
    echo -n "Quota Usage: "
    get_quota_usage $port
    
    # Connection count
    local connections=$(get_connection_count $port)
    echo "Active Connections: $connections"
    
    # Config file
    local config_file="$CONFIG_DIR/$port.json"
    if [[ -f "$config_file" ]]; then
        echo "Config File: $config_file"
        echo "Config Size: $(ls -lh "$config_file" | awk '{print $5}')"
    else
        echo -e "${RED}Config File: Missing${NC}"
    fi
    
    # UFW rule
    local ufw_rule=$(ufw status numbered 2>/dev/null | grep "SS user $port" || echo "No UFW rule found")
    echo "UFW Rule: $ufw_rule"
    
    echo
}

# Show summary
show_summary() {
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}        Outline-v2ray Status Summary${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo
    
    # Count total users
    local total_users=0
    local active_users=0
    local failed_users=0
    
    if [[ -d "$CONFIG_DIR" ]]; then
        for config_file in "$CONFIG_DIR"/*.json; do
            if [[ -f "$config_file" ]]; then
                local port=$(basename "$config_file" .json)
                ((total_users++))
                
                if systemctl is-active --quiet "shadowsocks-libev@$port" 2>/dev/null; then
                    ((active_users++))
                elif systemctl is-failed --quiet "shadowsocks-libev@$port" 2>/dev/null; then
                    ((failed_users++))
                fi
            fi
        done
    fi
    
    echo "Total Users: $total_users"
    echo -e "Active Services: ${GREEN}$active_users${NC}"
    echo -e "Failed Services: ${RED}$failed_users${NC}"
    echo -e "Inactive Services: ${YELLOW}$((total_users - active_users - failed_users))${NC}"
    
    # System resources
    echo
    echo -e "${CYAN}System Resources:${NC}"
    echo "CPU Load: $(uptime | awk -F'load average:' '{print $2}')"
    echo "Memory Usage: $(free -h | grep Mem | awk '{print $3 "/" $2 " (" $3/$2*100 "%)"}')"
    echo "Disk Usage: $(df -h / | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"
    
    echo
}

# Show all users
show_all_users() {
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}           All Users Status${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo
    
    if [[ ! -d "$CONFIG_DIR" ]]; then
        echo "No configuration directory found"
        return
    fi
    
    local found_users=false
    
    for config_file in "$CONFIG_DIR"/*.json; do
        if [[ -f "$config_file" ]]; then
            local port=$(basename "$config_file" .json)
            show_user_details $port
            found_users=true
        fi
    done
    
    if [[ "$found_users" == "false" ]]; then
        echo "No users found"
    fi
}

# Show real-time monitoring
show_realtime() {
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}         Real-time Monitoring${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo "Press Ctrl+C to stop"
    echo
    
    while true; do
        clear
        show_summary
        show_all_users
        sleep 5
    done
}

# Show help
show_help() {
    echo "Outline-v2ray Monitoring Script"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --summary              Show system summary"
    echo "  --users                Show all users status"
    echo "  --user <port>          Show specific user details"
    echo "  --realtime             Real-time monitoring (refresh every 5s)"
    echo "  --help                 Show this help"
    echo
    echo "Examples:"
    echo "  $0 --summary           # Show system summary"
    echo "  $0 --users             # Show all users"
    echo "  $0 --user 7001         # Show user on port 7001"
    echo "  $0 --realtime          # Real-time monitoring"
    echo
}

# Main execution
main() {
    case "${1:-}" in
        --help|-h)
            show_help
            ;;
        --summary)
            show_summary
            ;;
        --users)
            show_all_users
            ;;
        --user)
            if [[ -z "${2:-}" ]]; then
                echo -e "${RED}[ERROR]${NC} Port number required"
                exit 1
            fi
            show_user_details "$2"
            ;;
        --realtime)
            show_realtime
            ;;
        "")
            show_summary
            show_all_users
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@" 