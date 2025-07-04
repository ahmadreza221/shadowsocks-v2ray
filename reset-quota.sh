#!/bin/bash

# Outline-v2ray Quota Reset Script
# Resets traffic quotas for users - can be run manually or via cron

set -euo pipefail

# Configuration
IPTABLES_RULES_V4="/etc/iptables/rules.v4"
IPTABLES_RULES_V6="/etc/iptables/rules.v6"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Reset quota for a specific port
reset_port_quota() {
    local port=$1
    local quota_gb="${2:-25}"
    local quota_bytes=$((quota_gb * 1024 * 1024 * 1024))
    
    log "Resetting quota for port $port to ${quota_gb}GB"
    
    # Remove existing quota rules
    iptables -D INPUT -p tcp --dport $port -m quota --quota 26843545600 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p tcp --sport $port -m quota --quota 26843545600 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -p tcp --sport $port -j DROP 2>/dev/null || true
    
    # Try to remove with different quota values
    for quota in 107374182400 53687091200 13421772800 6710886400; do
        iptables -D INPUT -p tcp --dport $port -m quota --quota $quota -j ACCEPT 2>/dev/null || true
        iptables -D OUTPUT -p tcp --sport $port -m quota --quota $quota -j ACCEPT 2>/dev/null || true
    done
    
    # Add new quota rules
    iptables -A INPUT -p tcp --dport $port -m quota --quota $quota_bytes -j ACCEPT
    iptables -A INPUT -p tcp --dport $port -j DROP
    iptables -A OUTPUT -p tcp --sport $port -m quota --quota $quota_bytes -j ACCEPT
    iptables -A OUTPUT -p tcp --sport $port -j DROP
    
    # IPv6 rules (if supported)
    if [[ $(check_ipv6) == "true" ]]; then
        log "Resetting IPv6 quota for port $port"
        
        # Remove existing IPv6 quota rules
        ip6tables -D INPUT -p tcp --dport $port -m quota --quota 26843545600 -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p tcp --dport $port -j DROP 2>/dev/null || true
        ip6tables -D OUTPUT -p tcp --sport $port -m quota --quota 26843545600 -j ACCEPT 2>/dev/null || true
        ip6tables -D OUTPUT -p tcp --sport $port -j DROP 2>/dev/null || true
        
        # Try to remove with different quota values
        for quota in 107374182400 53687091200 13421772800 6710886400; do
            ip6tables -D INPUT -p tcp --dport $port -m quota --quota $quota -j ACCEPT 2>/dev/null || true
            ip6tables -D OUTPUT -p tcp --sport $port -m quota --quota $quota -j ACCEPT 2>/dev/null || true
        done
        
        # Add new IPv6 quota rules
        ip6tables -A INPUT -p tcp --dport $port -m quota --quota $quota_bytes -j ACCEPT
        ip6tables -A INPUT -p tcp --dport $port -j DROP
        ip6tables -A OUTPUT -p tcp --sport $port -m quota --quota $quota_bytes -j ACCEPT
        ip6tables -A OUTPUT -p tcp --sport $port -j DROP
    fi
    
    # Persist rules
    iptables-save > "$IPTABLES_RULES_V4"
    if [[ $(check_ipv6) == "true" ]]; then
        ip6tables-save > "$IPTABLES_RULES_V6"
    fi
    
    log "Quota reset completed for port $port"
}

# Reset all quotas
reset_all_quotas() {
    local quota_gb="${1:-25}"
    
    log "Resetting all quotas to ${quota_gb}GB"
    
    # Find all ports with quota rules
    local ports=$(iptables -L INPUT -n --line-numbers | grep "dpt:" | grep "quota" | awk '{print $5}' | cut -d: -f2 | sort -u)
    
    if [[ -z "$ports" ]]; then
        warn "No quota rules found"
        return
    fi
    
    for port in $ports; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [[ $port -ge 7000 ]] && [[ $port -le 9000 ]]; then
            reset_port_quota $port $quota_gb
        fi
    done
    
    log "All quotas reset completed"
}

