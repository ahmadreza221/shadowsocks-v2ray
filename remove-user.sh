#!/bin/bash

# Outline-v2ray User Removal Script
# Removes user configuration, iptables rules, UFW rules, and systemd services

set -euo pipefail

# Configuration
CONFIG_DIR="/etc/shadowsocks-libev/config.d"
IPTABLES_RULES_V4="/etc/iptables/rules.v4"
IPTABLES_RULES_V6="/etc/iptables/rules.v6"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
fi

# Check for IPv6 support
check_ipv6() {
    if ip -6 addr | grep -q "scope global"; then
        echo "true"
    else
        echo "false"
    fi
}

# Remove iptables rules
remove_iptables_rules() {
    local port=$1
    
    log "Removing iptables rules for port $port"
    
    # IPv4 rules
    iptables -D INPUT -p tcp --dport $port -m quota --quota 26843545600 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p tcp --sport $port -m quota --quota 26843545600 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -p tcp --sport $port -j DROP 2>/dev/null || true
    
    # Try to remove with different quota values (in case quota was different)
    for quota in 107374182400 53687091200 13421772800 6710886400; do
        iptables -D INPUT -p tcp --dport $port -m quota --quota $quota -j ACCEPT 2>/dev/null || true
        iptables -D OUTPUT -p tcp --sport $port -m quota --quota $quota -j ACCEPT 2>/dev/null || true
    done
    
    # IPv6 rules (if supported)
    if [[ $(check_ipv6) == "true" ]]; then
        log "Removing IPv6 iptables rules"
        ip6tables -D INPUT -p tcp --dport $port -m quota --quota 26843545600 -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null || true
        ip6tables -D OUTPUT -p tcp --sport $port -m quota --quota 26843545600 -j ACCEPT 2>/dev/null || true
        ip6tables -D OUTPUT -p tcp --sport $port -j DROP 2>/dev/null || true
        
        # Try to remove with different quota values
        for quota in 107374182400 53687091200 13421772800 6710886400; do
            ip6tables -D INPUT -p tcp --dport $port -m quota --quota $quota -j ACCEPT 2>/dev/null || true
            ip6tables -D OUTPUT -p tcp --sport $port -m quota --quota $quota -j ACCEPT 2>/dev/null || true
        done
    fi
    
    # Persist rules
    iptables-save > "$IPTABLES_RULES_V4"
    if [[ $(check_ipv6) == "true" ]]; then
        ip6tables-save > "$IPTABLES_RULES_V6"
    fi
}

# Remove UFW rules
remove_ufw_rules() {
    local port=$1
    
    log "Removing UFW rule for port $port"
    
    # Find and remove UFW rules for this port
    ufw status numbered | grep "SS user $port" | awk '{print $1}' | sed 's/\[//;s/\]//' | tac | while read rule_num; do
        if [[ -n "$rule_num" ]]; then
            echo "y" | ufw delete $rule_num >/dev/null 2>&1 || true
        fi
    done
}

# Stop and disable systemd service
stop_service() {
    local port=$1
    
    log "Stopping shadowsocks-libev service on port $port"
    
    # Stop the service
    systemctl stop "shadowsocks-libev@$port" 2>/dev/null || true
    
    # Disable the service
    systemctl disable "shadowsocks-libev@$port" 2>/dev/null || true
    
    # Reload systemd
    systemctl daemon-reload
}

# Remove configuration file
remove_config() {
    local port=$1
    local config_file="$CONFIG_DIR/$port.json"
    
    log "Removing configuration file: $config_file"
    
    if [[ -f "$config_file" ]]; then
        rm -f "$config_file"
        log "Configuration file removed"
    else
        warn "Configuration file not found: $config_file"
    fi
}

# Main removal function
remove_user() {
    local port=$1
    
    log "Starting removal process for port $port"
    
    # Validate port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        error "Invalid port number: $port. Must be between 1-65535"
    fi
    
    # Check if service exists (silent check)
    if ! systemctl list-unit-files | grep -q "shadowsocks-libev@$port" 2>/dev/null; then
        # Service doesn't exist, which is normal for new installations
        log "Service shadowsocks-libev@$port not found (normal for new installations)"
    fi
    
    # Perform removal steps
    stop_service $port
    remove_iptables_rules $port
    remove_ufw_rules $port
    remove_config $port
    
    log "User removal completed for port $port"
}

# List all users
list_users() {
    log "Listing all configured users:"
    echo
    
    if [[ ! -d "$CONFIG_DIR" ]]; then
        echo "No configuration directory found"
        return
    fi
    
    local found_users=false
    
    for config_file in "$CONFIG_DIR"/*.json; do
        if [[ -f "$config_file" ]]; then
            local port=$(basename "$config_file" .json)
            local service_status="unknown"
            
            if systemctl is-active --quiet "shadowsocks-libev@$port" 2>/dev/null; then
                service_status="active"
            elif systemctl is-failed --quiet "shadowsocks-libev@$port" 2>/dev/null; then
                service_status="failed"
            else
                service_status="inactive"
            fi
            
            echo "Port: $port | Service: $service_status | Config: $config_file"
            found_users=true
        fi
    done
    
    if [[ "$found_users" == "false" ]]; then
        echo "No users found"
    fi
}

# Main execution
main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 <port>"
        echo "       $0 --list"
        echo ""
        echo "Examples:"
        echo "  $0 7001          # Remove user on port 7001"
        echo "  $0 --list        # List all users"
        exit 1
    fi
    
    if [[ "$1" == "--list" ]]; then
        list_users
    else
        remove_user "$1"
    fi
}

main "$@" 