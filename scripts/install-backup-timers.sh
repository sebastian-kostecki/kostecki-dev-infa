#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_STORAGE="${BACKUP_STORAGE:-/storage}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

if ! command -v restic >/dev/null 2>&1; then
  apt-get update
  apt-get install -y restic
fi

mkdir -p \
  "$BACKUP_STORAGE/restic/vaultwarden" \
  "$BACKUP_STORAGE/restic/obsidian-livesync" \
  "$BACKUP_STORAGE/backup-staging" \
  /etc/restic

chmod 700 /etc/restic

need_pass() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "ERROR: create ${f} (mode 600, root) then rerun" >&2
    exit 1
  fi
  chmod 600 "$f"
}

need_pass /etc/restic/vaultwarden.password
need_pass /etc/restic/obsidian-livesync.password

init_if_empty() {
  local repo="$1"
  local pass="$2"
  if [[ ! -f "${repo}/config" ]]; then
    echo "==> restic init ${repo}"
    RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD_FILE="$pass" restic init
  else
    echo "==> restic repo already initialized: ${repo}"
  fi
}

init_if_empty "$BACKUP_STORAGE/restic/vaultwarden" /etc/restic/vaultwarden.password
init_if_empty "$BACKUP_STORAGE/restic/obsidian-livesync" /etc/restic/obsidian-livesync.password

cp "$REPO_ROOT/systemd/backup-vaultwarden.service" /etc/systemd/system/
cp "$REPO_ROOT/systemd/backup-vaultwarden.timer" /etc/systemd/system/
cp "$REPO_ROOT/systemd/backup-obsidian-livesync.service" /etc/systemd/system/
cp "$REPO_ROOT/systemd/backup-obsidian-livesync.timer" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now backup-vaultwarden.timer
systemctl enable --now backup-obsidian-livesync.timer

systemctl list-timers 'backup-*'

echo "==> Backup timers installed. First automatic runs at 03:00 and 03:20."
echo "    Manual: systemctl start backup-vaultwarden.service"
