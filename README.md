# EasyHole — WireGuard Easy + Pi-hole + Technitium DNS

A self-hosted, all-in-one privacy stack:

- **wg-easy** — WireGuard VPN with a web admin UI (built from source, version-pinned)
- **Pi-hole** — network-wide ad blocking
- **Technitium DNS Server** — recursive DNS resolution (no third-party upstreams)

Built from [wg-easy](https://github.com/wg-easy/wg-easy) source so you can pin to any tag/commit.

---

## Quick Start

```bash
# 1. Configure
cp .env.example .env
nano .env                    # set INIT_HOST, INIT_PASSWORD, WEBPASSWORD, DNS_SERVER_ADMIN_PASSWORD

# 2. Build wg-easy
./build.sh

# 3. Launch
docker compose up -d

# 4. Reach the admin UI from your laptop (UI is bound to 127.0.0.1 on the host)
ssh -L 51821:127.0.0.1:51821 user@your-host
# then open http://localhost:51821
```

> **Why the SSH tunnel?** Docker port publishing bypasses UFW. Binding the admin UI to `127.0.0.1` on the host keeps it off the public internet regardless of firewall state. The WireGuard UDP port (`SERVERPORT`) is intentionally public.

---

## Architecture

```
┌─────────────────────────────────────────────┐
│  VPN Client (your device)                   │
│  DNS: 10.2.0.100                            │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────┐
│  WireGuard (wg-easy)         10.2.0.3       │
│  Public UDP: ${SERVERPORT}                  │
│  Admin UI:   127.0.0.1:${WGUI_PORT}         │
└──────────────────┬──────────────────────────┘
                   │ DNS queries
                   ▼
┌─────────────────────────────────────────────┐
│  Pi-hole (ad blocker)        10.2.0.100     │
└──────────────────┬──────────────────────────┘
                   │ Non-blocked queries
                   ▼
┌─────────────────────────────────────────────┐
│  Technitium DNS (recursive)  10.2.0.200     │
└──────────────────┬──────────────────────────┘
                   ▼
              Internet (root DNS)
```

All services share a private Docker bridge `10.2.0.0/24`. WireGuard peers live on `10.8.0.0/24` (configurable via `INIT_IPV4_CIDR`).

---

## Repository Layout

```
easyhole/
├── docker-compose.yml      # Service definitions
├── .env / .env.example     # Configuration
├── build.sh                # Clones + builds wg-easy from a pinned tag
├── wg-easy/                # Cloned by build.sh on first run
└── (created at runtime)
    ├── dns-server/         # Technitium data
    ├── etc-pihole/         # Pi-hole settings + blocklists
    ├── etc-dnsmasq.d/      # dnsmasq configs
    └── config/             # wg-easy SQLite DB + WireGuard keys
```

---

## Configuration

### Critical environment variables

The `.env` file is split into runtime values (always honored) and **first-boot init** values (applied only when `./config/` is empty).

| Variable                | What it controls                                                 | Type        |
| ----------------------- | ---------------------------------------------------------------- | ----------- |
| `WG_EASY_TAG`           | wg-easy git tag/commit to build                                  | runtime     |
| `SERVERPORT`            | Public UDP port for WireGuard (host **and** in-container listen) | runtime     |
| `WGUI_PORT`             | Admin web UI port (bound to `127.0.0.1` on host)                 | runtime     |
| `EXPERIMENTAL_AWG`      | Enable AmneziaWG support (auto-detects kernel module)            | runtime     |
| `INIT_ENABLED`          | Run unattended setup on first boot                               | first-boot  |
| `INIT_USERNAME`         | Admin username                                                   | first-boot  |
| `INIT_PASSWORD`         | Admin password — **change before first boot**                    | first-boot  |
| `INIT_HOST`             | Public hostname/IP for client `Endpoint =` line                  | first-boot  |
| `INIT_DNS`              | DNS handed to VPN clients (default: Pi-hole `10.2.0.100`)        | first-boot  |
| `INIT_ALLOWED_IPS`      | Client `AllowedIPs` (`10.2.0.0/24` split / `0.0.0.0/0,::/0` full)| first-boot  |
| `INIT_IPV4_CIDR`        | WireGuard peer subnet (default `10.8.0.0/24`)                    | first-boot  |
| `INIT_IPV6_CIDR`        | WireGuard peer IPv6 subnet                                       | first-boot  |
| `WEBPASSWORD`           | Pi-hole admin password — **change**                              | runtime     |
| `DNS_SERVER_ADMIN_PASSWORD` | Technitium admin password — **change**                       | runtime     |

> **First-boot init only fires once.** wg-easy stores its config in a SQLite DB under `./config/`. Once that DB exists, all `INIT_*` variables are ignored. To re-seed you must delete `./config/*` (which destroys all clients/keys).
>
> Changes made through the web UI after first boot persist in the DB — they will **not** be overwritten by editing `INIT_*` later.

### AmneziaWG host kernel module

`EXPERIMENTAL_AWG=true` only does anything if the host kernel has the `amneziawg` module loaded — wg-easy auto-detects via `modinfo amneziawg` at startup. Install methods:

- **`./install-awg.sh`** (recommended, included in this repo) — builds from upstream source via DKMS. Auto-runs as part of `./build.sh` and is safe to invoke repeatedly.
- The official `ppa:amnezia/ppa` PPA — built for Ubuntu `focal`, updated irregularly, and as of early 2026 was missing recent fixes for kernel use-after-free / memory corruption in `jp_spec_setup`. Source build is the safer path on a long-running VPS.

#### Behavior of `install-awg.sh`

| Situation                                       | What happens                                                |
| ----------------------------------------------- | ----------------------------------------------------------- |
| Not Linux (e.g., macOS dev box)                 | Silent exit                                                 |
| Not Debian/Ubuntu                               | One-line skip notice, exit 0                                |
| LXC container or no `/lib/modules/$(uname -r)`  | Skip with explanation (kernel modules can't be loaded here) |
| Module already loaded, ref matches `AWG_KERNEL_REF` | "OK: amneziawg already current ($SHA)"                  |
| Module loaded but upstream `master` moved       | WARNING with the upgrade command                            |
| Not running as root                             | Prints `sudo` instruction, exit 0                           |
| Root + all gates pass                           | `apt-get install` deps, `git clone`, `make dkms-install`, `dkms add/build/install`, `modprobe`, persist via `/etc/modules-load.d/amneziawg.conf` |

State file `/var/lib/easyhole/awg-installed-ref` records the SHA of the last successful install.

#### Manual invocation

```bash
sudo ./install-awg.sh                              # first install
sudo AWG_FORCE_REINSTALL=true ./install-awg.sh     # force rebuild (e.g., to pick up upstream master)
```

DKMS handles kernel upgrades automatically — when you boot a new kernel, the module is rebuilt against its headers.

### Why the variable rename (v15)

Earlier versions of wg-easy honored env vars like `WG_HOST`, `WG_DEFAULT_DNS`, `WG_ALLOWED_IPS`, `WG_PERSISTENT_KEEPALIVE`, `WG_MTU` at runtime. **wg-easy v15 removed them.** All those settings now live in the SQLite DB and are seeded once via the `INIT_*` family. If you migrated from an older `.env`, the legacy `WG_*` keys were silently ignored.

### Port behavior (important)

`INIT_PORT` sets **both** the in-container WireGuard listener AND the `Endpoint = host:PORT` line in generated client configs. They cannot be different via env vars. We pin `INIT_PORT=${SERVERPORT}` and use a Docker mapping of `${SERVERPORT}:${SERVERPORT}/udp` so the external port matches the listener and matches what clients dial.

If you later want a non-standard external port, change `SERVERPORT` in `.env` and re-create the container — the new port will propagate via the existing mapping (the DB-stored interface port still needs to be updated via the UI if the DB has already been seeded).

---

## Installation

### Prerequisites

- Docker + Docker Compose
- Git
- Linux host with `NET_ADMIN` and `SYS_MODULE` capabilities (already configured in `docker-compose.yml`)
- Podman users: uncomment the `NET_RAW` line in `docker-compose.yml`
- For AmneziaWG support: a Debian/Ubuntu host where you can `sudo`. Kernel headers and `dkms` are installed automatically by `install-awg.sh`.

### Steps

```bash
git clone https://github.com/lost-illusion/easyhole.git
cd easyhole

cp .env.example .env
$EDITOR .env                 # set INIT_HOST, all *PASSWORD* fields

./build.sh                   # clones + builds wg-easy from $WG_EASY_TAG
docker compose up -d
docker compose ps            # all 3 services should be 'running'
```

> **Always run `./build.sh` before `docker compose up -d`.** The script clones `wg-easy/` (which compose uses as a build context), runs `git fetch`, and warns if your pinned `WG_EASY_TAG` is behind the latest upstream stable release. Running `docker compose up -d --build` directly will fail on first install (no `wg-easy/` directory) and skips the upstream-version check.

### First connection

1. SSH-tunnel to the admin UI: `ssh -L 51821:127.0.0.1:51821 user@your-host`
2. Open <http://localhost:51821>, log in with `INIT_USERNAME` / `INIT_PASSWORD`
3. Create a client → download `.conf` or scan QR code
4. Import into the WireGuard app and connect

---

## Network Exposure

| Port            | Bound to host  | Purpose                                | Required from internet? |
| --------------- | -------------- | -------------------------------------- | ----------------------- |
| `SERVERPORT/udp`| `0.0.0.0`      | WireGuard data plane                   | Yes                     |
| `WGUI_PORT/tcp` | `127.0.0.1`    | wg-easy admin web UI                   | **No** (SSH tunnel)     |
| Pi-hole         | (none)         | Reachable only via VPN at `10.2.0.100` | No                      |
| Technitium      | (none)         | Reachable only via VPN at `10.2.0.200` | No                      |

> **UFW caveat:** Docker writes its own iptables rules into the `DOCKER` chain, which is evaluated before UFW's user chains. UFW rules do **not** apply to `0.0.0.0`-published Docker ports. We avoid the foot-gun by binding the admin UI to `127.0.0.1` and only publishing the WireGuard UDP port (which you want public anyway).

---

## Services Reachable Over the VPN

Once connected:

- Pi-hole admin: <http://10.2.0.100/admin>
- Technitium console: <http://10.2.0.200:5380>
- wg-easy UI (alternative to SSH tunnel): <http://10.2.0.3:51821>

---

## Common Commands

```bash
# Logs
docker compose logs -f
docker compose logs -f wg-easy

# Restart
docker compose restart
docker compose restart pihole

# Stop
docker compose down

# Stop and wipe volumes (DESTROYS clients/keys/Pi-hole data)
docker compose down -v

# Update wg-easy version
nano .env                    # change WG_EASY_TAG=...
./build.sh
docker compose up -d --force-recreate wg-easy

# Re-seed wg-easy from INIT_* (DESTROYS existing clients)
docker compose down
rm -rf ./config/*            # ⚠️ destroys SQLite DB and WireGuard keys
docker compose up -d
```

---

## DNS Flow

1. VPN client → Pi-hole (`10.2.0.100`) — ad/tracker blocking
2. Pi-hole → Technitium (`10.2.0.200`) — non-blocked queries
3. Technitium → root DNS — recursive resolution, no third-party

To use Cloudflare/Google upstreams instead of recursion: open the Technitium console (Settings → Forwarders) and add `1.1.1.1`, `8.8.8.8`, etc.

### Quick test

```bash
nslookup google.com 10.2.0.100         # should resolve
nslookup ads.google.com 10.2.0.100     # should be blocked (0.0.0.0)
curl ifconfig.me                       # should return your VPN host's IP
```

---

## Data Persistence

All state is on the host filesystem under the project directory:

- `dns-server/` — Technitium config + zones
- `etc-pihole/`, `etc-dnsmasq.d/` — Pi-hole settings, blocklists, stats
- `config/` — wg-easy SQLite DB + WireGuard keys

Backup = copy these directories. Restore = put them back and `docker compose up -d`. They are gitignored.

---

## Troubleshooting

### Services won't start

```bash
sudo lsof -i :${SERVERPORT}
sudo lsof -i :${WGUI_PORT}
docker compose ps
docker compose logs
```

### Generated client configs have the wrong port

If `Endpoint = host:51820` appears even though you set `SERVERPORT=51999`, the SQLite DB was seeded before you changed `SERVERPORT`. Either:

- change the port in the wg-easy UI (Interface settings), **or**
- wipe `./config/*` and let `INIT_*` re-seed (destroys clients)

### `INIT_*` changes seem to do nothing

`INIT_*` only fires when the wg-easy DB is empty. After the first boot, change settings in the web UI. To force re-seed: stop the stack, delete `./config/*`, restart.

### Admin UI not reachable

The UI is bound to `127.0.0.1` on the host. From outside, use SSH port-forwarding or change the bind in `docker-compose.yml` (e.g. to a LAN IP). Do **not** bind to `0.0.0.0` unless you've put TLS + auth in front of it.

### Pi-hole shows no queries

- Confirm the client is actually using the VPN (`curl ifconfig.me`)
- Confirm DNS is `10.2.0.100` in the client's tunnel config
- Check `docker logs pihole`

### Building wg-easy fails

`build.sh` clones `https://github.com/wg-easy/wg-easy` if the `wg-easy/` directory is missing, then checks out `WG_EASY_TAG`. If the build fails, check that the tag exists upstream and that Docker has enough memory.

---

## Notes

- IPv6 enabled in the WireGuard interface by default
- Technitium recursion is allowed only from `127.0.0.1`, `192.168.1.0/24`, and `10.0.0.0/8` — adjust in `docker-compose.yml` if your LAN differs
- `INSECURE=true` is set on wg-easy because the UI is bound to `127.0.0.1`; if you expose it publicly, set `INSECURE=false` and front it with TLS

---

## License

Project glue is provided as-is. Component licenses:

- [wg-easy](https://github.com/wg-easy/wg-easy)
- [Pi-hole](https://github.com/pi-hole/pi-hole)
- [Technitium DNS Server](https://github.com/TechnitiumSoftware/DnsServer)
