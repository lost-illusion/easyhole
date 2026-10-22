#!/bin/bash
# awg-params.sh — fill every AmneziaWG obfuscation parameter in the wg-easy DB.
#
# wg-easy only generates single-value H1-H4 on first boot and leaves S3/S4,
# H ranges, I1-I5 and all AmneziaWG 3.x options empty. This script writes
# randomized values for all of them (server interface + defaults for new clients).
#
# Usage: sudo ./awg-params.sh [--awg3] [--force]
#        sudo ./awg-params.sh --sync-clients
#        sudo ./awg-params.sh --remove-client-defaults
#   --awg3          also fill the AmneziaWG 3.x options: HeaderProtectionKey,
#                   ContentPaddingAddition, RandomTrailers, DisableCookies and the
#                   timing ranges. 2.x clients can't connect to a 3.x server.
#                   On a server that already has 2.x values, only adds the 3.x ones.
#   --force         re-roll parameters that are already filled. S1-S4/H1-H4 must match
#                   on both ends, so every existing client has to re-download its config.
#   --sync-clients  copy the server's client-side values (Jc/Jmin/Jmax, I1-I5 and the
#                   3.x per-client options) to every existing client.
#   --remove-client-defaults
#                   remove the new-client defaults workaround (see below) once wg-easy
#                   has its own defaults for the 3.x per-client options.
#
# TEMPORARY WORKAROUND: wg-easy has no new-client defaults for the 3.x per-client
# options, so every mode except --remove-client-defaults also installs
# awg-client-defaults.mjs plus a wg0 PostUp hook that runs it. It creates an SQLite
# trigger that fills those options into each client created in the admin UI.
# Remove it with --remove-client-defaults once wg-easy supports them; this script
# prints a notice when it detects that.
#
# Run after the first `docker compose up -d` (the DB must exist). Stops wg-easy
# while writing, backs up the DB next to it, then starts wg-easy again.
set -euo pipefail

cd "$(dirname "$0")"
DB="./config/wg-easy.db"
MODE=fill
AWG3=0
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --awg3) AWG3=1 ;;
        --force) FORCE=1 ;;
        --sync-clients) MODE=sync ;;
        --remove-client-defaults) MODE=remove ;;
        *) echo "Usage: $0 [--awg3] [--force] | --sync-clients | --remove-client-defaults"; exit 1 ;;
    esac
done

if [ ! -f "$DB" ]; then
    echo "ERROR: $DB not found. Start the stack once (docker compose up -d) so wg-easy creates it."
    exit 1
fi
if [ ! -w "$DB" ]; then
    echo "ERROR: $DB is not writable. Run: sudo $0 $*"
    exit 1
fi
command -v python3 >/dev/null || { echo "ERROR: python3 not found"; exit 1; }

echo "Stopping wg-easy..."
docker compose stop wg-easy
trap 'echo "Starting wg-easy..."; docker compose start wg-easy' EXIT

BACKUP="$DB.bak-$(date +%Y%m%d-%H%M%S)"
cp -a "$DB" "$BACKUP"
echo "Backup: $BACKUP"

# ./config is mounted at /etc/wireguard, where the PostUp hook runs the script.
if [ "$MODE" = remove ]; then
    rm -f ./config/awg-client-defaults.mjs
else
    cp -f ./awg-client-defaults.mjs ./config/awg-client-defaults.mjs
fi

python3 -I - "$DB" "$MODE" "$AWG3" "$FORCE" <<'PY'
import base64
import secrets
import sqlite3
import sys

db_path, mode = sys.argv[1], sys.argv[2]
awg3, force = sys.argv[3] == "1", sys.argv[4] == "1"
rnd = secrets.SystemRandom()

# Columns a client may set for itself (copied from the interface to every client).
CLIENT_COLS = ["j_c", "j_min", "j_max", "i1", "i2", "i3", "i4", "i5",
               "content_padding_addition", "rekey_after_time", "rekey_timeout",
               "reject_after_time", "keepalive_timeout", "max_handshake_attempts",
               "disable_cookies"]
# Columns wg-easy keeps new-client defaults for (user_configs_table.default_*).
DEFAULT_COLS = ["j_c", "j_min", "j_max", "i1", "i2", "i3", "i4", "i5"]

# Workaround for missing wg-easy new-client defaults (see awg-client-defaults.mjs).
TRIGGER = "easyhole_awg_client_defaults"
HOOK = "node --no-warnings /etc/wireguard/awg-client-defaults.mjs || true;"

db = sqlite3.connect(db_path)


