#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/backup-lib.sh
source "$SCRIPT_DIR/lib/backup-lib.sh"

APP="vaultwarden"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/restic/vaultwarden.password}"

require_storage_mounted
if [[ ! -f "$PASSWORD_FILE" ]]; then
  echo "ERROR: missing restic password file ${PASSWORD_FILE}" >&2
  exit 1
fi
if [[ ! -d "$(app_restic_repo "$APP")" ]]; then
  echo "ERROR: restic repo missing $(app_restic_repo "$APP")" >&2
  exit 1
fi

prepare_staging "$APP"
STAGING="$(app_staging_dir "$APP")"

# Copy attachments/keys first; never copy live sqlite files into staging.
docker run --rm \
  -v "${VAULTWARDEN_VOLUME}:/data:ro" \
  -v "${STAGING}:/staging" \
  "$ALPINE_IMAGE" \
  sh -c 'apk add --no-cache rsync >/dev/null && rsync -a --delete \
    --exclude db.sqlite3 \
    --exclude db.sqlite3-wal \
    --exclude db.sqlite3-shm \
    /data/ /staging/'

# Consistent sqlite snapshot into staging/db.sqlite3 (volume RW for .backup).
docker run --rm \
  -v "${VAULTWARDEN_VOLUME}:/data" \
  -v "${STAGING}:/staging" \
  "$ALPINE_IMAGE" \
  sh -c 'apk add --no-cache sqlite >/dev/null && sqlite3 /data/db.sqlite3 ".backup \"/staging/db.sqlite3\""'

restic_backup_and_forget "$(app_restic_repo "$APP")" "$PASSWORD_FILE" "$STAGING"
remove_staging "$APP"

echo "==> Vaultwarden backup complete"
