# Obsidian Self-hosted LiveSync (CouchDB)

Step-by-step guide to run CouchDB for the **Self-hosted LiveSync** plugin at **https://obsidian.kostecki.dev**.

Related: [ADDING-AN-APP.md](./ADDING-AN-APP.md) · [ARCHITECTURE.md](./ARCHITECTURE.md)

This is **not** official Obsidian Sync. There is **no** separate GitHub app repo: compose and INI live in this infra repo under `stacks/obsidian-livesync/`. A deploy script copies them to `/srv/apps/obsidian-livesync`.

---

## Prerequisites

- Traefik already running from `kostecki-dev-infra` (`docker network` named `proxy` exists)
- Access to Cloudflare DNS for `kostecki.dev`
- SSH access to the VPS

---

## Step-by-step (first deploy)

### 1. Pull infra on the VPS

```bash
cd /srv/infra
git pull
```

### 2. DNS (Cloudflare)

| Record | Type | Value | Proxy |
|--------|------|--------|--------|
| `obsidian` | A | your VPS IP | **DNS only** (grey cloud) |

Do **not** orange-cloud this hostname. Cloudflare proxy often breaks CouchDB replication (request body limits, buffering).

Let's Encrypt is issued by Traefik (HTTP-01). Wait a few minutes after creating the record.

### 3. Secrets (once)

```bash
mkdir -p /srv/apps/obsidian-livesync
cp /srv/infra/stacks/obsidian-livesync/.env.example /srv/apps/obsidian-livesync/.env
```

Edit `/srv/apps/obsidian-livesync/.env`:

```env
COUCHDB_USER=obsidian
COUCHDB_PASSWORD=<long-random-secret>
```

Do **not** commit this file. Do **not** put CouchDB passwords in `/srv/infra/.env`.

(`bootstrap-vps.sh` also creates `/srv/apps/obsidian-livesync` on a fresh VPS.)

### 4. Start the stack

```bash
docker network ls | grep proxy
cd /srv/infra
./scripts/deploy-obsidian-livesync.sh
```

The script always overwrites `docker-compose.yml` and `local.d/livesync.ini` from git. It never overwrites an existing `.env`.

If `.env` is missing, it copies the example and **exits** until you fill in `COUCHDB_*` and run it again.

### 5. Point Obsidian (Self-hosted LiveSync)

In the plugin:

- URI: `https://obsidian.kostecki.dev` (no port, no trailing path required)
- Database name: e.g. `obsidian` (the plugin can create it)
- Username / password: same as `.env`
- Enable **end-to-end encryption** and store the passphrase in a password manager
- Run the plugin’s CouchDB configuration check (CORS)

Do not sync the same vault with iCloud / another folder sync tool at the same time.

### 6. Verify

```bash
curl -I https://obsidian.kostecki.dev
```

Unauthenticated requests should fail (401) because `require_valid_user` is on. That is expected.

```bash
curl -I -u 'USER:PASSWORD' https://obsidian.kostecki.dev/
```

Checklist:

- [ ] DNS is **DNS only**
- [ ] HTTPS answers on `obsidian.kostecki.dev`
- [ ] `/_utils` is **403** from the internet (Fauxton blocked)
- [ ] Plugin check passes (CORS)
- [ ] Notes sync between two devices
- [ ] `https://kostecki.dev`, `https://budget.kostecki.dev`, and `https://vault.kostecki.dev` still work

---

## Later updates

From infra:

```bash
cd /srv/infra
git pull
./scripts/deploy-obsidian-livesync.sh
```

Data stays in the Docker volume `couchdb-data`.

When bumping the image version, change the tag in `stacks/obsidian-livesync/docker-compose.yml` (currently `3.4.3`), commit, pull on the VPS, then run the deploy script.

Edits made by hand under `/srv/apps/obsidian-livesync` (except `.env`) are lost on the next deploy.

---

## Architecture (reference)

```text
Cloudflare (DNS only) → Traefik → obsidian.kostecki.dev → couchdb :5984
                                                      volume couchdb-data
                                                      local.d/livesync.ini
```

- No host ports published
- Traefik labels live on the CouchDB service in the **copied** compose file
- Root infra `docker-compose.yml` (Traefik) is **not** modified
- CORS is configured in CouchDB only — do not add CORS headers on Traefik

---

## Traefik labels (reference)

On the `couchdb` service:

- `Host(\`obsidian.kostecki.dev\`)` → port `5984`
- Higher-priority router: `PathPrefix(\`/_utils\`)` + IP allowlist `127.0.0.1/32`

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| 502 | Container not on `proxy` | `docker network inspect proxy` |
| SSL errors | DNS not ready or orange cloud | Grey cloud; wait; Traefik ACME logs |
| CORS errors in the plugin | Traefik CORS middleware, or INI not mounted | Remove extra CORS; redeploy |
| Timeouts / large attachments | Cloudflare Proxied | Switch to DNS only |
| 403 on `/_utils` | Expected | Do not use Fauxton remotely |
| Deploy asks to fill `.env` | First run | Set `COUCHDB_*` and rerun |
| Plugin cannot create the database | Wrong user/password | Match `/srv/apps/obsidian-livesync/.env` |
