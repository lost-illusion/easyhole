#!/bin/bash
# awg-params.sh — fill every AmneziaWG obfuscation parameter in the wg-easy DB.
#
# wg-easy only generates single-value H1-H4 on first boot and leaves S3/S4,
# H ranges and I1-I5 empty. This script writes randomized AmneziaWG 2.x values
# for all of them (server interface + defaults for new clients).
#
# Usage: sudo ./awg-params.sh [--awg3] [--force]
#   --awg3   also set a HeaderProtectionKey (AmneziaWG 3.x; 2.x clients can't connect)
#   --force  re-roll parameters that are already filled. S1-S4/H1-H4 must match on
#            both ends, so every existing client has to re-download its config.
#
# Run after the first `docker compose up -d` (the DB must exist). Stops wg-easy
# while writing, backs up the DB next to it, then starts wg-easy again.
set -euo pipefail

cd "$(dirname "$0")"
DB="./config/wg-easy.db"
AWG3=0
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --awg3) AWG3=1 ;;
        --force) FORCE=1 ;;
        *) echo "Usage: $0 [--awg3] [--force]"; exit 1 ;;
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

python3 -I - "$DB" "$AWG3" "$FORCE" <<'PY'
import base64
import secrets
import sqlite3
import sys

db_path, awg3, force = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
rnd = secrets.SystemRandom()

db = sqlite3.connect(db_path)
row = db.execute("SELECT s3, i1 FROM interfaces_table WHERE name='wg0'").fetchone()
if row is None:
    sys.exit("ERROR: interface wg0 not found in DB")
if any(v is not None for v in row) and not force:
    sys.exit("Parameters already filled. Use --force to re-roll (existing clients must re-download configs).")

jc = rnd.randint(4, 12)
jmin = rnd.randint(8, 40)
jmax = rnd.randint(jmin + 40, 120)

# Padded message sizes must all differ: init 148+S1, resp 92+S2, cookie 64+S3, data 32+S4.
# S4 pads every data packet; keep it <=16 so a 1420 MTU + overhead stays under 1500.
while True:
    s1, s2, s3 = (rnd.randint(15, 150) for _ in range(3))
    s4 = rnd.randint(4, 16)
    if len({148 + s1, 92 + s2, 64 + s3, 32 + s4}) == 4:
        break

# H1-H4: four disjoint ranges, one per quarter of [5, 2^31-1], shuffled.
lo, hi = 5, 2**31 - 1
band = (hi - lo) // 4
hs = []
for b in range(4):
    width = rnd.randint(10**6, 10**8)
    start = lo + b * band + rnd.randint(0, band - width - 1)
    hs.append(f"{start}-{start + width}")
rnd.shuffle(hs)

# I1: QUIC v1 Initial look-alike (1208 bytes); I2-I5: short-header style junk
# using the timestamp, counter, random-char and random-digit tags.
i1 = "<b 0xc30000000108><r 8><b 0x08><r 8><b 0x00449e><r 1182>"
i2 = f"<b 0x4{rnd.randint(0, 15):x}><r 8><t><r {rnd.randint(40, 80)}>"
i3 = f"<b 0x4{rnd.randint(0, 15):x}><r 8><c><r {rnd.randint(80, 140)}>"
i4 = f"<b 0x4{rnd.randint(0, 15):x}><r 8><rc {rnd.randint(16, 32)}><r {rnd.randint(24, 64)}>"
i5 = f"<b 0x4{rnd.randint(0, 15):x}><r 8><rd {rnd.randint(8, 24)}><r {rnd.randint(32, 96)}>"

hpk = base64.b64encode(secrets.token_bytes(32)).decode() if awg3 else None

with db:
    db.execute(
        "UPDATE interfaces_table SET j_c=?, j_min=?, j_max=?, s1=?, s2=?, s3=?, s4=?,"
        " h1=?, h2=?, h3=?, h4=?, i1=?, i2=?, i3=?, i4=?, i5=? WHERE name='wg0'",
        (jc, jmin, jmax, s1, s2, s3, s4, *hs, i1, i2, i3, i4, i5),
    )
    if awg3:
        db.execute("UPDATE interfaces_table SET header_protection_key=? WHERE name='wg0'", (hpk,))
    db.execute(
        "UPDATE user_configs_table SET default_j_c=?, default_j_min=?, default_j_max=?,"
        " default_i1=?, default_i2=?, default_i3=?, default_i4=?, default_i5=? WHERE id='wg0'",
        (jc, jmin, jmax, i1, i2, i3, i4, i5),
    )
    clients = db.execute(
        "UPDATE clients_table SET j_c=?, j_min=?, j_max=?, i1=?, i2=?, i3=?, i4=?, i5=?",
        (jc, jmin, jmax, i1, i2, i3, i4, i5),
    ).rowcount

print(f"Jc={jc} Jmin={jmin} Jmax={jmax} S1-S4={s1}/{s2}/{s3}/{s4}")
print("H1-H4=" + " ".join(hs))
print(f"I1-I5 set; HeaderProtectionKey {'set' if awg3 else 'unset (2.x compatible)'}")
if clients:
    print(f"Updated {clients} existing client(s): they must re-download their configs.")
PY

trap - EXIT
echo "Starting wg-easy..."
docker compose start wg-easy
sleep 5
docker compose exec wg-easy awg show wg0 | grep -vE 'key:'
