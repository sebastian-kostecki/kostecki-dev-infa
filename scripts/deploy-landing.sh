#!/usr/bin/env bash
set -euo pipefail

LANDING_DIR="${VPS_LANDING_DIR:-/srv/apps/landing}"

cd "$LANDING_DIR"

echo "==> Pulling latest..."
git pull

echo "==> Building..."
npm ci
npm run build

echo "==> Restarting container..."
docker compose up -d

echo "==> Done. Check https://kostecki.dev"