def post_up():
    row = db.execute("SELECT post_up FROM hooks_table WHERE id='wg0'").fetchone()
    if row is None:
        sys.exit("ERROR: no hooks for wg0 in DB")
    return row[0]


def install_hook():
    hooks = post_up()
    if HOOK in hooks:
        return
    hooks = hooks.rstrip()
    if hooks and not hooks.endswith(";"):
        hooks += ";"
    db.execute("UPDATE hooks_table SET post_up=? WHERE id='wg0'", (f"{hooks} {HOOK}".strip(),))
    print("Added wg0 PostUp hook: new clients get the 3.x per-client values")


def remove_hook():
    hooks = post_up().replace(HOOK, "").strip()
    db.execute("UPDATE hooks_table SET post_up=? WHERE id='wg0'", (hooks,))
    db.execute(f"DROP TRIGGER IF EXISTS {TRIGGER}")


def upstream_has_defaults():
    cols = [r[1] for r in db.execute("PRAGMA table_info(user_configs_table)")]
    return "default_content_padding_addition" in cols


def sync_clients():
    cols = ", ".join(CLIENT_COLS)
    values = db.execute(f"SELECT {cols} FROM interfaces_table WHERE name='wg0'").fetchone()
    sets = ", ".join(f"{c}=?" for c in CLIENT_COLS)
    return db.execute(f"UPDATE clients_table SET {sets}", values).rowcount


HP_MIN_S = 12  # header protection nonce size: S1-S4 must each be at least this


def span(lo_min, lo_max, width_min, width_max):
    lo = rnd.randint(lo_min, lo_max)
    return f"{lo}-{lo + rnd.randint(width_min, width_max)}"


def gen_2x():
    p = {}
    p["j_c"] = rnd.randint(4, 12)
    p["j_min"] = rnd.randint(8, 40)
    p["j_max"] = rnd.randint(p["j_min"] + 40, 120)

    # Padded message sizes must all differ: init 148+S1, resp 92+S2, cookie 64+S3, data 32+S4.
    # S4 pads every data packet; keep it <=16 so a 1420 MTU + overhead stays under 1500.
    # 3.x HeaderProtectionKey needs every S >= 12 (the kernel rejects wg0 with EINVAL).
    while True:
        s = [rnd.randint(15, 150) for _ in range(3)] + [rnd.randint(HP_MIN_S, 16)]
        if len({148 + s[0], 92 + s[1], 64 + s[2], 32 + s[3]}) == 4:
            break
    p.update(s1=s[0], s2=s[1], s3=s[2], s4=s[3])

    # H1-H4: four disjoint ranges, one per quarter of [5, 2^31-1], shuffled.
    lo, hi = 5, 2**31 - 1
    band = (hi - lo) // 4
    hs = []
    for b in range(4):
        width = rnd.randint(10**6, 10**8)
        start = lo + b * band + rnd.randint(0, band - width - 1)
        hs.append(f"{start}-{start + width}")
    rnd.shuffle(hs)
    p.update(h1=hs[0], h2=hs[1], h3=hs[2], h4=hs[3])

    # I1: QUIC v1 Initial look-alike (1208 bytes); I2-I5: short-header style junk.
    # Only tags both the kernel module and amneziawg-go (used by the phone/desktop
    # apps) parse: b, t, r, rc, rd. The kernel-only <c> counter tag makes every
    # amneziawg-go client fail with "unknown tag <c>".
    p["i1"] = "<b 0xc30000000108><r 8><b 0x08><r 8><b 0x00449e><r 1182>"
    p["i2"] = f"<b 0x4{rnd.randint(0, 15):x}><r 8><t><r {rnd.randint(40, 80)}>"
    p["i3"] = f"<b 0x4{rnd.randint(0, 15):x}><r 8><rd {rnd.randint(4, 8)}><t><r {rnd.randint(80, 140)}>"
    p["i4"] = f"<b 0x4{rnd.randint(0, 15):x}><r 8><rc {rnd.randint(16, 32)}><r {rnd.randint(24, 64)}>"
    p["i5"] = f"<b 0x4{rnd.randint(0, 15):x}><r 8><rd {rnd.randint(8, 24)}><r {rnd.randint(32, 96)}>"
    return p


