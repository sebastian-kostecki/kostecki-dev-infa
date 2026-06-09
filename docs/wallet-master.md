# wallet-master deployment

Deployment guide for Laravel + Inertia + Reverb + Horizon on **budget.kostecki.dev**.

Related: [ADDING-AN-APP.md](./ADDING-AN-APP.md) · [ARCHITECTURE.md](./ARCHITECTURE.md)

---

## Is Reverb a separate application?

**No.** Reverb is a **supervisord program in the wallet-master app container** — same Laravel codebase, command `php artisan reverb:start`.

WebSockets use the **same domain** as the app (`budget.kostecki.dev`, paths `/app` and `/apps`) — not a separate repo or product.

```text
wallet-master (one repo, one docker-compose.prod.yml)
├── app         → supervisord: artisan serve, reverb, horizon, schedule:work
│                 Traefik: budget.kostecki.dev :80, /app + /apps → :8080 (Reverb)
├── mysql
├── redis
└── typesense
```

Analogy: Horizon and the scheduler are also separate processes, but nobody treats them as separate applications.

---

## Repositories vs landing

| | kostecki-dev-landing | wallet-master |
|--|---------------------|---------------|
| Type | static Vue (`dist/`) | Laravel + Inertia |
| Vue | standalone SPA project | Vue in `resources/js/Pages/` |
| PHP | none | yes |
| Domain | kostecki.dev | budget.kostecki.dev |

Inertia does **not** live in the landing repo — assets are built in the Laravel repo (`npm run build` → `public/build/`) and baked into the production image via `docker/8.5/Dockerfile.prod`.

---

## DNS

```text
budget.kostecki.dev  →  VPS IP (Cloudflare Proxied)
```

WebSockets use the same host (`wss://budget.kostecki.dev/app/...`). Do **not** use `ws.budget.kostecki.dev` — Cloudflare Universal SSL covers `*.kostecki.dev` only, not third-level names like `*.budget.kostecki.dev`.

---

## Cloudflare (Proxied)

