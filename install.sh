#!/bin/bash

# Outline-v2ray Installation Script
# Installs all prerequisites and configures the system

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

# Detect OS
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    else
        error "Cannot detect OS"
    fi
}

# Install packages on Ubuntu/Debian
install_debian_packages() {
    log "Installing packages on $OS..."

    # Update package list
    apt-get update

    # Install required packages
    apt-get install -y \
        shadowsocks-libev \
        iptables-persistent \
        qrencode \
        curl \
        net-tools \
        ufw \
        openssl \
        dnsutils

    log "Package installation completed"
}

# Install v2ray-plugin manually
install_v2ray_plugin() {
    log "Installing v2ray-plugin manually..."

    # Download latest release
    wget -O /tmp/v2ray-plugin-linux-amd64.tar.gz https://github.com/shadowsocks/v2ray-plugin/releases/latest/download/v2ray-plugin-linux-amd64.tar.gz

    # Extract
    tar -xzf /tmp/v2ray-plugin-linux-amd64.tar.gz -C /tmp

    # Move binary
    mv /tmp/v2ray-plugin_linux_amd64 /usr/bin/v2ray-plugin

    # Make executable
    chmod +x /usr/bin/v2ray-plugin

    log "v2ray-plugin installed"
}

# Install packages on CentOS/RHEL
install_centos_packages() {
    log "Installing packages on $OS..."

    # Install EPEL repository
    yum install -y epel-release

    # Install required packages
    yum install -y \
        shadowsocks-libev \
        iptables-services \
        qrencode \
        curl \
        net-tools \
        firewalld \
        openssl \
        bind-utils

    # Enable and start iptables
    systemctl enable iptables
    systemctl start iptables

    log "Package installation completed"
}

# Configure iptables-persistent
configure_iptables_persistent() {
    log "Configuring iptables-persistent..."

    # Create rules directory if it doesn't exist
    mkdir -p /etc/iptables

    # Save current rules
    iptables-save > /etc/iptables/rules.v4

    # Save IPv6 rules if available
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables-save > /etc/iptables/rules.v6
    fi

    log "iptables-persistent configured"
}

# Install systemd service template
install_systemd_template() {
    log "Installing systemd service template..."

    # Copy the service template
    cp shadowsocks-libev@.service /etc/systemd/system/

    # Reload systemd
    systemctl daemon-reload

    log "Systemd service template installed"
}

# Configure UFW
configure_ufw() {
    log "Configuring UFW..."

    # Enable UFW
    ufw --force enable

    # Allow SSH (important!)
    ufw allow ssh

    # Allow HTTP/HTTPS for domain validation
    ufw allow 80/tcp
    ufw allow 443/tcp

    log "UFW configured"
}

# Create configuration directory
create_config_directory() {
    log "Creating configuration directory..."

    mkdir -p /etc/shadowsocks-libev/config.d
    chmod 700 /etc/shadowsocks-libev/config.d
    chown root:root /etc/shadowsocks-libev/config.d

    log "Configuration directory created"
}

# Make scripts executable
make_scripts_executable() {
    log "Making scripts executable..."

    chmod +x add-user.sh
    chmod +x remove-user.sh
    chmod +x reset-quota.sh
    chmod +x monitor.sh

    log "Scripts made executable"
}

# Check nftables compatibility
check_nftables_compatibility() {
    log "Checking nftables compatibility..."

    # Check if system is using nftables backend
    if iptables --version | grep -q nf_tables; then
        warn "System is using nftables backend"
        warn "If quota rules fail, switch to legacy backend with:"
        warn "  update-alternatives --set iptables /usr/sbin/iptables-legacy"
        warn "  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy"
    else
        log "System is using legacy iptables backend"
    fi
}

# Show post-installation instructions
show_post_install_instructions() {
    echo
    echo "=========================================="
    echo "Installation Completed Successfully!"
    echo "=========================================="
    echo
    echo "Next steps:"
    echo "1. Add a user: ./add-user.sh <domain> <email> [quota_gb]"
    echo "   Example: ./add-user.sh example.com user@example.com 25"
    echo
    echo "2. List users: ./remove-user.sh --list"
    echo
    echo "3. Remove a user: ./remove-user.sh <port>"
    echo "   Example: ./remove-user.sh 7001"
    echo
    echo "4. Reset quota: ./reset-quota.sh <port> [quota_gb]"
    echo "   Example: ./reset-quota.sh 7001 50"
    echo
    echo "5. Setup monthly quota reset: ./reset-quota.sh --setup-cron 25"
    echo
    echo "6. Monitor quota usage: ./reset-quota.sh --show"
    echo
    echo "Important Notes:"
    echo "- Quotas do NOT reset automatically - use cron or manual reset"
    echo "- Each user gets their own config file in /etc/shadowsocks-libev/config.d/"
    echo "- UFW rules are automatically managed"
    echo "- IPv6 support is automatically detected and configured"
    echo
    echo "For more information, see README.md"
    echo "=========================================="
}

# Main installation function
main() {
    log "Starting Outline-v2ray installation..."

    detect_os
    log "Detected OS: $OS $VER"

    # Install packages based on OS
    if [[ "$OS" == *"Ubuntu"* ]] || [[ "$OS" == *"Debian"* ]]; then
        install_debian_packages
        install_v2ray_plugin
    elif [[ "$OS" == *"CentOS"* ]] || [[ "$OS" == *"Red Hat"* ]]; then
        install_centos_packages
        install_v2ray_plugin
    else
        error "Unsupported OS: $OS"
    fi

    configure_iptables_persistent
    install_systemd_template
    configure_ufw
    create_config_directory
    make_scripts_executable
    check_nftables_compatibility

    log "Installation completed successfully"
    show_post_install_instructions
}

# Run installation
main 