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
