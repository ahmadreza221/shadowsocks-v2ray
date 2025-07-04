# Outline-v2ray

A comprehensive Shadowsocks-libev management system with traffic quotas, IPv6 support, and automated user management.

## Features

- **Traffic Quotas**: Per-user traffic limits with iptables quota module
- **IPv6 Support**: Automatic detection and configuration of IPv6 rules
- **UFW Integration**: Automatic firewall rule management
- **Systemd Templates**: Multi-instance support using systemd template units
- **QR Code Generation**: Automatic QR code generation for easy client setup
- **User Management**: Add, remove, and list users with simple commands
- **Quota Management**: Manual and automated quota resets
- **Monitoring**: Built-in quota usage monitoring

## Prerequisites

- Ubuntu 18.04+ or Debian 9+ (CentOS/RHEL 7+ supported)
- Root access
- Domain name with valid SSL certificate
- VPS with IPv4 (IPv6 optional but recommended)

## Quick Start

1. **Clone and install**:
   ```bash
   git clone <repository-url>
   cd outline-v2ray
   sudo ./install.sh
   ```

2. **Add your first user**:
   ```bash
   sudo ./add-user.sh example.com user@example.com 25
   ```

3. **Setup monthly quota reset**:
   ```bash
   sudo ./reset-quota.sh --setup-cron 25
   ```

## Installation

The installation script (`install.sh`) automatically:

- Installs required packages: `shadowsocks-libev`, `v2ray-plugin`, `iptables-persistent`, `qrencode`
- Configures iptables-persistent for rule persistence across reboots
- Installs systemd service template for multi-instance support
- Configures UFW firewall
- Creates configuration directory structure
- Checks nftables compatibility

### Required Packages

- `shadowsocks-libev`: Core Shadowsocks server
- `v2ray-plugin`: TLS obfuscation plugin
- `iptables-persistent`: Persist firewall rules across reboots
- `qrencode`: Generate QR codes for client configuration
- `ufw`: Uncomplicated firewall for port management
- `curl`, `net-tools`, `openssl`: System utilities

## Usage

### Adding Users

```bash
sudo ./add-user.sh <domain> <email> [quota_gb]
```

**Examples**:
```bash
sudo ./add-user.sh example.com user@example.com 25
sudo ./add-user.sh mydomain.com admin@company.com 100
```

**What happens**:
1. Validates domain and tests TLS connectivity
2. Finds next available port (7000-9000 range)
3. Creates per-port JSON configuration file
4. Sets up iptables quota rules (IPv4 + IPv6)
5. Adds UFW firewall rule
6. Starts systemd service using template
7. Generates QR code and connection string

### Removing Users

```bash
sudo ./remove-user.sh <port>
sudo ./remove-user.sh --list
```

**Examples**:
```bash
sudo ./remove-user.sh 7001
sudo ./remove-user.sh --list
```

**What happens**:
1. Stops and disables systemd service
2. Removes iptables quota rules (IPv4 + IPv6)
3. Removes UFW firewall rule
4. Deletes configuration file
5. Persists rule changes

### Managing Quotas

```bash
# Reset specific user quota
sudo ./reset-quota.sh <port> [quota_gb]

# Reset all quotas
sudo ./reset-quota.sh --all [quota_gb]

# Show current quota usage
sudo ./reset-quota.sh --show

# Setup monthly automatic reset
sudo ./reset-quota.sh --setup-cron [quota_gb]

# Remove automatic reset
sudo ./reset-quota.sh --remove-cron
```

**Examples**:
```bash
sudo ./reset-quota.sh 7001 50
sudo ./reset-quota.sh --all 25
sudo ./reset-quota.sh --setup-cron 25
```

## Traffic Quota Mechanics

### Important: Quota Behavior

**Quotas do NOT reset automatically**. The `iptables -m quota` module:

1. Counts bytes **once** until the quota is exhausted
2. Then converts the rule to "match-all drop"
3. **Never resets itself** - requires manual intervention

### Quota Reset Options

1. **Manual Reset**: `./reset-quota.sh <port> [quota_gb]`
2. **Cron Job**: `./reset-quota.sh --setup-cron [quota_gb]`
3. **Monthly Reset**: Automatically runs on the 1st of each month

### Sample Cron Entry

```bash
# Reset all quotas to 25GB on the 1st of each month at 00:01
1 0 1 * * root /path/to/reset-quota.sh --all 25 >> /var/log/quota-reset.log 2>&1
```

### Quota Direction

The quota rules count traffic in the direction that hits the rule:
- **INPUT rules**: Count incoming traffic to the port
- **OUTPUT rules**: Count outgoing traffic from the port

For total traffic metering, both INPUT and OUTPUT rules are configured.

## Systemd Template Configuration

The system uses a systemd template unit (`shadowsocks-libev@.service`) where:

- `%i` expands to the port number (e.g., `7001`)
- Each user gets their own service instance: `shadowsocks-libev@7001`
- Configuration files are stored in `/etc/shadowsocks-libev/config.d/<port>.json`

### Service Template

```ini
[Unit]
Description=Shadowsocks-libev instance on port %i
After=network.target

[Service]
ExecStart=/usr/bin/ss-server -c /etc/shadowsocks-libev/config.d/%i.json
Restart=on-failure
```

### Service Management

```bash
# Start service for port 7001
systemctl enable --now shadowsocks-libev@7001

# Check status
systemctl status shadowsocks-libev@7001

# View logs
journalctl -u shadowsocks-libev@7001 -f
```

## Multi-Port Configuration Strategy

