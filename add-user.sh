#!/bin/bash

# Outline-v2ray User Management Script
# Handles user creation with traffic quotas, IPv6 support, and UFW integration

set -euo pipefail

# Configuration
DOMAIN="${1:-}"
EMAIL="${2:-}"
QUOTA_GB="${3:-25}"
BASE_PORT=7000
CONFIG_DIR="/etc/shadowsocks-libev/config.d"
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

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check for required packages
    local missing_packages=()
    
    if ! command -v iptables >/dev/null 2>&1; then
        missing_packages+=("iptables")
    fi
    
    if ! command -v ufw >/dev/null 2>&1; then
        missing_packages+=("ufw")
    fi
    
    if ! command -v systemctl >/dev/null 2>&1; then
        missing_packages+=("systemd")
    fi
    
    if ! command -v ss-server >/dev/null 2>&1; then
        missing_packages+=("shadowsocks-libev")
    fi
    
    if ! command -v qrencode >/dev/null 2>&1; then
        missing_packages+=("qrencode")
    fi
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        error "Missing required packages: ${missing_packages[*]}"
    fi
    
    # Check for iptables-persistent
    if [[ ! -f "$IPTABLES_RULES_V4" ]]; then
        warn "iptables-persistent not configured. Installing..."
        apt-get update
        apt-get install -y iptables-persistent
        iptables-save > "$IPTABLES_RULES_V4"
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables-save > "$IPTABLES_RULES_V6"
        fi
    fi
    
    log "Prerequisites check completed"
}

# Validate domain and test TLS
validate_domain() {
    if [[ -z "$DOMAIN" ]]; then
        error "Domain is required. Usage: $0 <domain> <email> [quota_gb]"
    fi
    
    log "Validating domain: $DOMAIN"
    
    # Test if domain resolves
    if ! nslookup "$DOMAIN" >/dev/null 2>&1; then
        error "Domain $DOMAIN does not resolve"
    fi
    
    # Test TLS connectivity
    if ! curl -Ik "https://$DOMAIN" >/dev/null 2>&1; then
        warn "TLS test failed for $DOMAIN. Continuing anyway..."
    else
        log "TLS validation passed for $DOMAIN"
    fi
}

# Find next available port
find_next_port() {
    local port=$BASE_PORT
    while [[ $port -lt 9000 ]]; do
        if ! netstat -tln | grep -q ":$port "; then
            echo $port
            return 0
        fi
        ((port++))
    done
    error "No available ports found in range $BASE_PORT-9000"
}

# Check for IPv6 support
check_ipv6() {
    if ip -6 addr | grep -q "scope global"; then
        echo "true"
    else
        echo "false"
    fi
}

# Create user configuration
create_user_config() {
    local port=$1
    local password=$(openssl rand -base64 32)
    local config_file="$CONFIG_DIR/$port.json"
    
    log "Creating configuration for port $port"
    
    # Ensure config directory exists
    mkdir -p "$CONFIG_DIR"
    
    # Create per-port JSON configuration
    # Note: Each user gets its own config file for easier audit and revert
    cat > "$config_file" << EOF
{
    "server": "0.0.0.0",
    "server_port": $port,
    "password": "$password",
    "method": "aes-256-gcm",
    "plugin": "v2ray-plugin",
    "plugin_opts": "server;tls;host=$DOMAIN",
    "mode": "tcp_and_udp"
}
EOF
    
    # Set proper permissions
    chmod 600 "$config_file"
    chown root:root "$config_file"
    
    echo "$password"
}

# Setup iptables quota rules
# IMPORTANT: Quota rules count bytes ONCE and then become "match-all drop"
# They do NOT reset automatically - manual reset or cron job required
setup_iptables_quota() {
    local port=$1
    local quota_bytes=$((QUOTA_GB * 1024 * 1024 * 1024))
    
    log "Setting up iptables quota rules for port $port (${QUOTA_GB}GB)"
    
    # IPv4 rules
    iptables -A INPUT -p tcp --dport $port -m quota --quota $quota_bytes -j ACCEPT
    iptables -A INPUT -p tcp --dport $port -j DROP
    iptables -A OUTPUT -p tcp --sport $port -m quota --quota $quota_bytes -j ACCEPT
    iptables -A OUTPUT -p tcp --sport $port -j DROP
    
    # IPv6 rules (if supported)
    if [[ $(check_ipv6) == "true" ]]; then
        log "Adding IPv6 quota rules"
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
}

# Setup UFW rules
setup_ufw() {
    local port=$1
    
    log "Adding UFW rule for port $port"
    ufw allow $port/tcp comment "SS user $port (${QUOTA_GB} GB cap)"
}

# Start systemd service
# Using systemd template: shadowsocks-libev@.service
# The %i parameter expands to the port number
start_service() {
    local port=$1
    
    log "Starting shadowsocks-libev service on port $port"
    
    # Enable and start the service using the template
    systemctl enable --now "shadowsocks-libev@$port"
    
    # Verify service is running
    if systemctl is-active --quiet "shadowsocks-libev@$port"; then
        log "Service started successfully"
    else
        error "Failed to start service on port $port"
    fi
}

# Generate QR code and connection info
generate_connection_info() {
    local port=$1
    local password=$2
    
    log "Generating connection information"
    
    # Create connection string
    local connection_string="ss://$(echo -n "aes-256-gcm:$password@$DOMAIN:$port" | base64 -w 0)#$EMAIL"
    
    echo
    echo "=========================================="
    echo "User Configuration Created Successfully"
    echo "=========================================="
    echo "Domain: $DOMAIN"
    echo "Port: $port"
    echo "Email: $EMAIL"
    echo "Quota: ${QUOTA_GB}GB"
    echo "Method: aes-256-gcm"
    echo "Plugin: v2ray-plugin"
    echo "=========================================="
    echo
    
    # Generate QR code
    if command -v qrencode >/dev/null 2>&1; then
        echo "QR Code:"
        echo "$connection_string" | qrencode -t ansiutf8
        echo
    else
        warn "qrencode not found - QR code not generated"
    fi
    
    echo "Connection String:"
    echo "$connection_string"
    echo
    echo "Configuration file: $CONFIG_DIR/$port.json"
    echo
    echo "To remove this user, run: ./remove-user.sh $port"
    echo "To reset quota, run: ./reset-quota.sh $port"
}

# Main execution
main() {
    log "Starting user creation process"
    
    check_prerequisites
    validate_domain
    
    local port=$(find_next_port)
    log "Selected port: $port"
    
    local password=$(create_user_config $port)
    setup_iptables_quota $port
    setup_ufw $port
    start_service $port
    generate_connection_info $port $password
    
    log "User creation completed successfully"
}

# Handle script arguments
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <domain> <email> [quota_gb]"
    echo "Example: $0 example.com user@example.com 25"
    exit 1
fi

main 