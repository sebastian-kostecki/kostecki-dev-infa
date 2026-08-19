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

echo "==> Installing restic..."
if ! command -v restic &>/dev/null; then
  sudo apt-get update
  sudo apt-get install -y restic
fi

echo "==> Configuring firewall..."
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

echo "==> Creating directories..."
sudo mkdir -p \
  /srv/infra \
  /srv/apps/landing \
  /srv/apps/wallet-master \
  /srv/apps/vaultwarden \
  /srv/apps/obsidian-livesync \
  /storage/wallet-master-backups \
  /storage/restic/vaultwarden \
  /storage/restic/obsidian-livesync \
  /storage/backup-staging
sudo chown -R "$USER:$USER" /srv /storage/wallet-master-backups

echo "==> Creating Docker network..."
docker network create proxy 2>/dev/null || true

echo "==> Done. Next steps:"
echo "  1. Clone kostecki-dev-infra to /srv/infra"
echo "  2. cp .env.example .env && edit ACME_EMAIL"
echo "  3. docker compose up -d"
echo "  4. Clone kostecki-dev-landing to /srv/apps/landing, build & deploy"
echo "  5. Clone wallet-master to /srv/apps/wallet-master — see docs/wallet-master.md"
echo "  6. Clone kostecki-dev-vaultwarden to /srv/apps/vaultwarden — see docs/vaultwarden.md"
echo "  7. Obsidian LiveSync: copy stacks/obsidian-livesync/.env.example to /srv/apps/obsidian-livesync/.env, then ./scripts/deploy-obsidian-livesync.sh"
echo "  8. Backups: create /etc/restic/*.password, then sudo ./scripts/install-backup-timers.sh — see docs/backups.md"
