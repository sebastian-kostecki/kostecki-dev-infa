#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/backup-lib.sh
source "$SCRIPT_DIR/lib/backup-lib.sh"

APP="obsidian-livesync"
PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/etc/restic/obsidian-livesync.password}"
couch_was_stopped=0

start_couch_if_needed() {
  if [[ "$couch_was_stopped" -eq 1 ]]; then
    docker start "$COUCHDB_CONTAINER" >/dev/null || docker start "$COUCHDB_CONTAINER"
    couch_was_stopped=0
  fi
}

trap start_couch_if_needed EXIT

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

docker stop "$COUCHDB_CONTAINER"
couch_was_stopped=1

copy_named_volume_to_dir "$COUCHDB_VOLUME" "$STAGING"

start_couch_if_needed

restic_backup_and_forget "$(app_restic_repo "$APP")" "$PASSWORD_FILE" "$STAGING"
remove_staging "$APP"

echo "==> Obsidian LiveSync backup complete"
