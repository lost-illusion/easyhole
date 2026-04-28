#!/bin/bash
set -e

# ── Pre-flight: ensure .env exists and INIT_HOST is set ────────────────

prompt_yes_no() {
    local prompt="$1"
    local choice
    if [ ! -t 0 ]; then return 0; fi
    read -r -p "$prompt " choice
    case "${choice:-Y}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

if [ ! -f .env ]; then
    if [ ! -f .env.example ]; then
        echo "ERROR: neither .env nor .env.example found. Cannot continue."
        exit 1
    fi
    echo ".env not found."
    if prompt_yes_no "Create .env from .env.example? [Y/n]"; then
        cp .env.example .env
        echo "Created .env from .env.example. Review passwords before deploying."
    else
        echo "Aborted: .env is required."
        exit 1
    fi
fi

# Strip comments and export variables
export $(grep -v '^#' .env | sed 's/#.*$//' | sed '/^$/d' | xargs)

# wg-easy unattended setup is silently skipped when INIT_HOST is empty,
# so guard against that here rather than letting users hit the wizard.
if [ -z "${INIT_HOST:-}" ]; then
    echo ""
    echo "INIT_HOST is empty in .env (required by wg-easy unattended setup)."

    if [ ! -t 0 ]; then
        echo "ERROR: not running interactively. Edit .env and set INIT_HOST first."
        exit 1
    fi

    DETECTED_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
        || curl -s --max-time 5 https://icanhazip.com 2>/dev/null \
        || true)
    DETECTED_IP=$(echo "$DETECTED_IP" | tr -d '[:space:]')

    echo "Choose INIT_HOST:"
    if [ -n "$DETECTED_IP" ]; then
        echo "  1) Detected external IP: $DETECTED_IP"
        echo "  2) Custom domain or IP"
        DEFAULT_CHOICE=1
    else
        echo "  (external IP auto-detection failed)"
        echo "  2) Custom domain or IP"
        DEFAULT_CHOICE=2
    fi
    read -r -p "Choice [$DEFAULT_CHOICE]: " choice
    choice="${choice:-$DEFAULT_CHOICE}"

    NEW_HOST=""
    case "$choice" in
        1)
            if [ -z "$DETECTED_IP" ]; then
                echo "ERROR: external IP not available."
                exit 1
            fi
            NEW_HOST="$DETECTED_IP"
            ;;
        2)
            read -r -p "Enter domain or IP: " NEW_HOST
            ;;
        *)
            echo "Unknown choice."
            exit 1
            ;;
    esac

    NEW_HOST=$(echo "$NEW_HOST" | tr -d '[:space:]')
    if [ -z "$NEW_HOST" ]; then
        echo "ERROR: INIT_HOST cannot be empty."
        exit 1
    fi

    # Portable in-place rewrite (works on both BSD and GNU sed)
    sed "s|^INIT_HOST=.*|INIT_HOST=$NEW_HOST|" .env > .env.tmp && mv .env.tmp .env
    export INIT_HOST="$NEW_HOST"
    echo "Set INIT_HOST=$NEW_HOST in .env."
fi

# Default tag if not specified
WG_EASY_TAG=${WG_EASY_TAG:-v15.1.0}

echo "Building wg-easy from tag/commit: $WG_EASY_TAG"

# Best-effort: build/refresh the AmneziaWG kernel module on the host.
# Skips silently when not on Debian/Ubuntu, when already current, or when
# not running as root. See install-awg.sh for details.
if [ -x ./install-awg.sh ]; then
    ./install-awg.sh || echo "WARNING: install-awg.sh exited non-zero (continuing wg-easy build)"
fi

# Clone wg-easy repository if it doesn't exist
if [ ! -d "wg-easy" ]; then
    echo "Cloning wg-easy repository..."
    git clone https://github.com/wg-easy/wg-easy.git
fi

# Navigate to the wg-easy directory
cd wg-easy

# Fetch latest changes
echo "Fetching latest changes..."
git fetch --all --tags --prune

# Compare pinned WG_EASY_TAG against the latest upstream stable release.
# Stable = vX.Y.Z (no -beta, -rc, etc.). Latest is determined locally from
# the tags we just fetched, so no GitHub API call is needed.
LATEST_TAG=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

if [ -n "$LATEST_TAG" ]; then
    if [ "$WG_EASY_TAG" = "$LATEST_TAG" ]; then
        echo "OK: pinned to latest stable ($LATEST_TAG)."
    elif echo "$WG_EASY_TAG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo ""
        echo "WARNING: pinned to $WG_EASY_TAG, but latest stable is $LATEST_TAG."
        echo "         To upgrade: edit .env and set WG_EASY_TAG=$LATEST_TAG"
        echo ""
    else
        echo "INFO: pinned to $WG_EASY_TAG (non-stable ref). Latest stable is $LATEST_TAG."
    fi
fi

# Checkout the specified tag/commit
echo "Checking out $WG_EASY_TAG..."
git checkout "$WG_EASY_TAG"

# Go back to parent directory
cd ..

# Build with docker-compose
echo "Building docker image..."
docker compose build

echo "Build complete! You can now run: docker compose up -d"
