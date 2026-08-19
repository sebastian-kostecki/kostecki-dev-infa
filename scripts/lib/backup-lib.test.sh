#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup-lib.sh
source "$TEST_DIR/backup-lib.sh"

fail=0
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $name (expected [$expected] got [$actual])" >&2
    fail=1
  else
    echo "PASS: $name"
  fi
}

assert_eq "restic_forget_args" \
  "--keep-daily 7 --keep-weekly 4 --keep-monthly 6" \
  "$(restic_forget_args)"

BACKUP_STORAGE="/tmp/fake-storage"
assert_eq "app_staging_dir vaultwarden" \
  "/tmp/fake-storage/backup-staging/vaultwarden" \
  "$(app_staging_dir vaultwarden)"

assert_eq "app_restic_repo obsidian-livesync" \
  "/tmp/fake-storage/restic/obsidian-livesync" \
  "$(app_restic_repo obsidian-livesync)"

BACKUP_SKIP_MOUNT_CHECK=1
if require_storage_mounted; then
  echo "PASS: require_storage_mounted skip"
else
  echo "FAIL: require_storage_mounted skip" >&2
  fail=1
fi

tmpdir="$(mktemp -d)"
BACKUP_STORAGE="$tmpdir"
prepare_staging vaultwarden
echo hello >"$(app_staging_dir vaultwarden)/x"
prepare_staging vaultwarden
if [[ -e "$(app_staging_dir vaultwarden)/x" ]]; then
  echo "FAIL: prepare_staging should recreate empty dir" >&2
  fail=1
else
  echo "PASS: prepare_staging recreates empty dir"
fi
remove_staging vaultwarden
if [[ -d "$(app_staging_dir vaultwarden)" ]]; then
  echo "FAIL: remove_staging" >&2
  fail=1
else
  echo "PASS: remove_staging"
fi
rmdir "$tmpdir/backup-staging" 2>/dev/null || true
rmdir "$tmpdir"

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "All backup-lib tests passed"
