# Vaultwarden deployment

Step-by-step guide to run Vaultwarden at **https://vault.kostecki.dev**.

Related: [ADDING-AN-APP.md](./ADDING-AN-APP.md) · [ARCHITECTURE.md](./ARCHITECTURE.md)

**Important:** you do **not** clone [dani-garcia/vaultwarden](https://github.com/dani-garcia/vaultwarden). Docker pulls the image `vaultwarden/server:1.37.1`. You only keep a small compose repo: **kostecki-dev-vaultwarden**.

---

## Prerequisites

- Traefik already running from `kostecki-dev-infra` (`docker network` named `proxy` exists)
- Landing / other apps may already be up — they are unaffected
- Access to Cloudflare DNS for `kostecki.dev`
- SSH access to the VPS
- GitHub repo `sebastian-kostecki/kostecki-dev-vaultwarden` created and pushed (local copy may already exist under `~/my-projects/kostecki-dev-vaultwarden`)

---

## Step-by-step (first deploy)

### 1. Publish the compose repo (once, from your laptop)

If the GitHub repo does not exist yet:

1. On GitHub: **New repository** → name `kostecki-dev-vaultwarden` (empty, no README).
2. From your machine:

```bash
cd ~/my-projects/kostecki-dev-vaultwarden
git remote add origin git@github.com:sebastian-kostecki/kostecki-dev-vaultwarden.git
git push -u origin master
```

Also push infra docs/scripts (branch `app/vaultwarden` or after merge to `master`):

```bash
cd ~/my-projects/kostecki-dev-infra
git push -u origin app/vaultwarden
# then merge via PR or: git checkout master && git merge app/vaultwarden && git push
```

On the VPS, pull infra so `docs/vaultwarden.md` and `scripts/deploy-vaultwarden.sh` are available:

```bash
cd /srv/infra
git pull
# if you use the feature branch temporarily:
# git fetch && git checkout app/vaultwarden
```

### 2. DNS (Cloudflare)

| Record | Type | Value | Proxy |
|--------|------|-------|-------|
| `vault` | A | your VPS IP | **Proxied** (orange cloud) |

Confirm:

- SSL/TLS mode for the zone: **Full (strict)**
- Wait a few minutes for the hostname / edge cert if Cloudflare shows a warning

### 3. Directory on the VPS

```bash
sudo mkdir -p /srv/apps/vaultwarden
sudo chown "$USER:$USER" /srv/apps/vaultwarden
git clone git@github.com:sebastian-kostecki/kostecki-dev-vaultwarden.git /srv/apps/vaultwarden
cd /srv/apps/vaultwarden
```

(`bootstrap-vps.sh` also creates `/srv/apps/vaultwarden` on a fresh VPS.)

### 4. Configure `.env`

```bash
cp .env.example .env
```

Edit `.env` so it contains at least:

```env
DOMAIN=https://vault.kostecki.dev
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
ADMIN_TOKEN=
```

Generate a hashed admin token (recommended):

```bash
docker run --rm -it vaultwarden/server:1.37.1 /vaultwarden hash
```

1. Type a long random password when prompted (this is the **plaintext** you will type in `/admin`).
2. Copy the printed Argon2 hash into `ADMIN_TOKEN=...` in `.env`.
3. Save the plaintext somewhere safe (password manager) — you need it to open `/admin`.

Do **not** commit `.env`.

### 5. Start the container

Confirm Traefik’s network exists, then start:

```bash
docker network ls | grep proxy
cd /srv/apps/vaultwarden
docker compose up -d
docker compose ps
docker compose logs -f --tail=50
```

Stop following logs with `Ctrl+C` once you see Vaultwarden listening / no crash loop.

### 6. Create the first user (signups stay off)

Public registration is disabled on purpose.

1. Open **https://vault.kostecki.dev/admin**
2. Log in with the **plaintext** admin token from step 4
3. Invite a user (Users → invite) and **copy the invitation link** (SMTP is optional)
4. Open the link in a browser and complete registration
5. Log in to the vault UI at **https://vault.kostecki.dev**

**Emergency only:** set `SIGNUPS_ALLOWED=true`, `docker compose up -d`, register once in the UI, set `SIGNUPS_ALLOWED=false` again, `docker compose up -d`.

### 7. Point Bitwarden clients

In the official Bitwarden app / browser extension:

- Self-hosted / custom server URL: `https://vault.kostecki.dev`
- Log in with the account from step 6

### 8. Verify

```bash
curl -I https://vault.kostecki.dev
```

Checklist:

- [ ] HTTPS loads the Vaultwarden web UI
- [ ] `/admin` works with your token
- [ ] Invite → register → unlock vault works
- [ ] Client sync works
- [ ] `https://kostecki.dev` and `https://budget.kostecki.dev` still work

---

## Later updates

From infra:

```bash
cd /srv/infra
./scripts/deploy-vaultwarden.sh
```

Or from the app directory:

```bash
cd /srv/apps/vaultwarden
git pull
docker compose pull
docker compose up -d
```

Data stays in the Docker volume `vw-data`.

## Backups

Automated restic to `/storage/restic/vaultwarden`. Setup and restore: [backups.md](./backups.md).

When bumping the image version, change the tag in `docker-compose.yml` (currently `1.37.1`), commit, pull on VPS, then `docker compose pull && docker compose up -d`.

---

## Architecture (reference)

```text
Cloudflare (Proxied) → Traefik → vault.kostecki.dev → vaultwarden :80
                                                      volume vw-data → /data (SQLite)
```

- No host ports published
- Traefik labels live in the **app** repo — do **not** edit infra `docker-compose.yml`
- WebSocket / live sync uses the same HTTPS host (no extra subdomain)

---

## Traefik labels (reference)

On the `vaultwarden` service:

- `Host(\`vault.kostecki.dev\`)`
- entrypoint `websecure`, certresolver `letsencrypt`
- loadbalancer port `80`

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| 502 | Container not on `proxy` | `docker network inspect proxy` |
| SSL / Cloudflare errors | DNS not ready or SSL mode | Proxied + Full strict; wait; check Traefik logs |
| Cannot register on main UI | Signups disabled (expected) | Use `/admin` invite |
| Admin login fails | Wrong token / hash mismatch | Re-run `/vaultwarden hash`, update `.env`, `docker compose up -d` |
| Client cannot connect | Wrong server URL | Use exactly `https://vault.kostecki.dev` |
