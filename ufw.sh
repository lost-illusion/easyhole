#!/bin/bash
# ufw.sh — configure UFW for easyhole, then keep the WireGuard rule
# (comment 'easyhole') in sync with $SERVERPORT from .env.
#
# First run: prompts for SSH port, applies default deny-in/allow-out,
# allows SSH (no comment, user owns it), allows $SERVERPORT/udp tagged
# 'easyhole', enables UFW.
#
# Subsequent runs: only the easyhole-tagged WG rule is touched. SSH and
# defaults are never modified.
#
# NOTE: UFW is host-level only. Cloud providers may have a separate
# external firewall (security group) that also needs $SERVERPORT/udp open.
# Also: Docker bypasses UFW for published ports, so the WG allow rule is
# documentation of intent rather than enforcement.
set -euo pipefail

log() { echo "ufw: $*"; }

# 1. Platform gate
if [ "$(uname -s)" != "Linux" ]; then
    exit 0
fi

# 2. ufw available
if ! command -v ufw >/dev/null 2>&1; then
    echo "ERROR: ufw not found. Install with: apt install ufw"
    exit 1
fi

# 3. Root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: ufw.sh requires root. Run: sudo ./ufw.sh"
    exit 1
fi

# 4. .env present
if [ ! -f .env ]; then
    echo "ERROR: .env not found. Run ./build.sh first."
    exit 1
fi

# 5. Load .env (same one-liner as build.sh)
export $(grep -v '^#' .env | sed 's/#.*$//' | sed '/^$/d' | xargs)

# 6. Validate SERVERPORT
if [ -z "${SERVERPORT:-}" ] || ! [[ "$SERVERPORT" =~ ^[0-9]+$ ]] \
   || [ "$SERVERPORT" -lt 1 ] || [ "$SERVERPORT" -gt 65535 ]; then
    echo "ERROR: SERVERPORT in .env must be a number 1..65535 (got: '${SERVERPORT:-}')"
    exit 1
fi

UFW_STATUS="$(ufw status verbose 2>/dev/null || true)"

# ── Update mode ─────────────────────────────────────────────────────────
if echo "$UFW_STATUS" | grep -q 'easyhole'; then
    OLD_PORT=$(echo "$UFW_STATUS" \
        | awk "/easyhole/ && /\\/udp/ {print \$1; exit}" \
        | sed 's|/udp$||')

    if [ -z "$OLD_PORT" ]; then
        echo "ERROR: found 'easyhole' marker in ufw status but couldn't parse the port. Inspect 'ufw status verbose' manually."
        exit 1
    fi

    if [ "$OLD_PORT" = "$SERVERPORT" ]; then
        log "OK: easyhole rule already current (${SERVERPORT}/udp)"
        exit 0
    fi

    log "easyhole rule out of date (was ${OLD_PORT}/udp, .env says ${SERVERPORT}/udp)"
    log "  - delete ${OLD_PORT}/udp"
    ufw delete allow "${OLD_PORT}/udp"
    log "  + allow ${SERVERPORT}/udp (comment 'easyhole')"
    ufw allow "${SERVERPORT}/udp" comment 'easyhole'

    log "status:"
    ufw status verbose
    exit 0
fi

# ── First-run mode ──────────────────────────────────────────────────────
if [ ! -t 0 ]; then
    echo "ERROR: first-run setup requires an interactive terminal (need to confirm SSH port)."
    exit 1
fi

DETECTED_SSH=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' \
    /etc/ssh/sshd_config 2>/dev/null || true)
DETECTED_SSH="${DETECTED_SSH:-22}"

SSH_PORT=""
for _ in 1 2 3; do
    read -r -p "SSH port [${DETECTED_SSH}]: " SSH_PORT
    SSH_PORT="${SSH_PORT:-$DETECTED_SSH}"
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ]; then
        break
    fi
    echo "  invalid port, try again"
    SSH_PORT=""
done

if [ -z "$SSH_PORT" ]; then
    echo "ERROR: no valid SSH port after 3 attempts."
    exit 1
fi

log "applying first-run config"
log "  + allow ${SSH_PORT}/tcp"
ufw allow "${SSH_PORT}/tcp"
log "  + allow ${SERVERPORT}/udp (comment 'easyhole')"
ufw allow "${SERVERPORT}/udp" comment 'easyhole'
log "  + default deny incoming"
ufw default deny incoming
log "  + default allow outgoing"
ufw default allow outgoing
log "  + enable"
ufw --force enable

log "status:"
ufw status verbose
