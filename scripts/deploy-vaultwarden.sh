#!/usr/bin/env bash
set -euo pipefail

VAULT_DIR="${VPS_VAULTWARDEN_DIR:-/srv/apps/vaultwarden}"

cd "$VAULT_DIR"

echo "==> Pulling latest..."
git pull

echo "==> Updating Vaultwarden image..."
docker compose pull
docker compose up -d

echo "==> Done. Check https://vault.kostecki.dev"
