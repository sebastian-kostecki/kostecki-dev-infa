#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STACK_SRC="$REPO_ROOT/stacks/obsidian-livesync"

if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

APP_DIR="${VPS_OBSIDIAN_LIVESYNC_DIR:-/srv/apps/obsidian-livesync}"

if [[ ! -f "$STACK_SRC/docker-compose.yml" ]]; then
  echo "error: stack templates not found at $STACK_SRC" >&2
  exit 1
fi

mkdir -p "$APP_DIR/local.d"
cp "$STACK_SRC/docker-compose.yml" "$APP_DIR/docker-compose.yml"
cp "$STACK_SRC/local.d/livesync.ini" "$APP_DIR/local.d/livesync.ini"

if [[ ! -f "$APP_DIR/.env" ]]; then
  cp "$STACK_SRC/.env.example" "$APP_DIR/.env"
  echo "error: created $APP_DIR/.env from the example." >&2
  echo "Fill in COUCHDB_USER and COUCHDB_PASSWORD, then run this script again." >&2
  exit 1
fi

cd "$APP_DIR"

echo "==> Updating CouchDB image..."
docker compose pull
docker compose up -d

echo "==> Done. Check https://obsidian.kostecki.dev (Obsidian Self-hosted LiveSync)."
