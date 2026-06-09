#!/usr/bin/env bash
set -euo pipefail

echo "==> Updating system..."
sudo apt update && sudo apt upgrade -y

echo "==> Installing Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "Log out and back in for docker group to take effect."
fi

echo "==> Configuring firewall..."
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

echo "==> Creating directories..."
sudo mkdir -p /srv/infra /srv/apps/landing /srv/apps/wallet-master /storage/wallet-master-backups
sudo chown -R "$USER:$USER" /srv /storage/wallet-master-backups

echo "==> Creating Docker network..."
docker network create proxy 2>/dev/null || true

echo "==> Done. Next steps:"
echo "  1. Clone kostecki-dev-infra to /srv/infra"
echo "  2. cp .env.example .env && edit ACME_EMAIL"
echo "  3. docker compose up -d"
echo "  4. Clone kostecki-dev-landing to /srv/apps/landing, build & deploy"
echo "  5. Clone wallet-master to /srv/apps/wallet-master — see docs/wallet-master.md"
