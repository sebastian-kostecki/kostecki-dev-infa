# Host restic backups (Vaultwarden + Obsidian LiveSync)

**Date:** 2026-08-19  
**Status:** Approved  
**Scope:** Automated local restic backups with GFS rotation for Vaultwarden and CouchDB LiveSync, writing to the existing VPS `/storage` mount. Wallet-master stays on Spatie.

`/storage` is a network mount from another machine (not the VPS system disk). Snapshots survive VPS disk loss or a rebuilt OS as long as that mount and its host remain. A third copy (S3/B2 / `restic copy`) is a later follow-up, not this work.

---

## Decisions

| Topic | Choice |
|-------|--------|
| Apps in this system | Vaultwarden and Obsidian LiveSync (CouchDB) only |
| Wallet-master | Unchanged — Spatie → `/storage/wallet-master-backups` |
| Destination | `/storage` (already off the VPS disk) |
| Tool | `restic` on the host |
| Repositories | Two: one per app, separate passwords |
| Retention (GFS) | 7 daily + 4 weekly + 6 monthly, then `prune` |
| Runner | Bash scripts in this repo + systemd timers (root) |
| Vaultwarden consistency | Hot: `sqlite3 .backup` + copy of other `/data` files |
| CouchDB consistency | Cold: `docker stop` → copy volume → `docker start` → then restic |
| Alerts | None — journald only |
| Encryption | Restic default (password files on host, not in git) |
| Traefik / app compose | No change to routing; backup is host-side |

---

## Architecture

Backup is **not** a Traefik service. Root systemd timers on the VPS run scripts from `/srv/infra`.

```text
VPS
├── /srv/infra                         ← this repo (scripts + unit files)
├── /srv/apps/vaultwarden              ← volume vw-data
├── /srv/apps/obsidian-livesync        ← volume couchdb-data
├── /etc/restic/                       ← password files (root, 600), not in git
└── /storage                           ← mount from another machine
    ├── wallet-master-backups/         ← Spatie (out of this design)
    ├── restic/
    │   ├── vaultwarden/               ← restic repository
    │   └── obsidian-livesync/
    └── backup-staging/                ← ephemeral dumps/copies
        ├── vaultwarden/
        └── obsidian-livesync/
```

Schedule (Europe/local VPS time, after wallet-master Spatie at 01:30):

| Time | Unit | App |
|------|------|-----|
| 03:00 | `backup-vaultwarden.timer` | Vaultwarden (hot) |
| 03:20 | `backup-obsidian-livesync.timer` | CouchDB (cold copy, then restic) |

Timers use `Persistent=true` so a missed window after reboot still runs once.

---

## Components

All of these live in **kostecki-dev-infra** (this repo):

| Piece | Role |
|-------|------|
| `scripts/backup-vaultwarden.sh` | Hot dump → restic → GFS → delete staging |
| `scripts/backup-obsidian-livesync.sh` | Stop Couch → copy volume → start Couch → restic → GFS → delete staging |
| `scripts/install-backup-timers.sh` | Install restic if missing; copy units to `/etc/systemd/system`; `daemon-reload`; enable `--now` timers. Run **once** on the VPS, not on every app deploy. Does **not** create password files. If a password file exists and the repo has no `config`, it may `restic init`; otherwise init stays a documented manual step |
| `systemd/backup-vaultwarden.service` + `.timer` | Daily 03:00 |
| `systemd/backup-obsidian-livesync.service` + `.timer` | Daily 03:20 |
| `docs/backups.md` | Init, install, manual run, `restic snapshots`, restore |
| `scripts/bootstrap-vps.sh` | Also `mkdir` `/storage/restic/*`, `/storage/backup-staging/*`; `apt` restic if we already install packages there |

Units run as **root** so they can talk to Docker, read `/etc/restic`, and write `/storage`.

Environment for restic (in the service files, not git secrets):

- `RESTIC_REPOSITORY=/storage/restic/vaultwarden` or `.../obsidian-livesync`
- `RESTIC_PASSWORD_FILE=/etc/restic/vaultwarden.password` or `obsidian-livesync.password`

Exact Docker volume names are those already used by the apps (`vw-data`, `couchdb-data`). Scripts resolve data via `docker volume inspect` / a one-shot helper container mount, not by guessing `/var/lib/docker/volumes/...` paths in docs only.

---

## Data flow

