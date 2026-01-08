# EasyHole - WireGuard Easy + Pi-hole + DNS Server

Complete VPN solution with ad-blocking and privacy-focused DNS. This setup combines:
- **wg-easy**: Easy WireGuard VPN management with web UI
- **Pi-hole**: Network-wide ad blocking
- **Technitium DNS Server**: Privacy-focused recursive DNS resolver

All built from [wg-easy](https://github.com/wg-easy/wg-easy) source with configurable version control.

## Quick Start (TL;DR)

```bash
# 1. Configure environment (optional - defaults work for testing)
cp .env.example .env
nano .env  # Change passwords!

# 2. Build wg-easy from source
./build.sh

# 3. Start all services
docker compose up -d

# 4. Check status
docker compose ps
```

**Access:**
- **WireGuard UI**: http://localhost:51821
- **Pi-hole**: http://10.2.0.100/admin (via VPN)
- **DNS Server**: http://10.2.0.200:5380 (via VPN)

## Features

- 🔒 **Secure VPN** - WireGuard with easy peer management
- 🚫 **Ad Blocking** - Network-wide via Pi-hole
- 🔐 **Privacy DNS** - Recursive DNS resolution (no upstream providers)
- 🏗️ **Version Control** - Build wg-easy from any tag/commit
- 💾 **Persistent Data** - Local directories for easy backup
- 🐳 **Docker Compose** - Simple orchestration
- 📝 **Well Documented** - Complete setup guide

## Architecture

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

**DNS Flow:**
1. VPN clients use Pi-hole (10.2.0.100) as primary DNS
2. Pi-hole blocks ads and forwards to DNS Server (10.2.0.200)
3. DNS Server performs recursive DNS resolution for privacy

**Network:** All services run on the `10.2.0.0/24` private network

## Repository Structure

```
easyhole/
├── docker-compose.yml      # Service orchestration
├── .env                    # Your configuration (create from .env.example)
├── .env.example            # Configuration template
├── build.sh                # Build script for wg-easy
├── README.md               # This file
├── .gitignore              # Git exclusions
├── wg-easy/                # Cloned by build.sh (auto-created)
└── Data directories (auto-created on first run):
    ├── dns-server/         # Technitium DNS Server data
    ├── etc-pihole/         # Pi-hole configuration
    ├── etc-dnsmasq.d/      # dnsmasq configuration
    └── config/             # WireGuard keys and configs
```

## Installation

### Prerequisites

- Docker and Docker Compose
- Git
- NET_ADMIN and SYS_MODULE capabilities (configured in docker-compose.yml)
- If using Podman, uncomment the NET_RAW capability in docker-compose.yml

### Setup Steps

1. **Clone the repository**

   ```bash
   git clone https://github.com/lost-illusion/easyhole.git
   cd easyhole
   ```

2. **Configure environment**

   ```bash
   cp .env.example .env
   nano .env
   ```

   **IMPORTANT**: Change default passwords!
   ```bash
   WEBPASSWORD=your_secure_password          # Pi-hole admin
   DNS_SERVER_ADMIN_PASSWORD=your_password   # DNS Server admin
   ```

3. **Optional: Choose wg-easy version**

   Edit `.env` to change the version:
   ```bash
   WG_EASY_TAG=v15.1.0  # Or any tag/commit/branch
   ```

4. **Build wg-easy**

   ```bash
   ./build.sh
   ```

   This script will:
   - Clone wg-easy repository (if not exists)
   - Fetch latest tags
   - Checkout specified version
   - Build Docker image

5. **Start services**

   ```bash
   docker compose up -d
   ```

6. **Verify all services are running**

   ```bash
   docker compose ps
   ```

   You should see 3 services running: dns-server, pihole, wg-easy

## Configuration

### Network Architecture

All services run on the `10.2.0.0/24` private network:
- **dns-server**: 10.2.0.200 (Technitium DNS Server)
- **pihole**: 10.2.0.100 (Pi-hole)
- **wg-easy**: 10.2.0.3 (WireGuard VPN)

VPN clients are configured to use Pi-hole (10.2.0.100) as their DNS server automatically.

### Environment Variables (.env)

```bash
# WireGuard Easy version to build
WG_EASY_TAG=v15.1.0          # Git tag/commit to build from

# WireGuard settings
SERVERPORT=51820              # VPN port (UDP)
WGUI_PORT=51821               # Web UI port (TCP)
TZ=UTC                        # Timezone

# Pi-hole settings
WEBPASSWORD=admin             # Change this!
PIHOLE_DNS=10.2.0.200         # DNS Server IP
ServerIP=10.2.0.100           # Pi-hole IP
DNS1=10.2.0.200               # Primary upstream DNS
DNS2=10.2.0.200               # Secondary upstream DNS

# DNS Server settings
DNS_SERVER_ADMIN_PASSWORD=admin  # Change this!
```

**IMPORTANT**: Change the default passwords before deployment!

### Additional wg-easy Configuration

Edit the `environment` section in `docker-compose.yml` for advanced options:

```yaml
environment:
  - WG_DEFAULT_DNS=10.2.0.100
  - PORT=51821
  - HOST=0.0.0.0
  - INSECURE=false
```

See the [wg-easy documentation](https://github.com/wg-easy/wg-easy) for all available options.

## Usage

### Setting Up VPN Clients

1. **Access WireGuard UI**

   Open http://localhost:51821 in your browser

2. **Create a client/peer**

   Click "New Client" and give it a name

3. **Download configuration**

   - Download the `.conf` file, or
   - Scan the QR code with WireGuard mobile app

4. **Connect**

   Import the configuration into your WireGuard client and connect

**DNS is automatically configured** - clients will use Pi-hole (10.2.0.100) for ad-blocking

### Accessing Services via VPN

Once connected to the VPN:

- **Pi-hole Admin**: http://10.2.0.100/admin
- **DNS Server Console**: http://10.2.0.200:5380
- **WireGuard UI**: http://10.2.0.3:51821

**Benefits:**
- All DNS queries go through Pi-hole (automatic ad-blocking)
- View blocked domains and statistics in Pi-hole dashboard
- Configure DNS settings in DNS Server console

### Common Commands

```bash
# View logs from all services
docker compose logs -f

# View specific service logs
docker compose logs -f wg-easy
docker compose logs -f pihole
docker compose logs -f dns-server

# Restart services
docker compose restart

# Restart specific service
docker compose restart pihole

# Stop all services
docker compose down

# Stop and remove all data (CAUTION!)
docker compose down -v

# Update to different wg-easy version
# 1. Edit .env and change WG_EASY_TAG
# 2. Rebuild
./build.sh
# 3. Recreate containers
docker compose up -d --force-recreate wg-easy
```

## Changing Versions

To build a different version of wg-easy:

1. Update the `WG_EASY_TAG` in `.env`
   ```bash
   WG_EASY_TAG=v15.2.0  # or any tag/commit
   ```

2. Run build script
   ```bash
   ./build.sh
   ```

3. Restart the container
   ```bash
   docker compose up -d
   ```

You can use:
- **Release tags**: `v15.1.0`, `v15.0.0-beta.13`, etc.
- **Commit hashes**: `abc1234`
- **Branch names**: `main`, `develop`, etc.

## Ports

- `51820/udp` - WireGuard VPN port (configurable via SERVERPORT)
- `51821/tcp` - WireGuard Web UI (configurable via WGUI_PORT)

**Note**: Pi-hole and DNS Server web interfaces are only accessible via VPN on their internal IPs (no external ports exposed).

## DNS Configuration Details

### Default Setup (Privacy-Focused)

- **VPN clients** use Pi-hole (10.2.0.100) as primary DNS
- **Pi-hole** forwards to DNS Server (10.2.0.200) for recursive resolution
- **DNS Server** performs recursive DNS queries directly to root servers
- This provides **maximum privacy** - no DNS queries go to third-party providers

### Using Upstream DNS Providers (Optional)

If you prefer to use Cloudflare, Google, or other DNS providers:

1. Connect to VPN
2. Access DNS Server console at http://10.2.0.200:5380
3. Go to Settings → Forwarders
4. Add your preferred DNS servers (e.g., 1.1.1.1, 8.8.8.8)

### Testing DNS Resolution

```bash
# Test DNS resolution (from VPN client)
nslookup google.com 10.2.0.100

# Test ad blocking (should be blocked)
nslookup ads.google.com 10.2.0.100

# Verify you're routing through VPN
curl ifconfig.me
```

## Data Persistence

All service data is stored in local directories:
- **dns-server/** - DNS Server configuration and zones
- **etc-pihole/** - Pi-hole settings, blocklists, and statistics
- **etc-dnsmasq.d/** - Custom dnsmasq configurations
- **config/** - WireGuard keys and peer configurations

These directories are automatically created and populated on first run. They are excluded from git via `.gitignore` to protect sensitive data.

**Backup**: Simply backup these directories to preserve your configuration and data.

**Restore**: Copy the directories back and run `docker compose up -d`

## Troubleshooting

### Services won't start

```bash
# Check if WireGuard ports are already in use
sudo lsof -i :51820
sudo lsof -i :51821

# Note: Pi-hole and DNS Server have no exposed ports (only accessible via VPN)

# Check container status
docker compose ps

# View error logs
docker compose logs
```

### DNS not working

- Verify all containers are running: `docker compose ps`
- Check Pi-hole is using correct upstream: `docker logs pihole`
- Verify DNS Server is accessible: `docker logs dns-server`
- Test DNS directly:
  ```bash
  docker exec pihole dig google.com @127.0.0.1
  docker exec dns-server dig google.com @127.0.0.1
  ```

### Can't access web interfaces

- **WireGuard UI**: Check if ports ${SERVERPORT} and ${WGUI_PORT} are available
- **Pi-hole/DNS Server**: Must be accessed via VPN (no external ports exposed)
- Check firewall rules on host machine
- Verify containers are on correct network: `docker network inspect easyhole_private_network`

### Pi-hole shows no queries

- Verify WireGuard clients are configured with correct DNS (10.2.0.100)
- Check client is actually routing through VPN: `curl ifconfig.me`
- Verify VPN is connected and active

### Can't access Pi-hole admin

- Make sure you're connected to the VPN first
- Pi-hole's internal IP (10.2.0.100) is only accessible via VPN
- There is no external port mapping for Pi-hole by default

## Notes

- Uses original wg-easy Dockerfile with buildable version control
- Pi-hole and DNS Server use official Docker images
- All services configured for automatic restart
- IPv6 enabled by default on WireGuard
- DNS Server allows recursion for private networks (10.0.0.0/8, 192.168.1.0/24)
- All configuration data stored in local directories for easy backup
- Sensitive data (.env, configs, keys) excluded from git

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project configuration is provided as-is. Individual components maintain their own licenses:
- [wg-easy](https://github.com/wg-easy/wg-easy)
- [Pi-hole](https://github.com/pi-hole/pi-hole)
- [Technitium DNS Server](https://github.com/TechnitiumSoftware/DnsServer)
