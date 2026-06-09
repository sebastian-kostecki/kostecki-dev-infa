#!/usr/bin/env bash
set -euo pipefail

WALLET_DIR="${VPS_WALLET_DIR:-/srv/apps/wallet-master}"

cd "$WALLET_DIR"

echo "==> Deploying wallet-master..."
./scripts/deploy.sh

echo "==> Done. Check https://budget.kostecki.dev"