**Each user gets their own configuration file**:
- Location: `/etc/shadowsocks-libev/config.d/<port>.json`
- **Never mix multiple ports in the root `config.json`**
- Benefits: Easier audit, individual revert, cleaner management

### Configuration Structure

```
/etc/shadowsocks-libev/
├── config.d/
│   ├── 7001.json  # User 1
│   ├── 7002.json  # User 2
│   └── 7003.json  # User 3
└── config.json    # Main config (unused)
```

## IPv6 Support

The system automatically:

1. **Detects IPv6 availability**: `ip -6 addr | grep "scope global"`
2. **Creates matching rules**: IPv6 quota rules mirror IPv4 rules
3. **Persists IPv6 rules**: Saves to `/etc/iptables/rules.v6`

### IPv6 Quota Rules

```bash
# IPv4 rules
iptables -A INPUT -p tcp --dport 7001 -m quota --quota 26843545600 -j ACCEPT
iptables -A INPUT -p tcp --dport 7001 -j DROP

# IPv6 rules (if supported)
ip6tables -A INPUT -p tcp --dport 7001 -m quota --quota 26843545600 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 7001 -j DROP
```

## UFW Integration

Each new user automatically gets a UFW rule:

```bash
ufw allow 7001/tcp comment "SS user 7001 (25 GB cap)"
```

**Benefits**:
- Prevents service startup failures
- Clear audit trail of open ports
- Easy removal when user is deleted

## Monitoring and Troubleshooting

### Check Service Status

```bash
# List all services
systemctl list-units 'shadowsocks-libev@*'

# Check specific service
systemctl status shadowsocks-libev@7001

# View logs
journalctl -u shadowsocks-libev@7001 -f
```

### Monitor Quota Usage

```bash
# Show all quota rules
sudo ./reset-quota.sh --show

# Check iptables rules
iptables -L INPUT -n --line-numbers | grep quota
ip6tables -L INPUT -n --line-numbers | grep quota
```

### Check UFW Rules

```bash
# List all rules
ufw status numbered

# Find specific user rule
ufw status numbered | grep "SS user 7001"
```

### Domain Validation

The system validates domains before creating users:

```bash
# DNS resolution test
nslookup example.com

# TLS connectivity test
curl -Ik https://example.com
```

## Troubleshooting

### Common Issues

#### 1. Quota Rules Not Working

**Symptoms**: Users can connect even after quota exceeded

**Solutions**:
```bash
# Check if using nftables backend
iptables --version | grep nf_tables

# Switch to legacy backend if needed
update-alternatives --set iptables /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

#### 2. Service Won't Start

**Symptoms**: `systemctl status shadowsocks-libev@7001` shows failure

**Check**:
```bash
# Verify config file exists
ls -la /etc/shadowsocks-libev/config.d/7001.json

# Check UFW rule exists
ufw status | grep 7001

# View service logs
journalctl -u shadowsocks-libev@7001 -n 50
```

#### 3. Rules Lost After Reboot

**Symptoms**: Quota rules disappear after system restart

**Solutions**:
```bash
# Verify iptables-persistent is installed
dpkg -l | grep iptables-persistent

# Check rules files exist
ls -la /etc/iptables/rules.v4
ls -la /etc/iptables/rules.v6

# Manually save rules
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6
```

#### 4. QR Code Not Generated

**Symptoms**: No QR code in output

**Solutions**:
```bash
# Check if qrencode is installed
command -v qrencode

# Install if missing
apt-get install -y qrencode
```

### Log Locations

- **Service logs**: `journalctl -u shadowsocks-libev@<port>`
- **Quota reset logs**: `/var/log/quota-reset.log`
- **UFW logs**: `journalctl -u ufw`

### Performance Monitoring

```bash
# Monitor network usage per port
ss -tuln | grep :7001

# Check quota consumption
iptables -L INPUT -n -v | grep quota

# Monitor system resources
htop
iotop
```

## Security Considerations

### Outbound Traffic Caveats

**Important**: The quota system only meters traffic to/from the Shadowsocks ports. It does NOT:

- Limit outbound traffic from other services
- Prevent users from running their own proxy servers
- Control bandwidth usage of other applications

### Security Best Practices

1. **Regular Updates**: Keep system and packages updated
2. **Firewall Rules**: UFW provides basic protection
3. **Service Isolation**: Each user runs in separate systemd service
4. **Configuration Security**: Config files have restricted permissions (600)
5. **Log Monitoring**: Monitor service logs for unusual activity

### Network Security

```bash
# Check for unauthorized connections
netstat -tuln | grep :700

# Monitor quota usage
./reset-quota.sh --show

# Review UFW rules
ufw status numbered
```

## Advanced Configuration

### Custom Quota Values

```bash
# Add user with custom quota
./add-user.sh example.com user@example.com 100

# Reset to custom quota
./reset-quota.sh 7001 50
```

### Port Range Configuration

Edit `add-user.sh` to change the port range:

```bash
BASE_PORT=7000  # Start port
# Ports 7000-9000 are used
```

### Custom Systemd Settings

Modify `shadowsocks-libev@.service` for custom settings:

```ini
[Service]
# Custom resource limits
LimitNOFILE=65536
# Custom restart policy
Restart=always
RestartSec=10s
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support

For issues and questions:

1. Check the troubleshooting section
2. Review service logs
3. Verify configuration files
4. Test with minimal configuration

## Changelog

### v1.0.0
- Initial release
- Traffic quota support
- IPv6 compatibility
- UFW integration
- Systemd template support
- QR code generation
- User management scripts 