# Quick Start Guide

## Initial Setup

```bash
# 1. Configure environment (optional - defaults work fine for testing)
cp .env.example .env
nano .env  # Change passwords!

# 2. Build wg-easy from source
./build.sh

# 3. Start all services
docker compose up -d

# 4. Check status
docker compose ps
```

## Access Web Interfaces

| Service | URL | Default Password |
|---------|-----|------------------|
| WireGuard UI | http://localhost:51821 | (set in wg-easy) |
| Pi-hole Admin | http://10.2.0.100/admin (via VPN) | See `.env` WEBPASSWORD |
| DNS Server | http://10.2.0.200:5380 (via VPN) | See `.env` DNS_SERVER_ADMIN_PASSWORD |

## VPN Client Configuration

1. Open WireGuard UI at http://localhost:51821
2. Create a new client/peer
3. Download the configuration or scan QR code
4. Connect with your WireGuard client

**DNS is automatically configured** - clients will use:
- Primary: 10.2.0.100 (Pi-hole with ad-blocking)
- Secondary: 10.2.0.200 (DNS Server)

## Access Services via VPN

Once connected to VPN:
- Pi-hole: http://10.2.0.100/admin
- DNS Server: http://10.2.0.200:5380
- WireGuard UI: http://10.2.0.3:51821

## Data Directories

On first run, these directories will be automatically created and populated:
- `dns-server/` - DNS Server data
- `etc-pihole/` - Pi-hole configuration
- `etc-dnsmasq.d/` - dnsmasq configs
- `config/` - WireGuard configs and keys

**Important**: These directories contain sensitive data (keys, passwords) and are excluded from git.

## Common Commands

```bash
# View logs
docker compose logs -f

# View specific service logs
docker compose logs -f wg-easy
docker compose logs -f pihole
docker compose logs -f dns-server

# Restart services
docker compose restart

# Stop services
docker compose down

# Stop and remove volumes (CAUTION: deletes data)
docker compose down -v

# Update to different wg-easy version
# 1. Edit .env and change WG_EASY_TAG
# 2. Run ./build.sh
# 3. Run docker compose up -d
```

## Network Architecture

```
┌─────────────────────────────────────────────┐
│  VPN Client (Your Device)                   │
│  DNS: 10.2.0.100                            │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│  WireGuard (wg-easy)                        │
│  IP: 10.2.0.3                               │
│  Ports: 51820/udp, 51821/tcp                │
└──────────────────┬──────────────────────────┘
                   │ DNS Queries
                   ▼
┌─────────────────────────────────────────────┐
│  Pi-hole (Ad Blocking)                      │
│  IP: 10.2.0.100                             │
│  Web: http://10.2.0.100/admin               │
└──────────────────┬──────────────────────────┘
                   │ Non-blocked queries
                   ▼
┌─────────────────────────────────────────────┐
│  DNS Server (Recursive Resolution)          │
│  IP: 10.2.0.200                             │
│  Web: http://10.2.0.200:5380                │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
              Internet (Root DNS)
```

## Testing

```bash
# Test DNS resolution (from VPN client)
nslookup google.com 10.2.0.100

# Test ad blocking (should be blocked)
nslookup ads.google.com 10.2.0.100

# Check if connected to VPN
curl ifconfig.me
```

## Troubleshooting

**Services won't start:**
```bash
# Check if WireGuard ports are already in use
sudo lsof -i :51820
sudo lsof -i :51821

# Note: Pi-hole and DNS Server have no exposed ports (only accessible via VPN)
```

**DNS not resolving:**
```bash
# Check if all containers are running
docker compose ps

# Test DNS directly
docker exec pihole dig google.com @127.0.0.1
docker exec dns-server dig google.com @127.0.0.1
```

**Can't access Pi-hole:**
- Make sure you're connected to the VPN first
- Pi-hole's internal IP (10.2.0.100) is only accessible via VPN
- There is no external port mapping for Pi-hole by default
