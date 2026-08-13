# Vaultwarden deployment

Deployment guide for Vaultwarden on **vault.kostecki.dev**.

Related: [ADDING-AN-APP.md](./ADDING-AN-APP.md) · [ARCHITECTURE.md](./ARCHITECTURE.md)

App repo: **kostecki-dev-vaultwarden** (compose only — upstream image).

---

## Architecture

```text
Cloudflare (Proxied) → Traefik → vault.kostecki.dev → vaultwarden :80
                                                      volume vw-data → /data (SQLite)
```

- Image: `vaultwarden/server:1.37.1` (pin; bump deliberately)
- No host ports; container on external `proxy` network
- Traefik labels live in the **app** repo — do not edit infra `docker-compose.yml`

---

## DNS / Cloudflare

| Record | Type | Value | Proxy |
|--------|------|-------|-------|
| `vault` | A | VPS IP | Proxied |

- SSL/TLS mode: **Full (strict)**
- Same pattern as landing / budget

---

## VPS directory

```bash
sudo mkdir -p /srv/apps/vaultwarden
sudo chown "$USER:$USER" /srv/apps/vaultwarden
git clone git@github.com:YOUR_USER/kostecki-dev-vaultwarden.git /srv/apps/vaultwarden
```

`bootstrap-vps.sh` creates `/srv/apps/vaultwarden` automatically.

---

## Environment

On the server only (`/srv/apps/vaultwarden/.env`):

```env
DOMAIN=https://vault.kostecki.dev
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
ADMIN_TOKEN=<argon2-hash-or-secret>
```

Generate a hashed admin token:

```bash
docker run --rm -it vaultwarden/server:1.37.1 /vaultwarden hash
```

---

## Traefik labels

Defined on the `vaultwarden` service in the app repo:

- Host rule: `vault.kostecki.dev`
- entrypoint `websecure`, certresolver `letsencrypt`
- loadbalancer port `80`

---

## First user

Public signup stays **off**.

1. `docker compose up -d` with `ADMIN_TOKEN` set
2. Open `https://vault.kostecki.dev/admin`
3. Invite user → copy link → register
4. Clients: server URL `https://vault.kostecki.dev`

Emergency fallback: briefly enable `SIGNUPS_ALLOWED=true`, register once, disable again, recreate container.

---

## Deploy / update

From infra:

```bash
cd /srv/infra
./scripts/deploy-vaultwarden.sh
```

From app dir:

```bash
cd /srv/apps/vaultwarden
git pull
docker compose pull
docker compose up -d
```

---

## Verification

- `curl -I https://vault.kostecki.dev` — UI reachable over HTTPS
- Admin invite flow works
- `https://kostecki.dev` and `https://budget.kostecki.dev` unchanged

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| 502 | Not on `proxy` network | `docker network inspect proxy` |
| SSL errors | DNS / Cloudflare SSL mode | Proxied + Full strict; wait for cert |
| Cannot register | Signups disabled (expected) | Use `/admin` invite |
| Admin locked | Bad `ADMIN_TOKEN` | Fix `.env`, `docker compose up -d` |
