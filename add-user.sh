#!/bin/bash

# Outline-v2ray User Management Script
# Handles user creation with traffic quotas, IPv6 support, and UFW integration

set -euo pipefail

# Configuration
DOMAIN="${1:-}"
EMAIL="${2:-}"
QUOTA_GB="${3:-25}"
BASE_PORT=443  # Changed from 7000 to 443
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
    
    # Test if domain resolves to both IPv4 and IPv6
    local ipv4_resolved=false
    local ipv6_resolved=false
    
    # Test IPv4 resolution
    if nslookup "$DOMAIN" 2>/dev/null | grep -q "Address:"; then
        ipv4_resolved=true
        log "Domain resolves to IPv4"
    fi
    
    # Test IPv6 resolution
    if nslookup "$DOMAIN" 2>/dev/null | grep -q "AAAA"; then
        ipv6_resolved=true
        log "Domain resolves to IPv6"
    fi
    
    if [[ "$ipv4_resolved" == "false" && "$ipv6_resolved" == "false" ]]; then
        error "Domain $DOMAIN does not resolve to any IP address"
    fi
    
    # Test TLS connectivity (optional check)
    if curl -Ik "https://$DOMAIN" >/dev/null 2>&1; then
        log "TLS validation passed for $DOMAIN"
    else
        log "TLS test skipped for $DOMAIN (SSL certificate will be installed separately)"
    fi
}

# Find next available port starting from 443
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

# Get domain IP addresses
get_domain_ips() {
    local domain=$1
    local ipv4_ip=""
    local ipv6_ip=""
    
    # Get IPv4 address
    ipv4_ip=$(nslookup "$domain" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
    
    # Get IPv6 address
    ipv6_ip=$(nslookup "$domain" 2>/dev/null | grep "AAAA" | awk '{print $2}')
    
    echo "$ipv4_ip:$ipv6_ip"
}

# Create user configuration
create_user_config() {
    local port=$1
    local password=$(openssl rand -base64 32)
    local config_file="$CONFIG_DIR/$port.json"
    
    log "Creating configuration for port $port"
    
    # Ensure config directory exists
    mkdir -p "$CONFIG_DIR"
    
    # Check for SSL certificate
    local ssl_cert_path=""
    local ssl_key_path=""
    local plugin_opts=""
    
    # Check for Let's Encrypt certificate
    if [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] && [[ -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
        ssl_cert_path="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        ssl_key_path="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        plugin_opts="server;tls;host=$DOMAIN;cert=$ssl_cert_path;key=$ssl_key_path;loglevel=none"
        log "Using Let's Encrypt SSL certificate with secure configuration"
    # Check for acme.sh certificate
    elif [[ -f "/root/.acme.sh/$DOMAIN/fullchain.crt" ]] && [[ -f "/root/.acme.sh/$DOMAIN/$DOMAIN.key" ]]; then
        ssl_cert_path="/root/.acme.sh/$DOMAIN/fullchain.crt"
        ssl_key_path="/root/.acme.sh/$DOMAIN/$DOMAIN.key"
        plugin_opts="server;tls;host=$DOMAIN;cert=$ssl_cert_path;key=$ssl_key_path;loglevel=none"
        log "Using acme.sh SSL certificate with secure configuration"
    else
        # No SSL certificate found, use TLS without cert (fallback)
        plugin_opts="server;tls;host=$DOMAIN;loglevel=none"
        warn "No SSL certificate found. Using TLS without certificate (may not work with all clients)"
        warn "To install SSL certificate, run: sudo certbot certonly --standalone -d $DOMAIN"
    fi
    
    # Create per-port JSON configuration
    # Note: Each user gets its own config file for easier audit and revert
    cat > "$config_file" << EOF
{
    "server": "0.0.0.0",
    "server_port": $port,
    "password": "$password",
    "method": "chacha20-poly1305",
    "plugin": "v2ray-plugin",
    "plugin_opts": "$plugin_opts",
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
    
    # Get domain IP addresses
    local domain_ips=$(get_domain_ips "$DOMAIN")
    local ipv4_ip=$(echo "$domain_ips" | cut -d: -f1)
    local ipv6_ip=$(echo "$domain_ips" | cut -d: -f2)
    
    # Create connection strings for both IPv4 and IPv6 (legacy, for reference)
    local connection_string_ipv4=""
    local connection_string_ipv6=""
    if [[ -n "$ipv4_ip" ]]; then
        connection_string_ipv4="ss://$(echo -n "chacha20-poly1305:$password@$ipv4_ip:$port" | base64 -w 0)#$EMAIL (IPv4)"
    fi
    if [[ -n "$ipv6_ip" ]]; then
        connection_string_ipv6="ss://$(echo -n "chacha20-poly1305:$password@[$ipv6_ip]:$port" | base64 -w 0)#$EMAIL (IPv6)"
    fi
    # Domain-based connection string (legacy)
    local connection_string_domain="ss://$(echo -n "chacha20-poly1305:$password@$DOMAIN:$port" | base64 -w 0)#$EMAIL (Domain)"

    # Plugin string for QR/clients
    local plugin_string="v2ray-plugin;$(echo $plugin_opts | sed 's/;/;/g')"
    local plugin_urlencoded=$(echo "$plugin_string" | sed 's/;/%3B/g; s/:/%3A/g; s/=/%3D/g; s/,/%2C/g; s/ /%20/g')
    local ss_uri_full="ss://$(echo -n "chacha20-poly1305:$password@$DOMAIN:$port" | base64 -w 0)?plugin=$plugin_urlencoded#$EMAIL"

    echo
    echo "=========================================="
    echo "User Configuration Created Successfully"
    echo "=========================================="
    echo "Domain: $DOMAIN"
    echo "Port: $port"
    echo "Email: $EMAIL"
    echo "Quota: ${QUOTA_GB}GB"
    echo "Method: chacha20-poly1305"
    echo "Plugin: v2ray-plugin"
    echo "Plugin Options: $plugin_opts"
    if [[ -n "$ipv4_ip" ]]; then
        echo "IPv4: $ipv4_ip"
    fi
    if [[ -n "$ipv6_ip" ]]; then
        echo "IPv6: $ipv6_ip"
    fi
    echo "=========================================="
    echo
    # Generate QR code for full ss:// URI (with plugin)
    if command -v qrencode >/dev/null 2>&1; then
        echo "QR Code (for mobile clients, with plugin):"
        echo "$ss_uri_full" | qrencode -t ansiutf8
        echo
    else
        warn "qrencode not found - QR code not generated"
    fi
    echo "Connection String (for copy-paste in mobile/desktop clients):"
    echo "$ss_uri_full"
    echo
    echo "(Legacy connection strings for reference)"
    echo "Domain-based (base64, legacy):"
    echo "$connection_string_domain"
    echo
    if [[ -n "$connection_string_ipv4" ]]; then
        echo "IPv4-only (base64, legacy):"
        echo "$connection_string_ipv4"
        echo
    fi
    if [[ -n "$connection_string_ipv6" ]]; then
        echo "IPv6-only (base64, legacy):"
        echo "$connection_string_ipv6"
        echo
    fi
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