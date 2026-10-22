#!/bin/bash
# install-awg.sh — build/refresh the AmneziaWG kernel module on the host.
#
# Best-effort installer. Skips silently when the host can't or shouldn't run it
# (non-Linux, non-Debian/Ubuntu, container without modules, missing root, etc).
# Designed to be safe to invoke from build.sh on every run.
#
# Env:
#   AWG_KERNEL_REF        Git ref to build (default: v3.1.20260906)
#   AWG_FORCE_REINSTALL   Force rebuild even if module is already loaded
set -euo pipefail

REF="${AWG_KERNEL_REF:-v3.1.20260906}"
REPO="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"
DKMS_NAME="amneziawg"
DKMS_VER="1.0.0"
SRC_DIR="/usr/src/easyhole-awg-build"
STATE_DIR="/var/lib/easyhole"
STATE_FILE="$STATE_DIR/awg-installed-ref"
PERSIST_FILE="/etc/modules-load.d/amneziawg.conf"

log() { echo "install-awg: $*"; }

# 1. Platform gate
if [ "$(uname -s)" != "Linux" ]; then
    exit 0
fi

# 2. Distro gate
if [ ! -r /etc/os-release ]; then
    log "skip: /etc/os-release missing, can't identify distro"
    exit 0
fi
# shellcheck disable=SC1091
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) ;;
    *)
        log "skip: ${ID:-unknown} not supported (Debian/Ubuntu only); install AmneziaWG via your distro"
        exit 0
        ;;
esac

# 3. LXC / OpenVZ / no-modules gate
if [ ! -d "/lib/modules/$(uname -r)" ]; then
    log "skip: /lib/modules/$(uname -r) missing — kernel modules can't be loaded here"
    exit 0
fi
if grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
    log "skip: running inside an LXC container — kernel modules must come from the host"
    exit 0
fi

# Resolve target SHA (cheap, single network call, no clone)
resolve_remote_sha() {
    git ls-remote "$REPO" "$REF" 2>/dev/null | awk '{print $1; exit}'
}

TARGET_SHA="$(resolve_remote_sha || true)"
if [ -z "$TARGET_SHA" ]; then
    log "WARNING: could not resolve $REF on $REPO (network issue?); skipping"
    exit 0
fi
SHORT_TARGET="${TARGET_SHA:0:7}"

ppa_installed() {
    dpkg-query -W -f='${Status}' amneziawg-dkms 2>/dev/null | grep -q 'install ok installed'
}

# 4. Idempotence check
if modinfo amneziawg >/dev/null 2>&1 && [ -z "${AWG_FORCE_REINSTALL:-}" ]; then
    if ppa_installed; then
        log "WARNING: amneziawg comes from the PPA package amneziawg-dkms, not a source build"
        log "         to replace it with $REF ($SHORT_TARGET): sudo AWG_FORCE_REINSTALL=true ./install-awg.sh"
        exit 0
    fi
    INSTALLED_SHA=""
    [ -r "$STATE_FILE" ] && INSTALLED_SHA="$(cat "$STATE_FILE")"

    if [ "$INSTALLED_SHA" = "$TARGET_SHA" ]; then
        log "OK: amneziawg already current ($SHORT_TARGET)"
        exit 0
    fi
    SHORT_INSTALLED="${INSTALLED_SHA:0:7}"
    log "WARNING: amneziawg installed (${SHORT_INSTALLED:-unknown}) is behind $REF ($SHORT_TARGET)"
    log "         to upgrade: sudo AWG_FORCE_REINSTALL=true ./install-awg.sh"
    exit 0
fi

# 5. Root gate
if [ "$(id -u)" -ne 0 ]; then
    if modinfo amneziawg >/dev/null 2>&1; then
        log "amneziawg loaded but state unknown; sudo required to verify/refresh: sudo ./install-awg.sh"
    else
        log "amneziawg not installed; sudo required: sudo ./install-awg.sh"
    fi
    exit 0
fi

# 6. Install
log "installing amneziawg from $REF ($SHORT_TARGET)"

log "installing build dependencies (apt)"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    dkms git build-essential "linux-headers-$(uname -r)"

log "fetching source into $SRC_DIR"
rm -rf "$SRC_DIR"
git clone --quiet "$REPO" "$SRC_DIR"
git -C "$SRC_DIR" checkout --quiet "$REF"
RESOLVED_SHA="$(git -C "$SRC_DIR" rev-parse HEAD)"
SHORT_RESOLVED="${RESOLVED_SHA:0:7}"

