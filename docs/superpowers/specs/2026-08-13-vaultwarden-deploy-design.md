# Vaultwarden deployment design

**Date:** 2026-08-13  
**Status:** Approved  
**Scope:** Deploy Vaultwarden (Bitwarden-compatible server) on existing VPS behind Traefik at `vault.kostecki.dev`

Upstream: [dani-garcia/vaultwarden](https://github.com/dani-garcia/vaultwarden)

---

## Decisions

| Topic | Choice |
|-------|--------|
| App domain | `vault.kostecki.dev` |
| Repo layout | Separate small repo `kostecki-dev-vaultwarden` (compose + env + README) |
| Database | SQLite in persistent `/data` volume (no Postgres/MySQL) |
| Signups | `SIGNUPS_ALLOWED=false` from day one |
| Invitations | `INVITATIONS_ALLOWED=true` — create accounts via admin invite |
| Admin panel | Enabled via `ADMIN_TOKEN` in VPS `.env` |
| DNS / CDN | Cloudflare **Proxied** (orange cloud), SSL **Full (strict)** |
| Traefik / infra compose | **No changes** — discovery via Docker labels only |
| Image tag | Pin a concrete `vaultwarden/server` version (not `latest` in prod) |

---

## Architecture

```text
Internet
    │
    ▼
Cloudflare (Proxied, SSL edge)
    │
    ▼
Traefik (VPS, proxy network)          ← no changes to infra docker-compose
    │
    ├── kostecki.dev           → landing
    ├── budget.kostecki.dev    → wallet-master
    └── vault.kostecki.dev     → vaultwarden :80

vaultwarden (docker-compose.yml in kostecki-dev-vaultwarden)
├── vaultwarden/server (pinned tag)
└── volume vw-data → /data (SQLite + attachments + config)
```

Public exposure: **Traefik only** (ports 80/443). Vaultwarden does not bind host ports.

WebSocket / live sync uses the same HTTPS host and port (no separate subdomain).

---

## Repositories and VPS layout

```text
kostecki-dev-infra/          ← Traefik, docs, deploy helpers (this repo)
kostecki-dev-vaultwarden/    ← docker-compose.yml, .env.example, README
```

On VPS:

```text
/srv/
├── infra/                   ← kostecki-dev-infra
└── apps/
    ├── landing/
    ├── wallet-master/
    └── vaultwarden/         ← kostecki-dev-vaultwarden
```

---

## DNS and Cloudflare

Add **A record → VPS IP**, **Proxied**:

| Record | Type | Value |
|--------|------|-------|
| `vault` | A | VPS IP |

Cloudflare for `kostecki.dev`:

- **SSL/TLS → Full (strict)** — Traefik presents Let's Encrypt origin cert
- Edge certificate for the new hostname appears after DNS exists (may take a few minutes)

Landing and budget records — unchanged.

---

## App repo: `kostecki-dev-vaultwarden`

### Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Vaultwarden service + Traefik labels + volume |
| `.env.example` | Documented env vars (no secrets committed) |
| `README.md` | Clone, env, up, first-user invite, update |

### docker-compose.yml (outline)

```yaml
services:
  vaultwarden:
    image: vaultwarden/server:1.XX.X   # pin concrete version
    container_name: vaultwarden
    restart: unless-stopped
    env_file: .env
    volumes:
      - vw-data:/data
    networks:
      - proxy
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.vaultwarden.rule=Host(`vault.kostecki.dev`)
      - traefik.http.routers.vaultwarden.entrypoints=websecure
      - traefik.http.routers.vaultwarden.tls.certresolver=letsencrypt
      - traefik.http.services.vaultwarden.loadbalancer.server.port=80

networks:
  proxy:
    external: true

volumes:
  vw-data:
```

No host port mappings. Container must join the existing `proxy` network.

### Production `.env` (on VPS only)

```env
DOMAIN=https://vault.kostecki.dev
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
ADMIN_TOKEN=<long-random-secret>
# Optional later: SMTP for email invites
```

Generate `ADMIN_TOKEN` with a high-entropy value, e.g.:

```bash
openssl rand -base64 48
```

Prefer hashing the token for Vaultwarden if using a recent version that supports `ADMIN_TOKEN` Argon2 hash — document the generation command recommended by upstream at implementation time.

---

## First user (manual account creation)

Public registration stays **off**. Create the first account via admin invite:

1. Set `ADMIN_TOKEN` in `/srv/apps/vaultwarden/.env`.
2. `docker compose up -d` in that directory.
3. Open `https://vault.kostecki.dev/admin` and authenticate with the admin token.
4. Invite a user (copy the invitation link even without SMTP).
5. Open the invite link and complete account registration.
6. Install Bitwarden / Vaultwarden-compatible clients pointing at `https://vault.kostecki.dev`.

**Emergency fallback** (document, do not use as default): temporarily set `SIGNUPS_ALLOWED=true`, register once in the web UI, set back to `false`, recreate/restart the container.

Keep the admin panel enabled for user management unless there is a strong reason to remove `ADMIN_TOKEN` later.

---

## kostecki-dev-infra changes

| Change | Description |
|--------|-------------|
| `docs/vaultwarden.md` | Full ops guide: DNS, clone, env, Traefik labels, first-user invite, updates, troubleshooting |
| `docs/ARCHITECTURE.md` | Add `vault.kostecki.dev` to current diagram and tables |
| `docs/ADDING-AN-APP.md` | Optional short pointer to vaultwarden as a third-party image example |
| `README.md` | List vaultwarden repo / VPS path |
| `scripts/bootstrap-vps.sh` | Create `/srv/apps/vaultwarden` |
| `scripts/deploy-vaultwarden.sh` | `cd` + `docker compose pull && up -d` (or app-repo script if present) |
| `.env.example` | `VPS_VAULTWARDEN_DIR=/srv/apps/vaultwarden` |

**No changes** to `docker-compose.yml` (Traefik).

---

## Deployment procedure

### One-time (VPS)

```bash
# 1. Cloudflare DNS for vault → VPS IP (Proxied)

# 2. App directory
sudo mkdir -p /srv/apps/vaultwarden
sudo chown $USER:$USER /srv/apps/vaultwarden
git clone git@github.com:USER/kostecki-dev-vaultwarden.git /srv/apps/vaultwarden

# 3. Environment
cd /srv/apps/vaultwarden
cp .env.example .env
# Edit DOMAIN, SIGNUPS_ALLOWED=false, INVITATIONS_ALLOWED=true, ADMIN_TOKEN

# 4. Start
docker compose up -d

# 5. First user via /admin invite (see above)
```

### Updates

From infra:

```bash
cd /srv/infra
./scripts/deploy-vaultwarden.sh
```

Or from app dir:

```bash
cd /srv/apps/vaultwarden
docker compose pull
docker compose up -d
```

Data persists in the `vw-data` volume across image upgrades.

### Verification

- `curl -I https://vault.kostecki.dev` — expect HTTP 200 (or Vaultwarden web UI)
- Browser: admin login, invite flow, vault unlock
- Confirm `kostecki.dev` and `budget.kostecki.dev` still work

---

## Security and operations

- Firewall remains 22 / 80 / 443 only
- HTTPS via Traefik + Cloudflare Full (strict)
- `.env` and `ADMIN_TOKEN` only on VPS (never commit)
- `SIGNUPS_ALLOWED=false` permanently after bootstrap
- SQLite + attachments live only in Docker volume — plan backups of `vw-data` in a follow-up if needed
- Do not expose Traefik dashboard publicly without auth

---

## Error handling

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| 502 on `vault.kostecki.dev` | Container not on `proxy` network | `docker network inspect proxy` |
| SSL / Cloudflare error | DNS not ready or SSL mode wrong | Wait for DNS; Full (strict); check Traefik ACME logs |
| Cannot register | Expected with signups off | Use `/admin` invite |
| Admin 404 / locked | Missing or wrong `ADMIN_TOKEN` | Fix `.env`, recreate container |
| Clients cannot sync | Wrong server URL | Use `https://vault.kostecki.dev` (no trailing path required) |

---

## Testing before merge

- [ ] `docker compose config` valid in app repo
- [ ] Labels match Traefik patterns used by landing / wallet-master
- [ ] Docs describe invite bootstrap and emergency signup fallback
- [ ] Infra scripts create dir and deploy without touching Traefik compose

---

## Out of scope (follow-up)

- SMTP for email invitations
- Off-site backup of `vw-data`
- Postgres instead of SQLite
- Organizations / SSO
- CI/CD for image updates
- YubiKey / 2FA policy beyond Vaultwarden defaults
