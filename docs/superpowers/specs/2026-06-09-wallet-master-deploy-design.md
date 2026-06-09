# wallet-master deployment design

**Date:** 2026-06-09  
**Status:** Approved  
**Scope:** Deploy wallet-master (Laravel + Inertia + Reverb + Horizon) on existing VPS alongside landing

---

## Decisions

| Topic | Choice |
|-------|--------|
| App domain | `budget.kostecki.dev` |
| WebSocket domain | `ws.budget.kostecki.dev` |
| Landing | `kostecki.dev` — unchanged |
| DNS / CDN | Cloudflare **Proxied** (orange cloud) |
| VPS state | Traefik + landing already running |
| Deployment approach | Single app container + supervisord (A) |
| Build | Multi-stage `Dockerfile.prod` (no Node on VPS) |

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
    ├── kostecki.dev           → landing (unchanged)
    ├── budget.kostecki.dev    → wallet-master :80  (artisan serve)
    └── ws.budget.kostecki.dev → wallet-master :8080 (Reverb)

wallet-master (docker-compose.prod.yml, internal network + proxy)
├── app          supervisord: php serve + reverb + horizon + schedule:work
├── mysql        persistent data
├── redis        queues (Horizon) + cache
└── typesense    import description memory
```

Traefik in **kostecki-dev-infra** does not need routing changes. Discovery happens via Docker labels in wallet-master's `docker-compose.prod.yml`.

Reverb is **not** a separate repo — it is a supervisord program in the same app container, routed by a separate Traefik host rule (same pattern as queue workers, but public for WebSocket).

---

## DNS and Cloudflare

Add **A records → VPS IP**, **Proxied** (orange cloud):

| Record | Type | Value |
|--------|------|-------|
| `budget` | A | VPS IP |
| `ws.budget` | A | VPS IP |

Cloudflare settings for `kostecki.dev`:

- **SSL/TLS → Full (strict)** — origin (Traefik) must present a valid certificate (Let's Encrypt, same as landing)
- **Network → WebSockets: On**
- Edge certificates for new proxied hostnames are issued automatically after DNS records exist (the "hostname is not covered by a certificate" warning clears within minutes)

Landing records (`kostecki.dev`, `www`) — no changes.

---

## wallet-master changes (main implementation work)

### New files

| File | Purpose |
|------|---------|
| `docker-compose.prod.yml` | Production stack: app + mysql + redis + typesense + Traefik labels |
| `docker/8.5/Dockerfile.prod` | Multi-stage: `composer install --no-dev` + `npm run build` + runtime image |
| `docker/8.5/supervisord.prod.conf` | Dev supervisord + `schedule:work` for backups and import purge |
| `scripts/deploy.sh` | Build, up, migrate, cache |

### docker-compose.prod.yml

- `app` container on `wallet-internal` + `proxy` networks
- Two Traefik routers on the same container:
  - `budget.kostecki.dev` → port `80`
  - `ws.budget.kostecki.dev` → port `8080`
- No host port bindings (Traefik only entry point)
- Volumes: `storage`, `.env`, mysql/redis/typesense data
- Excluded from prod vs Sail: mailpit, Vite dev server, Xdebug, public DB/Redis/Typesense ports

**Traefik labels (app container):**

```yaml
labels:
  - traefik.enable=true
  - traefik.docker.network=proxy
  # HTTP / Inertia
  - traefik.http.routers.wallet.rule=Host(`budget.kostecki.dev`)
  - traefik.http.routers.wallet.entrypoints=websecure
  - traefik.http.routers.wallet.tls.certresolver=letsencrypt
  - traefik.http.services.wallet.loadbalancer.server.port=80
  # WebSocket / Reverb
  - traefik.http.routers.wallet-ws.rule=Host(`ws.budget.kostecki.dev`)
  - traefik.http.routers.wallet-ws.entrypoints=websecure
  - traefik.http.routers.wallet-ws.tls.certresolver=letsencrypt
  - traefik.http.services.wallet-ws.loadbalancer.server.port=8080
```

### Supervisord (production)

Four programs in `supervisord.prod.conf`:

1. `php artisan serve --host=0.0.0.0 --port=80`
2. `php artisan reverb:start --host=0.0.0.0 --port=8080`
3. `php artisan horizon`
4. `php artisan schedule:work` — runs `backup:run`, `backup:clean`, `backup:monitor`, `imports:purge-old-files` (defined in `routes/console.php`)

### Dockerfile.prod (multi-stage outline)

1. **composer** — `composer install --no-dev --optimize-autoloader`
2. **node** — `npm ci && npm run build` (requires `VITE_REVERB_*` build args or `.env` copied before build)
3. **runtime** — based on existing `docker/8.5/Dockerfile` without Xdebug; copy `vendor/`, `public/build/`, app source; use `supervisord.prod.conf`

### Production `.env` (on VPS only, not committed)

```env
APP_ENV=production
APP_DEBUG=false
APP_URL=https://budget.kostecki.dev

DB_CONNECTION=mysql
DB_HOST=mysql
DB_DATABASE=wallet_master
DB_USERNAME=wallet
DB_PASSWORD=<secret>

QUEUE_CONNECTION=redis
CACHE_STORE=redis
REDIS_HOST=redis

BROADCAST_CONNECTION=reverb
REVERB_APP_ID=<generated>
REVERB_APP_KEY=<generated>
REVERB_APP_SECRET=<generated>
REVERB_HOST=ws.budget.kostecki.dev
REVERB_PORT=443
REVERB_SCHEME=https
REVERB_SERVER_HOST=0.0.0.0
REVERB_SERVER_PORT=8080

