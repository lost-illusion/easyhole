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

# Navigate to the wg-easy directory
cd wg-easy

# Fetch latest changes
echo "Fetching latest changes..."
git fetch --all --tags

# Checkout the specified tag/commit
echo "Checking out $WG_EASY_TAG..."
git checkout "$WG_EASY_TAG"

# Go back to parent directory
cd ..

# Build with docker-compose
echo "Building docker image..."
docker compose build

echo "Build complete! You can now run: docker compose up -d"
