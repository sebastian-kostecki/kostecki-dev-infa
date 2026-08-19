# Host restic backups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add host-side restic backups with GFS rotation for Vaultwarden and Obsidian LiveSync CouchDB onto `/storage`, driven by systemd timers and scripts in this repo.

**Architecture:** Shared bash library plus two oneshot backup scripts. Vaultwarden dumps SQLite with `sqlite3 .backup` while the container stays up, then copies the rest of `/data`. CouchDB is stopped only for a volume copy, then started before `restic backup`. Two encrypted restic repos live under `/storage/restic/`. Timers are installed once; app deploy scripts do not touch them.

**Tech Stack:** bash, restic, Docker CLI, systemd timers, Alpine helper containers (`alpine:3.20`) for sqlite/rsync/cp

**Spec:** [2026-08-19-restic-backups-design.md](../specs/2026-08-19-restic-backups-design.md)

## Global Constraints

- Apps in this system: Vaultwarden and Obsidian LiveSync only; wallet-master Spatie path unchanged
- Destination: `/storage` (network mount); fail if not mounted
- Tool: restic on the host; two repositories, separate password files
- GFS: `--keep-daily 7 --keep-weekly 4 --keep-monthly 6` then `--prune`
- Runner: bash in this repo + systemd timers as root; install once, not on every app deploy
- Vaultwarden: hot sqlite `.backup` + copy of other `/data` files (never overwrite staged DB with live `db.sqlite3`)
- CouchDB: cold volume copy; `docker start` before restic; trap must start Couch if stop succeeded
- Staging deleted only after successful `restic backup`
- Alerts: none — journald only
- Password files: `/etc/restic/vaultwarden.password` and `/etc/restic/obsidian-livesync.password` (root, 600), never git
- Default Docker volume names: `vaultwarden_vw-data`, `obsidian-livesync_couchdb-data` (compose project = directory name); overridable via env
- CouchDB container name: `couchdb`; Vaultwarden container name: `vaultwarden`
- Docs and comments in English
- Do not change Traefik compose or app deploy scripts’ backup behavior

---

## File map

| File | Responsibility |
|------|----------------|
| `scripts/lib/backup-lib.sh` | Paths, mount check, staging, restic GFS, volume copy helper |
| `scripts/lib/backup-lib.test.sh` | Unit tests for the library (no Docker/restic required) |
| `scripts/backup-vaultwarden.sh` | Hot Vaultwarden dump + restic |
| `scripts/backup-obsidian-livesync.sh` | Cold Couch copy + restic |
| `scripts/install-backup-timers.sh` | apt restic, dirs, init empty repos, install/enable units |
| `systemd/backup-vaultwarden.service` | oneshot → vaultwarden script |
| `systemd/backup-vaultwarden.timer` | daily 03:00, Persistent=true |
| `systemd/backup-obsidian-livesync.service` | oneshot → livesync script |
| `systemd/backup-obsidian-livesync.timer` | daily 03:20, Persistent=true |
| `scripts/bootstrap-vps.sh` | mkdir `/storage/restic/*` and staging; install restic |
| `docs/backups.md` | Init, install, manual run, snapshots, restore |
| `docs/SETUP.md` | Checklist + repo tree + link |
| `docs/ARCHITECTURE.md` | `/storage` layout pointer |
| `docs/vaultwarden.md` | One-line pointer |
| `docs/obsidian-livesync.md` | One-line pointer |
| `README.md` | Docs table entry |

---

### Task 1: Shared backup library + unit tests

**Files:**
- Create: `scripts/lib/backup-lib.sh`
- Create: `scripts/lib/backup-lib.test.sh`

**Interfaces:**
- Consumes: env overrides `BACKUP_STORAGE`, `BACKUP_SKIP_MOUNT_CHECK`, `VAULTWARDEN_VOLUME`, `COUCHDB_VOLUME`
- Produces: functions `require_storage_mounted`, `restic_forget_args`, `app_staging_dir`, `app_restic_repo`, `prepare_staging`, `remove_staging`, `copy_named_volume_to_dir` (defined here, used by later scripts)

- [ ] **Step 1: Write the failing test script**

