# EasyHole - WireGuard Easy + Pi-hole + DNS Server

Complete VPN solution with ad-blocking and privacy-focused DNS. This setup combines:
- **wg-easy**: Easy WireGuard VPN management with web UI
- **Pi-hole**: Network-wide ad blocking
- **Technitium DNS Server**: Privacy-focused recursive DNS resolver

All built from [wg-easy](https://github.com/wg-easy/wg-easy) source with configurable version control.

## Architecture

```
Internet → WireGuard (wg-easy) → Pi-hole (Ad Blocking) → DNS Server (Recursive DNS)
```

**DNS Flow:**
1. VPN clients use Pi-hole (10.2.0.100) as primary DNS
2. Pi-hole blocks ads and forwards to DNS Server (10.2.0.200)
3. DNS Server performs recursive DNS resolution for privacy

## Structure

- `docker-compose.yml` - Complete stack configuration
- `.env` - Environment configuration
- `build.sh` - Build script for wg-easy from source
- `wg-easy/` - Cloned wg-easy repository
- `dns-server/` - Technitium DNS Server data (auto-created)
- `etc-pihole/` - Pi-hole configuration (auto-created)
- `etc-dnsmasq.d/` - dnsmasq configuration (auto-created)
- `config/` - WireGuard configuration (auto-created)

## Quick Start

1. **Configure the version** (optional)

   Edit `.env` to specify the tag or commit you want to build:
   ```bash
   WG_EASY_TAG=v15.1.0
   ```

2. **Build the image**

   ```bash
   ./build.sh
   ```

   This script will:
   - Fetch the latest tags from the repository
   - Check out the specified tag/commit
   - Build the Docker image

3. **Run the container**

   ```bash
   docker compose up -d
   ```

4. **Access the services**

   - **WireGuard UI**: http://localhost:51821 (default port, configurable via WGUI_PORT)
   - **Pi-hole Admin**: Connect to VPN, then http://10.2.0.100/admin (password: see `.env` WEBPASSWORD)
   - **DNS Server Console**: Connect to VPN, then http://10.2.0.200:5380 (password: see `.env` DNS_SERVER_ADMIN_PASSWORD)

## Configuration

### Network Architecture

All services run on the `10.2.0.0/24` private network:
- **dns-server**: 10.2.0.200 (Technitium DNS Server)
- **pihole**: 10.2.0.100 (Pi-hole)
- **wg-easy**: 10.2.0.3 (WireGuard VPN)

VPN clients are configured to use Pi-hole (10.2.0.100) as their DNS server automatically.

### Environment Variables (.env)

```bash
# WireGuard Easy version
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
  - PORT=51821
  - HOST=0.0.0.0
  - INSECURE=false
```

See the [wg-easy documentation](https://github.com/wg-easy/wg-easy) for all available options.

## Changing Versions

To build a different version:

1. Update the `WG_EASY_TAG` in `.env`
2. Run `./build.sh` again
3. Restart the container: `docker compose up -d`

You can use:
- Release tags: `v15.1.0`, `v15.0.0-beta.13`, etc.
- Commit hashes: `abc1234`
- Branch names: `main`, `develop`, etc.

## Ports

- `51820/udp` - WireGuard VPN port (configurable via SERVERPORT)
- `51821/tcp` - WireGuard Web UI (configurable via WGUI_PORT)

**Note**: Pi-hole and DNS Server web interfaces are only accessible via VPN on their internal IPs.

## Requirements

- Docker and Docker Compose
- NET_ADMIN and SYS_MODULE capabilities (configured in docker-compose.yml)
- If using Podman, uncomment the NET_RAW capability

## Using the VPN

Once connected to the VPN:

1. **Ad-blocking is automatic** - All DNS queries go through Pi-hole
2. **Access Pi-hole admin**: http://10.2.0.100/admin
3. **Access DNS Server**: http://10.2.0.200:5380
4. **View blocked domains**: Check Pi-hole dashboard for statistics

## DNS Configuration Details

- **VPN clients** use Pi-hole (10.2.0.100) as primary DNS
- **Pi-hole** forwards to DNS Server (10.2.0.200) for recursive resolution
- **DNS Server** performs recursive DNS queries (no upstream DNS providers)
- This provides **maximum privacy** - no DNS queries leave your control

To use upstream DNS providers (e.g., Cloudflare, Google):
1. Connect to VPN
2. Access DNS Server console at http://10.2.0.200:5380
3. Configure forwarders in Settings → Forwarders

## Data Persistence

All service data is stored in local directories:
- **dns-server/** - DNS Server configuration and zones
- **etc-pihole/** - Pi-hole settings, blocklists, and statistics
- **etc-dnsmasq.d/** - Custom dnsmasq configurations
- **config/** - WireGuard keys and peer configurations

These directories are automatically created and populated on first run. They are excluded from git via `.gitignore` to protect sensitive data.

**Backup**: Simply backup these directories to preserve your configuration and data.

## Notes

- Uses original wg-easy Dockerfile with buildable version control
- Pi-hole and DNS Server use official Docker images
- All services configured for automatic restart
- IPv6 enabled by default on WireGuard
- DNS Server allows recursion for private networks (10.0.0.0/8, 192.168.1.0/24)
- All configuration data stored in local directories for easy backup

## Troubleshooting

**DNS not working:**
- Verify all containers are running: `docker compose ps`
- Check Pi-hole is using correct upstream: `docker logs pihole`
- Verify DNS Server is accessible: `docker logs dns-server`

**Can't access web interfaces:**
- WireGuard UI: Check if ports ${SERVERPORT} and ${WGUI_PORT} are available
- Pi-hole/DNS Server: Must be accessed via VPN (no external ports exposed)
- Check firewall rules on host machine
- Verify containers are on correct network: `docker network inspect easyhole_private_network`

**Pi-hole shows no queries:**
- Verify WireGuard clients are configured with correct DNS (10.2.0.100)
- Check client is actually routing through VPN: `curl ifconfig.me`
