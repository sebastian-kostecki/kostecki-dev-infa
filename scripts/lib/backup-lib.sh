#!/usr/bin/env bash
# Shared helpers for host restic backups. Sourced, not executed.

BACKUP_STORAGE="${BACKUP_STORAGE:-/storage}"
BACKUP_SKIP_MOUNT_CHECK="${BACKUP_SKIP_MOUNT_CHECK:-0}"
VAULTWARDEN_VOLUME="${VAULTWARDEN_VOLUME:-vaultwarden_vw-data}"
COUCHDB_VOLUME="${COUCHDB_VOLUME:-obsidian-livesync_couchdb-data}"
COUCHDB_CONTAINER="${COUCHDB_CONTAINER:-couchdb}"
ALPINE_IMAGE="${ALPINE_IMAGE:-alpine:3.20}"

restic_forget_args() {
  printf '%s' '--keep-daily 7 --keep-weekly 4 --keep-monthly 6'
}

app_staging_dir() {
  local app="$1"
  printf '%s' "${BACKUP_STORAGE}/backup-staging/${app}"
}

app_restic_repo() {
  local app="$1"
  printf '%s' "${BACKUP_STORAGE}/restic/${app}"
}

require_storage_mounted() {
  if [[ "$BACKUP_SKIP_MOUNT_CHECK" == "1" ]]; then
    return 0
  fi
  if ! mountpoint -q "$BACKUP_STORAGE"; then
    echo "ERROR: ${BACKUP_STORAGE} is not a mountpoint" >&2
    return 1
  fi
}

prepare_staging() {
  local app="$1"
  local dir
  dir="$(app_staging_dir "$app")"
  rm -rf "$dir"
  mkdir -p "$dir"
}

remove_staging() {
  local app="$1"
  rm -rf "$(app_staging_dir "$app")"
}

# Copy a Docker named volume into an existing host directory (helper container).
copy_named_volume_to_dir() {
  local volume="$1"
  local dest="$2"
  docker run --rm \
    -v "${volume}:/from:ro" \
    -v "${dest}:/to" \
    "$ALPINE_IMAGE" \
    sh -c 'cp -a /from/. /to/'
}

restic_backup_and_forget() {
  local repo="$1"
  local password_file="$2"
  local source_dir="$3"
  export RESTIC_REPOSITORY="$repo"
  export RESTIC_PASSWORD_FILE="$password_file"
  restic backup "$source_dir"
  # split args so word-splitting is intentional
  # shellcheck disable=SC2046
  restic forget --prune $(restic_forget_args)
}