# Show current quota usage
show_quota_usage() {
    log "Current quota usage:"
    echo
    
    # Show IPv4 quota rules
    echo "IPv4 Quota Rules:"
    iptables -L INPUT -n --line-numbers | grep "quota" | while read line; do
        echo "  $line"
    done
    
    echo
    echo "IPv4 Quota Rules (OUTPUT):"
    iptables -L OUTPUT -n --line-numbers | grep "quota" | while read line; do
        echo "  $line"
    done
    
    # Show IPv6 quota rules if available
    if [[ $(check_ipv6) == "true" ]]; then
        echo
        echo "IPv6 Quota Rules:"
        ip6tables -L INPUT -n --line-numbers | grep "quota" | while read line; do
            echo "  $line"
        done
        
        echo
        echo "IPv6 Quota Rules (OUTPUT):"
        ip6tables -L OUTPUT -n --line-numbers | grep "quota" | while read line; do
            echo "  $line"
        done
    fi
}

# Setup monthly cron job
setup_monthly_cron() {
    local quota_gb="${1:-25}"
    local script_path=$(readlink -f "$0")
    
    log "Setting up monthly quota reset cron job"
    
    # Create cron entry for first day of month at 00:01
    local cron_entry="1 0 1 * * root $script_path --all $quota_gb >> /var/log/quota-reset.log 2>&1"
    
    # Check if cron entry already exists
    if crontab -l 2>/dev/null | grep -q "$script_path"; then
        warn "Cron entry already exists. Removing old entry..."
        crontab -l 2>/dev/null | grep -v "$script_path" | crontab -
    fi
    
    # Add new cron entry
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
    
    log "Monthly quota reset cron job configured"
    log "Cron entry: $cron_entry"
    log "Logs will be written to: /var/log/quota-reset.log"
}

# Remove cron job
remove_cron() {
    local script_path=$(readlink -f "$0")
    
    log "Removing quota reset cron job"
    
    if crontab -l 2>/dev/null | grep -q "$script_path"; then
        crontab -l 2>/dev/null | grep -v "$script_path" | crontab -
        log "Cron job removed"
    else
        warn "No cron job found to remove"
    fi
}

# Show help
show_help() {
    echo "Outline-v2ray Quota Reset Script"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  <port> [quota_gb]     Reset quota for specific port (default: 25GB)"
    echo "  --all [quota_gb]      Reset all quotas (default: 25GB)"
    echo "  --show                Show current quota usage"
    echo "  --setup-cron [quota]  Setup monthly cron job (default: 25GB)"
    echo "  --remove-cron         Remove monthly cron job"
    echo "  --help                Show this help"
    echo
    echo "Examples:"
    echo "  $0 7001               # Reset quota for port 7001 to 25GB"
    echo "  $0 7001 50            # Reset quota for port 7001 to 50GB"
    echo "  $0 --all              # Reset all quotas to 25GB"
    echo "  $0 --all 100          # Reset all quotas to 100GB"
    echo "  $0 --setup-cron 25    # Setup monthly reset to 25GB"
    echo "  $0 --show             # Show current quota usage"
    echo
    echo "Note: Quotas are reset manually or via cron. They do not reset automatically."
}

# Main execution
main() {
    case "${1:-}" in
        --help|-h)
            show_help
            ;;
        --show)
            show_quota_usage
            ;;
        --all)
            reset_all_quotas "${2:-25}"
            ;;
        --setup-cron)
            setup_monthly_cron "${2:-25}"
            ;;
        --remove-cron)
            remove_cron
            ;;
        "")
            show_help
            ;;
        *)
            # Check if it's a port number
            if [[ "$1" =~ ^[0-9]+$ ]] && [[ $1 -ge 7000 ]] && [[ $1 -le 9000 ]]; then
                reset_port_quota "$1" "${2:-25}"
            else
                error "Invalid option or port number: $1"
            fi
            ;;
    esac
}

main "$@" 