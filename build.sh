#!/bin/bash
set -e

# Load environment variables from .env file
if [ -f .env ]; then
    # Strip comments and export variables
    export $(grep -v '^#' .env | sed 's/#.*$//' | sed '/^$/d' | xargs)
fi

# Default tag if not specified
WG_EASY_TAG=${WG_EASY_TAG:-v15.1.0}

echo "Building wg-easy from tag/commit: $WG_EASY_TAG"

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