VITE_REVERB_APP_KEY="${REVERB_APP_KEY}"
VITE_REVERB_HOST=ws.budget.kostecki.dev
VITE_REVERB_PORT=443
VITE_REVERB_SCHEME=https

SESSION_ENCRYPT=true
SESSION_SECURE_COOKIE=true

TYPESENSE_ENABLED=true
TYPESENSE_HOST=typesense
TYPESENSE_API_KEY=<secret>

HORIZON_ALLOWED_EMAILS=admin@example.com
REGISTRATION_ENABLED=false
BACKUP_DISK=backups
BACKUP_MAIL_TO=admin@example.com
LOG_LEVEL=info
```

**Important:** `QUEUE_CONNECTION=redis` is required — `config/horizon.php` supervisors use the `redis` connection. The current `.env.example` defaults to `database`, which is incorrect for Horizon in production.

`VITE_REVERB_*` must be set **before** `docker build` — values are baked into `public/build/`.

Generate Reverb credentials: `php artisan reverb:install` or set manually.

---

## kostecki-dev-infra changes

| Change | Description |
|--------|-------------|
| `docs/wallet-master.md` | Update domains to `budget.kostecki.dev` / `ws.budget.kostecki.dev`; add Cloudflare Proxied notes |
| `docs/ARCHITECTURE.md` | Move wallet-master from "Planned" to "Current" |
| `scripts/bootstrap-vps.sh` | Add `/srv/apps/wallet-master` directory |
| `scripts/deploy-wallet-master.sh` | Deploy helper (like `deploy-landing.sh`) |
| `.env.example` | Add `VPS_WALLET_DIR=/srv/apps/wallet-master` |

**No changes** to `docker-compose.yml` (Traefik).

---

## kostecki-dev-landing changes

- `.env.example`: `VITE_APP_URL=https://budget.kostecki.dev` (link to app from landing page)

---

## Deployment procedure

### One-time (VPS)

```bash
# 1. Cloudflare DNS (see above) — wait for edge certificates

# 2. App directory
sudo mkdir -p /srv/apps/wallet-master
sudo chown $USER:$USER /srv/apps/wallet-master
git clone git@github.com:USER/wallet-master.git /srv/apps/wallet-master

# 3. Configure environment
cd /srv/apps/wallet-master
cp .env.example .env
# Edit .env (see production values above)
# Generate APP_KEY and Reverb credentials

# 4. First deploy
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml exec -T app php artisan migrate --force
docker compose -f docker-compose.prod.yml exec -T app php artisan config:cache
docker compose -f docker-compose.prod.yml exec -T app php artisan route:cache
docker compose -f docker-compose.prod.yml exec -T app php artisan view:cache
```

### Updates

From infra repo (after `deploy-wallet-master.sh` is added):

```bash
cd /srv/infra
./scripts/deploy-wallet-master.sh
```

Or from wallet-master repo:

```bash
cd /srv/apps/wallet-master
./scripts/deploy.sh
```

### Verification

```bash
curl -I https://budget.kostecki.dev/up     # expect 200
```

Browser checks:

- Login and basic navigation (Inertia, HTTPS links)
- Import with realtime progress (WebSocket via `ws.budget.kostecki.dev`)
- Horizon at `/horizon` (allowlisted email only)
- Session cookie has `Secure` flag (DevTools → Application → Cookies)
- Landing at `https://kostecki.dev` still works

---

## Security and operations

- Health endpoint: `/up` (registered in `bootstrap/app.php`)
- `TrustProxies` and `SecurityHeaders` middleware — already in app
- `APP_DEBUG=false`, `LOG_LEVEL=info` in production
- Horizon gated by `HORIZON_ALLOWED_EMAILS`
- `REGISTRATION_ENABLED=false` by default on production (single-user app)
- Backups: `spatie/laravel-backup` via scheduler (daily 01:00–03:00)
- Mail: `MAIL_MAILER=log` acceptable for initial deploy; configure SMTP later for backup failure notifications

---

## Error handling

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| 502 on `budget.kostecki.dev` | App container not on `proxy` network | Check `docker network inspect proxy` |
| SSL error at Cloudflare | DNS not proxied or Full (strict) without origin cert | Verify Cloudflare SSL mode; check Traefik ACME logs |
| WebSocket fails | Cloudflare WebSockets off, or wrong `VITE_REVERB_*` | Enable WebSockets; rebuild frontend with correct env |
| Horizon idle / jobs stuck | `QUEUE_CONNECTION=database` instead of `redis` | Set `QUEUE_CONNECTION=redis` in `.env` |
| Scheduler not running | Missing `schedule:work` in supervisord | Add to `supervisord.prod.conf` |

---

## Testing before merge

- [ ] `docker compose -f docker-compose.prod.yml config` — valid YAML
- [ ] Production image builds locally (smoke)
- [ ] Migrations on clean database
- [ ] HTTPS + WebSocket through Cloudflare (post-VPS deploy)
- [ ] Landing `kostecki.dev` unaffected

---

## Out of scope (follow-up)

- SMTP configuration for backup alerts
- CI/CD pipeline for wallet-master
- Off-site backup to S3 (`BACKUP_DISK=s3`)
- PHP-FPM + nginx instead of `artisan serve`
- Separate containers per process (reverb, horizon, scheduler)