# The PPA package registers the same DKMS name/version and owns
# /usr/src/amneziawg-1.0.0; left installed, its next apt upgrade would
# overwrite our source tree and DKMS would rebuild the PPA module.
if ppa_installed; then
    log "removing PPA package amneziawg-dkms (keeping amneziawg-tools)"
    if dpkg-query -W -f='${Status}' amneziawg-tools 2>/dev/null | grep -q 'install ok installed'; then
        apt-mark manual amneziawg-tools >/dev/null
    fi
    modprobe -r amneziawg 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq amneziawg amneziawg-dkms
fi

# Remove any prior DKMS install of the same module/version
if dkms status "$DKMS_NAME/$DKMS_VER" 2>/dev/null | grep -q .; then
    log "removing previous DKMS install of $DKMS_NAME/$DKMS_VER"
    dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all || true
fi

log "running make dkms-install"
make -C "$SRC_DIR/src" dkms-install

# `dkms add` is a no-op if already added by make dkms-install
dkms add -m "$DKMS_NAME" -v "$DKMS_VER" 2>/dev/null || true
log "building DKMS module for $(uname -r)"
dkms build -m "$DKMS_NAME" -v "$DKMS_VER"
log "installing DKMS module"
# --no-initrd: amneziawg is a runtime networking module, not needed in initramfs.
# Skipping the rebuild also avoids hard-failing the install when the host's
# update-initramfs/mkinitrd is broken for unrelated reasons.
dkms install --no-initrd -m "$DKMS_NAME" -v "$DKMS_VER"

# Also build for kernels that are installed but not booted yet (e.g. after an
# unattended upgrade awaiting reboot). DKMS AUTOINSTALL only covers kernels
# installed *after* the module; without this the next reboot comes up with no
# amneziawg and wg-easy falls back to plain WireGuard. Best-effort: an old
# kernel failing to build must not abort the install for the running one.
for kdir in /lib/modules/*/; do
    kver="$(basename "$kdir")"
    [ "$kver" = "$(uname -r)" ] && continue
    [ -e "$kdir/build" ] || continue
    log "building DKMS module for installed kernel $kver"
    if ! { dkms build -m "$DKMS_NAME" -v "$DKMS_VER" -k "$kver" \
           && dkms install --no-initrd -m "$DKMS_NAME" -v "$DKMS_VER" -k "$kver"; }; then
        log "WARNING: DKMS build failed for $kver (headers incomplete?); amneziawg will be missing if you boot it"
    fi
done

log "loading module"
modprobe amneziawg

# modprobe is a no-op when an older build is still loaded (e.g. wg-easy holds
# wg0), so the new module only takes effect after a reload.
if [ -r /sys/module/amneziawg/srcversion ] \
   && [ "$(cat /sys/module/amneziawg/srcversion)" != "$(modinfo -F srcversion amneziawg)" ]; then
    log "WARNING: an older amneziawg build is still loaded; to switch to $SHORT_RESOLVED:"
    log "         docker compose stop wg-easy && modprobe -r amneziawg && modprobe amneziawg && docker compose start wg-easy"
fi

# Verify module is registered with the kernel
if ! modinfo amneziawg >/dev/null 2>&1; then
    log "ERROR: install completed but modinfo amneziawg fails"
    exit 1
fi

# Verify module is functional: kernel must accept creating an amneziawg-type
# interface via netlink. This is what `awg-quick` ultimately relies on.
# Interface names are capped at 15 chars (IFNAMSIZ-1), so use a short fixed
# name; pre-delete handles a stale iface left by an earlier crashed run.
TEST_IFACE="awg-check"
ip link delete "$TEST_IFACE" 2>/dev/null || true
log "verifying module is functional (test iface $TEST_IFACE)"
if ! ip link add dev "$TEST_IFACE" type amneziawg; then
    log "ERROR: 'ip link add type amneziawg' failed — module loaded but not usable"
    exit 1
fi
ip link delete "$TEST_IFACE" 2>/dev/null || log "WARNING: could not delete test iface $TEST_IFACE"

log "persisting module load at boot ($PERSIST_FILE)"
echo amneziawg > "$PERSIST_FILE"

mkdir -p "$STATE_DIR"
echo "$RESOLVED_SHA" > "$STATE_FILE"

log "OK: amneziawg installed ($SHORT_RESOLVED)"