def gen_3x():
    return {
        # Encrypts the obfuscated header fields; must match on both ends.
        "header_protection_key": base64.b64encode(secrets.token_bytes(32)).decode(),
        # Random extra padding per data packet. The kernel caps it at the largest
        # packet seen on the path (udp_window), so it never pushes past the MTU.
        "content_padding_addition": span(0, 16, 64, 192),
        # Random-length trailers on handshake packets; must match on both ends.
        "random_trailers": 1,
        # No cookie-reply packets under load: one less fixed-size fingerprint.
        "disable_cookies": 1,
        # Jitter the WireGuard timers (stock: 120/180/5/10s, 18 attempts) so rekeys
        # don't happen on a fixed, recognizable schedule. RekeyAfterTime stays well
        # below RejectAfterTime so keys always refresh before they expire.
        "rekey_after_time": span(95, 110, 15, 30),
        "reject_after_time": span(170, 180, 10, 25),
        "rekey_timeout": span(4, 5, 1, 2),
        "keepalive_timeout": span(8, 10, 2, 5),
        "max_handshake_attempts": span(15, 18, 2, 5),
    }


if mode == "remove":
    with db:
        remove_hook()
    print(f"Removed the wg0 PostUp hook and {TRIGGER}.")
    if not upstream_has_defaults():
        print("NOTE: this wg-easy version has no 3.x new-client defaults: run --sync-clients after adding clients.")
    sys.exit(0)

if upstream_has_defaults():
    print("NOTICE: wg-easy now has its own new-client defaults for the 3.x options.")
    print("        Remove the workaround: sudo ./awg-params.sh --remove-client-defaults")
else:
    with db:
        install_hook()

if mode == "sync":
    with db:
        n = sync_clients()
    print(f"Synced client-side values to {n} client(s): they must re-download their configs.")
    sys.exit(0)

row = db.execute("SELECT s3, i1, header_protection_key FROM interfaces_table WHERE name='wg0'").fetchone()
if row is None:
    sys.exit("ERROR: interface wg0 not found in DB")

# Already-filled groups are kept unless --force, so `--awg3` on a 2.x setup
# only adds the 3.x options and existing S/H values stay valid.
do_2x = force or (row[0] is None and row[1] is None)
do_3x = awg3 and (force or row[2] is None)
if not do_2x and not do_3x:
    sys.exit("Parameters already filled. Use --force to re-roll (existing clients must re-download configs).")
if do_3x and not do_2x:
    s = db.execute("SELECT s1, s2, s3, s4 FROM interfaces_table WHERE name='wg0'").fetchone()
    if any(v is not None and v < HP_MIN_S for v in s):
        sys.exit(f"ERROR: S1-S4 = {s}, but HeaderProtectionKey needs each >= {HP_MIN_S}.\n"
                 "       Re-roll with: sudo ./awg-params.sh --awg3 --force (clients must re-download configs)")

p = {}
if do_2x:
    p.update(gen_2x())
if do_3x:
    p.update(gen_3x())

with db:
    sets = ", ".join(f"{k}=?" for k in p)
    db.execute(f"UPDATE interfaces_table SET {sets} WHERE name='wg0'", list(p.values()))
    if do_2x:
        sets = ", ".join(f"default_{c}=?" for c in DEFAULT_COLS)
        db.execute(f"UPDATE user_configs_table SET {sets} WHERE id='wg0'", [p[c] for c in DEFAULT_COLS])
    clients = sync_clients()

for k, v in p.items():
    print(f"  {k} = {'(set)' if k == 'header_protection_key' else v}")
if not awg3:
    print("3.x options left as they were (unset = AmneziaWG 2.x compatible)")
if clients:
    print(f"Updated {clients} existing client(s): they must re-download their configs.")
PY

trap - EXIT
echo "Starting wg-easy..."
docker compose start wg-easy
for i in $(seq 15); do
    docker compose exec wg-easy awg show wg0 >/dev/null 2>&1 && break
    if [ "$i" -eq 15 ]; then
        echo "ERROR: wg0 did not come up. Check: docker compose logs wg-easy | grep -A3 awg-quick"
        exit 1
    fi
    sleep 2
done
docker compose exec wg-easy awg show wg0 | grep -vE 'key:'

# The PostUp hook creates the trigger when wg0 comes up; confirm it did.
if [ "$MODE" != remove ] && grep -q "awg-client-defaults.mjs" ./config/wg0.conf 2>/dev/null; then
    for _ in $(seq 10); do
        if python3 -I - "$DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
sql = "SELECT 1 FROM sqlite_master WHERE type='trigger' AND name='easyhole_awg_client_defaults'"
sys.exit(0 if db.execute(sql).fetchone() else 1)
PY
        then
            echo "OK: new clients get the 3.x per-client values automatically"
            exit 0
        fi
        sleep 2
    done
    echo "WARNING: client defaults trigger not found. Check: docker compose logs wg-easy | grep easyhole"
fi