Create `scripts/lib/backup-lib.test.sh`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
chmod +x scripts/lib/backup-lib.test.sh
./scripts/lib/backup-lib.test.sh
```

Expected: FAIL (cannot source `backup-lib.sh` or functions undefined).

- [ ] **Step 3: Write `scripts/lib/backup-lib.sh`**

```bash
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
./scripts/lib/backup-lib.test.sh
```

Expected: `All backup-lib tests passed` and several `PASS:` lines.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/backup-lib.sh scripts/lib/backup-lib.test.sh
git commit -m "$(cat <<'EOF'
Add shared restic backup library and unit tests.

EOF
)"
```

---

### Task 2: Vaultwarden hot backup script

**Files:**
- Create: `scripts/backup-vaultwarden.sh`

**Interfaces:**
- Consumes: `require_storage_mounted`, `prepare_staging`, `remove_staging`, `app_staging_dir`, `app_restic_repo`, `restic_backup_and_forget`, `VAULTWARDEN_VOLUME` from `scripts/lib/backup-lib.sh`
- Produces: executable `scripts/backup-vaultwarden.sh` (exit 0 only after successful restic; staging kept on failure)

- [ ] **Step 1: Write a syntax/contract check (fail until script exists)**

From repo root, this must fail before the script exists:

```bash
test -x scripts/backup-vaultwarden.sh && bash -n scripts/backup-vaultwarden.sh
```

Expected: FAIL (`No such file`).

- [ ] **Step 2: Implement `scripts/backup-vaultwarden.sh`**

```bash
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
```

- [ ] **Step 3: Syntax-check the script**

Run:

```bash
chmod +x scripts/backup-vaultwarden.sh
bash -n scripts/backup-vaultwarden.sh
./scripts/lib/backup-lib.test.sh
```

Expected: no output from `bash -n`; library tests still PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/backup-vaultwarden.sh
git commit -m "$(cat <<'EOF'
Add Vaultwarden hot sqlite restic backup script.

EOF
)"
```

---

### Task 3: Obsidian LiveSync cold-copy backup script

**Files:**
- Create: `scripts/backup-obsidian-livesync.sh`

**Interfaces:**
- Consumes: `copy_named_volume_to_dir`, `COUCHDB_VOLUME`, `COUCHDB_CONTAINER`, restic helpers from `scripts/lib/backup-lib.sh`
- Produces: executable `scripts/backup-obsidian-livesync.sh` with EXIT trap that starts CouchDB if it was stopped

- [ ] **Step 1: Confirm script is missing**

```bash
test -x scripts/backup-obsidian-livesync.sh && bash -n scripts/backup-obsidian-livesync.sh
```

Expected: FAIL (`No such file`).

- [ ] **Step 2: Implement `scripts/backup-obsidian-livesync.sh`**

```bash
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
```

The EXIT trap still runs after success; `start_couch_if_needed` is a no-op when `couch_was_stopped` is already 0.

- [ ] **Step 3: Syntax-check**

Run:

```bash
chmod +x scripts/backup-obsidian-livesync.sh
bash -n scripts/backup-obsidian-livesync.sh
./scripts/lib/backup-lib.test.sh
```

Expected: `bash -n` silent; library tests PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/backup-obsidian-livesync.sh
git commit -m "$(cat <<'EOF'
Add CouchDB LiveSync cold-copy restic backup script.

EOF
)"
```

---

### Task 4: systemd units and one-time installer

**Files:**
- Create: `systemd/backup-vaultwarden.service`
- Create: `systemd/backup-vaultwarden.timer`
- Create: `systemd/backup-obsidian-livesync.service`
- Create: `systemd/backup-obsidian-livesync.timer`
- Create: `scripts/install-backup-timers.sh`

**Interfaces:**
- Consumes: `scripts/backup-vaultwarden.sh`, `scripts/backup-obsidian-livesync.sh` at `/srv/infra/scripts/...` on the VPS
- Produces: `install-backup-timers.sh` that copies units, may `restic init`, enables timers; does not create password files

- [ ] **Step 1: Write unit files**

`systemd/backup-vaultwarden.service`:

```ini
[Unit]
Description=Restic backup for Vaultwarden
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ExecStart=/srv/infra/scripts/backup-vaultwarden.sh
```

`systemd/backup-vaultwarden.timer`:

```ini
[Unit]
Description=Daily Vaultwarden restic backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=backup-vaultwarden.service

[Install]
WantedBy=timers.target
```

`systemd/backup-obsidian-livesync.service`:

```ini
[Unit]
Description=Restic backup for Obsidian LiveSync CouchDB
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ExecStart=/srv/infra/scripts/backup-obsidian-livesync.sh
```

`systemd/backup-obsidian-livesync.timer`:

```ini
[Unit]
Description=Daily Obsidian LiveSync restic backup

[Timer]
OnCalendar=*-*-* 03:20:00
Persistent=true
Unit=backup-obsidian-livesync.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 2: Write `scripts/install-backup-timers.sh`**

```bash
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
```

- [ ] **Step 3: Make executable and syntax-check**

```bash
chmod +x scripts/install-backup-timers.sh
bash -n scripts/install-backup-timers.sh
```

Expected: silent success.

If `systemd-analyze` exists locally:

```bash
systemd-analyze verify systemd/backup-vaultwarden.service systemd/backup-vaultwarden.timer systemd/backup-obsidian-livesync.service systemd/backup-obsidian-livesync.timer
```

Expected: no errors (on a machine with systemd; skip if unavailable).

- [ ] **Step 4: Commit**

```bash
git add systemd scripts/install-backup-timers.sh
git commit -m "$(cat <<'EOF'
Add systemd backup timers and one-time installer.

EOF
)"
```

---

### Task 5: Bootstrap directories and documentation

**Files:**
- Modify: `scripts/bootstrap-vps.sh`
- Create: `docs/backups.md`
- Modify: `docs/SETUP.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/vaultwarden.md`
- Modify: `docs/obsidian-livesync.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: installer path `scripts/install-backup-timers.sh` and ops flows from Tasks 2–4
- Produces: operator docs and bootstrap dirs matching the spec layout

- [ ] **Step 1: Extend `scripts/bootstrap-vps.sh`**

Replace the directory block with:

```bash
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
```

After the Docker install block, add restic:

```bash
echo "==> Installing restic..."
if ! command -v restic &>/dev/null; then
  sudo apt-get update
  sudo apt-get install -y restic
fi
```

Add a next-step echo (do not enable timers here):

```bash
echo "  8. Backups: create /etc/restic/*.password, then sudo ./scripts/install-backup-timers.sh — see docs/backups.md"
```

- [ ] **Step 2: Write `docs/backups.md`**

Create the file with exactly this body:

~~~~markdown
# Backups (Vaultwarden + Obsidian LiveSync)

Host restic backups to `/storage` (network mount). Wallet-master stays on Spatie (`/storage/wallet-master-backups`).

Related spec: [superpowers/specs/2026-08-19-restic-backups-design.md](./superpowers/specs/2026-08-19-restic-backups-design.md)

## Layout

```text
/storage/
├── wallet-master-backups/     ← Spatie, not restic
├── restic/
│   ├── vaultwarden/
│   └── obsidian-livesync/
└── backup-staging/            ← ephemeral; kept only if restic fails
```

Passwords (not in git):

```text
/etc/restic/vaultwarden.password           root, mode 600
/etc/restic/obsidian-livesync.password
```

Store the same passwords in a password manager. Without them the repos cannot be restored.

## One-time VPS setup

1. Ensure `/storage` is mounted (`mountpoint /storage`).
2. `sudo mkdir -p /etc/restic` and write two long random passwords into the files above (`chmod 600`).
3. From `/srv/infra` after `git pull`:

```bash
sudo ./scripts/install-backup-timers.sh
```

This installs restic if needed, `restic init` if a repo has no `config`, copies systemd units, and enables timers (03:00 Vaultwarden, 03:20 LiveSync). Do **not** run this from app deploy scripts.

## Manual run

```bash
sudo systemctl start backup-vaultwarden.service
sudo systemctl start backup-obsidian-livesync.service
journalctl -u backup-vaultwarden.service -u backup-obsidian-livesync.service -e
```

```bash
sudo RESTIC_REPOSITORY=/storage/restic/vaultwarden RESTIC_PASSWORD_FILE=/etc/restic/vaultwarden.password restic snapshots
sudo RESTIC_REPOSITORY=/storage/restic/obsidian-livesync RESTIC_PASSWORD_FILE=/etc/restic/obsidian-livesync.password restic snapshots
```

## Restore Vaultwarden

1. Pick a snapshot: `restic snapshots` on `/storage/restic/vaultwarden`.
2. Restore to a temp dir:

```bash
sudo RESTIC_REPOSITORY=/storage/restic/vaultwarden RESTIC_PASSWORD_FILE=/etc/restic/vaultwarden.password \
  restic restore latest --target /tmp/vw-restore
```

3. `docker stop vaultwarden`
4. Replace volume contents (example helper):

```bash
docker run --rm -v vaultwarden_vw-data:/data -v /tmp/vw-restore:/restore alpine:3.20 \
  sh -c 'rm -rf /data/* /data/.[!.]* ; cp -a /restore/. /data/'
```

Adjust the restore subdirectory if restic restored a nested staging path.

5. `docker start vaultwarden` and open `https://vault.kostecki.dev`.

## Restore CouchDB (LiveSync)

1. `restic snapshots` on `/storage/restic/obsidian-livesync`.
2. `restic restore latest --target /tmp/couch-restore`
3. `docker stop couchdb`
4. Copy restored files into `obsidian-livesync_couchdb-data` the same way as Vaultwarden.
5. `docker start couchdb` and confirm the Obsidian plugin syncs.

## Logs (no email alerts)

```bash
systemctl status backup-vaultwarden.timer backup-obsidian-livesync.timer
journalctl -u backup-vaultwarden.service
journalctl -u backup-obsidian-livesync.service
```

Retention is GFS: 7 daily, 4 weekly, 6 monthly (`restic forget --prune` in the job).
~~~~

- [ ] **Step 3: Link from existing docs**

In `docs/SETUP.md` checklist, after Obsidian LiveSync, add:

```markdown
### Backups (restic)

- [ ] `/storage` mounted from the backup host
- [ ] Password files in `/etc/restic/`
- [ ] `sudo ./scripts/install-backup-timers.sh` — see [backups.md](./backups.md)
```

In the repo structure tree, add `systemd/` and `scripts/lib/`, `backup-*.sh`, `install-backup-timers.sh`, and `docs/backups.md`.

In `docs/ARCHITECTURE.md` after the On VPS tree, add a short `/storage` tree (wallet-master Spatie + restic dirs) and a link to `backups.md`.

In `docs/vaultwarden.md` after the first-deploy sections (before Traefik labels is fine), add:

```markdown
## Backups

Automated restic to `/storage/restic/vaultwarden`. Setup and restore: [backups.md](./backups.md).
```

In `docs/obsidian-livesync.md` after “Later updates”, add:

```markdown
## Backups

Automated restic to `/storage/restic/obsidian-livesync` (short CouchDB stop for a consistent volume copy). Setup and restore: [backups.md](./backups.md).
```

In `README.md` documentation table, add a row for `docs/backups.md`.

- [ ] **Step 4: Re-run library tests and bash -n on all new scripts**

```bash
./scripts/lib/backup-lib.test.sh
bash -n scripts/bootstrap-vps.sh
bash -n scripts/backup-vaultwarden.sh
bash -n scripts/backup-obsidian-livesync.sh
bash -n scripts/install-backup-timers.sh
```

Expected: all tests passed; `bash -n` silent.

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap-vps.sh docs/backups.md docs/SETUP.md docs/ARCHITECTURE.md docs/vaultwarden.md docs/obsidian-livesync.md README.md
git commit -m "$(cat <<'EOF'
Document restic backups and create storage dirs in bootstrap.

EOF
)"
```

---

## Self-review (plan vs spec)

| Spec item | Task |
|-----------|------|
| Two restic repos on `/storage` | 1, 4, 5 |
| GFS 7/4/6 | 1 (`restic_forget_args`) |
| systemd 03:00 / 03:20 Persistent | 4 |
| Vaultwarden hot sqlite + rsync excludes | 2 |
| Couch stop → copy → start → restic; trap | 3 |
| Staging delete only after restic success | 2, 3 (remove_staging after restic) |
| Fail if `/storage` not mounted | 1, 2, 3 |
| Logs only | 5 docs; no healthchecks |
| Password files not in git | 4 installer `need_pass`, 5 docs |
| bootstrap dirs + restic package | 5 |
| install timers once, not in app deploys | 4, 5 (explicit) |
| wallet-master unchanged | no edits to wallet-master files |
| Restore documented, not automated | 5 `docs/backups.md` |
| Third copy / mail out of scope | not in any task |