### Vaultwarden (hot)

1. Fail fast if `/storage` is not mounted (e.g. missing mountpoint content or `findmnt`).
2. Recreate `/storage/backup-staging/vaultwarden` empty.
3. Mount or exec into the Vaultwarden data volume:
   - Run `sqlite3` `.backup` of `db.sqlite3` into staging (consistent SQLite snapshot).
   - Copy remaining `/data` files (attachments, `config.json`, `rsa_key*`, etc.) into staging **without** replacing the staged `db.sqlite3` with a live copy of the DB file.
4. `restic backup` the staging directory.
5. `restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6`.
6. Delete staging.
7. Non-zero from sqlite, restic, or copy → unit failure (journald). Container stays up.

### Obsidian LiveSync (cold copy, hot restic)

1. Fail fast if `/storage` is not mounted.
2. Recreate `/storage/backup-staging/obsidian-livesync` empty.
3. `docker stop couchdb`.
4. Copy volume `couchdb-data` into staging (helper container: source volume `ro`, staging bind-mounted).
5. `docker start couchdb` **before** restic. A `trap`/EXIT handler must attempt start if stop succeeded, even when copy fails, so CouchDB does not stay down.
6. `restic backup` staging → GFS forget/prune → delete staging.
7. Downtime is copy duration only, not restic encrypt/prune.

### Restore (manual only)

Documented in `docs/backups.md`, never run from a timer:

1. `restic snapshots` → pick snapshot.
2. `restic restore` to a directory on the VPS.
3. Stop the app container.
4. Replace volume contents with the restored files (Vaultwarden: whole `/data` including the backed-up sqlite; CouchDB: whole data dir).
5. Start the container and smoke-check the app.

---

## Secrets

On the VPS, not in git:

```text
/etc/restic/vaultwarden.password           root:root, mode 600
/etc/restic/obsidian-livesync.password
```

Generate long random passwords; store copies in a password manager. Without them, `/storage/restic/*` is unreadable.

`restic init` once per repository after the directories exist. Timers must not re-init a non-empty repo.

Repo contains only documentation and an example of the **path** of the password file, never a real password.

---

## Error handling

| Situation | Behaviour |
|-----------|-----------|
| `/storage` unmounted | Script exits non-zero before restic; no silent `init` |
| `sqlite3 .backup` fails | Unit failed; Vaultwarden keeps running |
| `docker stop` ok, copy fails | Trap starts CouchDB; unit failed |
| `restic backup` fails | No forget/prune; staging still deleted or left — **delete staging only after successful backup** so a failed run can be retried from staging if useful; if we always delete, document that retry re-dumps. **Decision: delete staging only on restic success;** on failure leave staging and log the path (disk use is temporary; next successful run recreates). |
| Missed schedule (VPS off) | `Persistent=true` runs once after boot |
| Alerts | None. Operator uses `systemctl status` / `journalctl -u backup-vaultwarden` / `backup-obsidian-livesync` |

---

## Testing

Implementation / ops checks (not a CI job against the VPS):

- [ ] Scripts `set -euo pipefail`; Couch start is trapped
- [ ] Units are valid (`systemd-analyze verify`)
- [ ] First VPS run: `restic snapshots` shows one snapshot per repo
- [ ] Docs: init, enable timers, restore for both apps
- [ ] `bootstrap-vps.sh` creates `/storage/restic` and staging dirs
- [ ] Deploy scripts for the two apps do **not** install/restart backup timers
- [ ] Wallet-master backup path and Spatie schedule unchanged

GFS itself is not fully testable in one day; document the `forget` flags and rely on restic.

---

## Documentation touchpoints

- New `docs/backups.md` (source of truth for backup/restore)
- Link from `docs/SETUP.md`, `docs/ARCHITECTURE.md`
- One-line pointer in `docs/vaultwarden.md` and `docs/obsidian-livesync.md`
- Obsidian LiveSync deploy spec listed “no backup” as follow-up — this spec is that follow-up for **on-`/storage` restic**, not a third off-site copy

---

## Out of scope (follow-up)

- Third location: S3/B2 / `restic copy` using the same repos and passwords
- Healthchecks.io, SMTP, or other failure paging
- Changing wallet-master to restic
- Automated restore or scheduled restore drills
- Stopping Vaultwarden for backups
- Hot CouchDB dump/`_replicate` instead of volume stop-copy