- A record for `budget` → VPS IP, **Proxied** (orange cloud)
- SSL/TLS mode: **Full (strict)**
- Network → WebSockets: **On**
- Origin TLS is handled by Traefik (Let's Encrypt), same as landing

---

## VPS directory

```bash
sudo mkdir -p /srv/apps/wallet-master
git clone git@github.com:USER/wallet-master.git /srv/apps/wallet-master
```

`bootstrap-vps.sh` creates this directory automatically.

---

## Traefik labels

Labels live on the **app** container in wallet-master's `docker-compose.prod.yml`. You do **not** change the infra repo.

**HTTP / Inertia (`budget.kostecki.dev`):**

```yaml
labels:
  - traefik.enable=true
  - traefik.docker.network=proxy
  - traefik.http.routers.wallet.rule=Host(`budget.kostecki.dev`)
  - traefik.http.routers.wallet.entrypoints=websecure
  - traefik.http.routers.wallet.tls.certresolver=letsencrypt
  - traefik.http.services.wallet.loadbalancer.server.port=80
```

**WebSocket (same host, Reverb paths):**

```yaml
labels:
  - traefik.http.routers.wallet-ws.rule=Host(`budget.kostecki.dev`) && (PathPrefix(`/app`) || PathPrefix(`/apps`))
  - traefik.http.routers.wallet-ws.priority=100
  - traefik.http.routers.wallet-ws.entrypoints=websecure
  - traefik.http.routers.wallet-ws.tls.certresolver=letsencrypt
  - traefik.http.services.wallet-ws.loadbalancer.server.port=8080
```

---

## Production stack

Keep Sail (`docker-compose.yml`) **local only**. On VPS use `docker-compose.prod.yml` with:

| File | Purpose |
|------|---------|
| `docker-compose.prod.yml` | app + mysql + redis + typesense + Traefik labels |
| `docker/8.5/Dockerfile.prod` | Multi-stage build: composer + npm + PHP runtime |
| `docker/8.5/supervisord.prod.conf` | artisan serve, reverb, horizon, schedule:work |
| `scripts/deploy.sh` | Pull, build, up, migrate, cache |

```text
services:
  app       supervisord (serve :80, reverb :8080, horizon, scheduler)
            networks: wallet-internal + proxy
            volumes: storage, bootstrap/cache, .env
  mysql     persistent data, healthcheck
  redis     queues + cache, healthcheck
  typesense persistent data, healthcheck

networks:
  wallet-internal   bridge (internal services)
  proxy             external (Traefik discovery)

volumes:
  wallet-mysql, wallet-redis, wallet-typesense
```

**Excluded from prod vs Sail:** mailpit, Vite dev server, Xdebug, public DB/Redis/Typesense ports, separate nginx/queue/reverb containers.

---

## Laravel .env (prod) — key settings

See `wallet-master/.env.example` for the full production block. Minimum:

```env
APP_URL=https://budget.kostecki.dev
APP_ENV=production
APP_DEBUG=false

DB_CONNECTION=mysql
DB_HOST=mysql

QUEUE_CONNECTION=redis
CACHE_STORE=redis
REDIS_HOST=redis

BROADCAST_CONNECTION=reverb
REVERB_HOST=budget.kostecki.dev
REVERB_PORT=443
REVERB_SCHEME=https
REVERB_SERVER_HOST=0.0.0.0
REVERB_SERVER_PORT=8080

VITE_REVERB_HOST=budget.kostecki.dev
VITE_REVERB_PORT=443
VITE_REVERB_SCHEME=https

TYPESENSE_ENABLED=true
TYPESENSE_HOST=typesense
```

`VITE_REVERB_*` are passed as Docker build args in `docker-compose.prod.yml` — rebuild the app image after changing them.

---

## Backups

Backups use [spatie/laravel-backup](https://github.com/spatie/laravel-backup) (`BACKUP_DISK=backups`). The scheduler runs `backup:run` daily at 01:30 (see `routes/console.php`).

On the VPS, archives are stored **outside the app directory**:

```text
/storage/wallet-master-backups/   ← host (persistent)
        ↓ mounted into container as
/var/www/html/storage/app/backups/
```

`docker-compose.prod.yml` mounts the host path via `BACKUP_HOST_DIR` (default `/storage/wallet-master-backups`).

### One-time setup (VPS)

```bash
sudo mkdir -p /storage/wallet-master-backups
sudo chown -R "$USER:$USER" /storage/wallet-master-backups
```

`bootstrap-vps.sh` creates this directory automatically on new servers.

### Test a backup manually

```bash
cd /srv/apps/wallet-master
docker compose -f docker-compose.prod.yml exec -T app php artisan backup:run --only-db
ls -la /storage/wallet-master-backups/
```

---

## Deploy

### First deploy (on VPS)

```bash
cd /srv/apps/wallet-master
cp .env.example .env
# Edit .env with production secrets

docker compose -f docker-compose.prod.yml run --rm app php artisan key:generate
./scripts/deploy.sh
```

### Updates (from wallet-master repo)

```bash
cd /srv/apps/wallet-master
./scripts/deploy.sh
```

`scripts/deploy.sh` pulls, builds the app image, starts the stack, runs migrations, and caches config/routes/views.

### Updates (from infra repo)

```bash
cd /srv/infra
./scripts/deploy-wallet-master.sh
```

Uses `VPS_WALLET_DIR` from infra `.env` (default `/srv/apps/wallet-master`).

---

## Verify

```bash
curl -I https://budget.kostecki.dev/up
```

Expected: `HTTP/2 200`

Check supervisord processes:

```bash
docker compose -f docker-compose.prod.yml exec -T app supervisorctl status
```

Expected: `php`, `reverb`, `horizon`, `scheduler` all `RUNNING`.

---

## Local dev — Sail

In wallet-master repo:

```bash
./vendor/bin/sail up -d
./vendor/bin/sail npm run dev
```

Sail and Traefik on VPS operate independently.
