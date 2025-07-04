#!/bin/bash

# SSL Certificate Installation Script for Outline-v2ray
# Automatically installs SSL certificates for domains

set -euo pipefail

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

# Install SSL certificate for domain
install_ssl_certificate() {
    local domain=$1
    
    if [[ -z "$domain" ]]; then
        error "Domain is required. Usage: $0 <domain>"
    fi
    
    log "Installing SSL certificate for domain: $domain"
    
    # Check if certbot is installed
    if ! command -v certbot >/dev/null 2>&1; then
        log "Installing certbot..."
        apt-get update
        apt-get install -y certbot
    fi
    
    # Stop any service using port 80/443 temporarily
    log "Stopping services on ports 80/443..."
    
    # Stop shadowsocks services temporarily
    for service in /etc/systemd/system/shadowsocks-libev@*.service; do
        if [[ -f "$service" ]]; then
            local port=$(basename "$service" | sed 's/shadowsocks-libev@\(.*\)\.service/\1/')
            if systemctl is-active --quiet "shadowsocks-libev@$port" 2>/dev/null; then
                log "Stopping shadowsocks-libev@$port"
                systemctl stop "shadowsocks-libev@$port"
            fi
        fi
    done
    
    # Stop nginx/apache if running
    if systemctl is-active --quiet nginx 2>/dev/null; then
        log "Stopping nginx"
        systemctl stop nginx
    fi
    
    if systemctl is-active --quiet apache2 2>/dev/null; then
        log "Stopping apache2"
        systemctl stop apache2
    fi
    
    # Install certificate using standalone mode
    log "Installing SSL certificate using Let's Encrypt..."
    if certbot certonly --standalone -d "$domain" --non-interactive --agree-tos --email admin@"$domain"; then
        log "SSL certificate installed successfully"
        
        # Verify certificate
        if [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]] && [[ -f "/etc/letsencrypt/live/$domain/privkey.pem" ]]; then
            log "Certificate verified:"
            log "  Certificate: /etc/letsencrypt/live/$domain/fullchain.pem"
            log "  Private Key: /etc/letsencrypt/live/$domain/privkey.pem"
            
            # Set proper permissions
            chmod 644 "/etc/letsencrypt/live/$domain/fullchain.pem"
            chmod 600 "/etc/letsencrypt/live/$domain/privkey.pem"
            
            # Setup auto-renewal
            log "Setting up auto-renewal..."
            (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
            
        else
            error "Certificate files not found after installation"
        fi
    else
        error "Failed to install SSL certificate"
    fi
    
    # Restart services
    log "Restarting services..."
    
    # Restart shadowsocks services
    for service in /etc/systemd/system/shadowsocks-libev@*.service; do
        if [[ -f "$service" ]]; then
            local port=$(basename "$service" | sed 's/shadowsocks-libev@\(.*\)\.service/\1/')
            log "Starting shadowsocks-libev@$port"
            systemctl start "shadowsocks-libev@$port"
        fi
    done
    
    # Restart web servers if they were running
    if systemctl is-enabled --quiet nginx 2>/dev/null; then
        log "Starting nginx"
        systemctl start nginx
    fi
    
    if systemctl is-enabled --quiet apache2 2>/dev/null; then
        log "Starting apache2"
        systemctl start apache2
    fi
    
    log "SSL certificate installation completed successfully"
}

# Show usage
show_usage() {
    echo "Usage: $0 <domain>"
    echo "Example: $0 example.com"
    echo
    echo "This script will:"
    echo "1. Install certbot if not already installed"
    echo "2. Stop services using ports 80/443 temporarily"
    echo "3. Install SSL certificate using Let's Encrypt"
    echo "4. Setup auto-renewal"
    echo "5. Restart all services"
}

# Main execution
main() {
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi
    
    local domain=$1
    install_ssl_certificate "$domain"
}

# Run main function
main "$@" 