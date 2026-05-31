# wallet-master (later)

Deployment plan for Laravel + Inertia + Reverb. **Not needed at startup** — return here when the landing is live and you start wallet-master.

Related: [ADDING-AN-APP.md](./ADDING-AN-APP.md) · [ARCHITECTURE.md](./ARCHITECTURE.md)

---

## Is Reverb a separate application?

**No.** Reverb is a **container in the wallet-master stack** — same Laravel codebase, command `php artisan reverb:start`.

It has a **separate subdomain** (`ws.kostecki.dev`) because WebSockets are easier to route separately — it is not a separate repo or product.

```text
wallet-master (one repo, one docker-compose.prod.yml)
├── nginx       → app.kostecki.dev
├── app         → PHP-FPM (Inertia)
├── queue       → php artisan queue:work
├── reverb      → php artisan reverb:start  → ws.kostecki.dev
├── scheduler   → optional
├── mysql, redis, typesense
```

Analogy: `queue` is also a separate container, but nobody treats it as a separate application.

---

## Repositories vs landing

| | kostecki-dev-landing | wallet-master |
|--|---------------------|---------------|
| Type | static Vue (`dist/`) | Laravel + Inertia |
| Vue | standalone SPA project | Vue in `resources/js/Pages/` |
| PHP | none | yes |
| Domain | kostecki.dev | app.kostecki.dev |

Inertia does **not** live in the landing repo — assets are built in the Laravel repo (`npm run build` → `public/build/`).

---

## DNS (when deploying)

```text
app.kostecki.dev  →  VPS_IP
ws.kostecki.dev   →  VPS_IP
```

Optionally earlier: wildcard `*.kostecki.dev`.

---

## VPS directory

```bash
sudo mkdir -p /srv/apps/wallet-master
git clone git@github.com:USER/wallet-master.git /srv/apps/wallet-master
```

---

## Traefik labels

**nginx (HTTP / Inertia):**

```yaml
labels:
  - traefik.enable=true
  - traefik.docker.network=proxy
  - traefik.http.routers.laravel.rule=Host(`app.kostecki.dev`)
  - traefik.http.routers.laravel.entrypoints=websecure
  - traefik.http.routers.laravel.tls.certresolver=letsencrypt
  - traefik.http.services.laravel.loadbalancer.server.port=80
```

**reverb (WebSocket):**

```yaml
labels:
  - traefik.enable=true
  - traefik.docker.network=proxy
  - traefik.http.routers.reverb.rule=Host(`ws.kostecki.dev`)
  - traefik.http.routers.reverb.entrypoints=websecure
  - traefik.http.routers.reverb.tls.certresolver=letsencrypt
  - traefik.http.services.reverb.loadbalancer.server.port=8080
```

You do **not** change the infra repo — labels go in wallet-master's `docker-compose.prod.yml`.

---

## docker-compose.prod.yml (outline)

Keep Sail (`docker-compose.yml`) **local only**. Use a separate prod file on VPS.

```yaml
services:
  nginx:
    image: nginx:alpine
    container_name: laravel-nginx
    volumes:
      - ./docker/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./public:/var/www/html/public:ro
    depends_on:
      - app
    networks:
      - laravel-internal
      - proxy
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.laravel.rule=Host(`app.kostecki.dev`)
      - traefik.http.routers.laravel.entrypoints=websecure
      - traefik.http.routers.laravel.tls.certresolver=letsencrypt
      - traefik.http.services.laravel.loadbalancer.server.port=80

  app:
    build:
      context: .
      dockerfile: docker/8.5/Dockerfile.prod
    volumes:
      - ./storage:/var/www/html/storage
      - ./.env:/var/www/html/.env:ro
    networks:
      - laravel-internal
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy

  queue:
    build:
      context: .
      dockerfile: docker/8.5/Dockerfile.prod
    command: php artisan queue:work --sleep=3 --tries=3
    volumes:
      - ./storage:/var/www/html/storage
      - ./.env:/var/www/html/.env:ro
    networks:
      - laravel-internal
    depends_on:
      - app
      - redis

  reverb:
    build:
      context: .
      dockerfile: docker/8.5/Dockerfile.prod
    container_name: reverb
    command: php artisan reverb:start
    volumes:
      - ./storage:/var/www/html/storage
      - ./.env:/var/www/html/.env:ro
    networks:
      - laravel-internal
      - proxy
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.reverb.rule=Host(`ws.kostecki.dev`)
      - traefik.http.routers.reverb.entrypoints=websecure
      - traefik.http.routers.reverb.tls.certresolver=letsencrypt
      - traefik.http.services.reverb.loadbalancer.server.port=8080
    depends_on:
      - app
      - redis

  mysql:
    image: mysql:8.4
    environment:
      MYSQL_DATABASE: ${DB_DATABASE}
      MYSQL_USER: ${DB_USERNAME}
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
    volumes:
      - sail-mysql:/var/lib/mysql
    networks:
      - laravel-internal
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-p${DB_PASSWORD}"]
      retries: 3
      timeout: 5s

  redis:
    image: redis:alpine
    volumes:
      - sail-redis:/data
    networks:
      - laravel-internal

  typesense:
    image: typesense/typesense:27.1
    environment:
      TYPESENSE_API_KEY: ${TYPESENSE_API_KEY}
      TYPESENSE_DATA_DIR: /typesense-data
    volumes:
      - sail-typesense:/typesense-data
    networks:
      - laravel-internal

networks:
  laravel-internal:
  proxy:
    external: true

volumes:
  sail-mysql:
  sail-redis:
  sail-typesense:
```

**Remove from prod vs Sail:** mailpit, Vite dev server, Xdebug, public DB/Redis ports.

---

## Laravel .env (prod) — Reverb

```env
APP_URL=https://app.kostecki.dev
APP_ENV=production
APP_DEBUG=false

BROADCAST_CONNECTION=reverb
REVERB_HOST=ws.kostecki.dev
REVERB_PORT=443
REVERB_SCHEME=https
REVERB_SERVER_HOST=0.0.0.0
REVERB_SERVER_PORT=8080

VITE_REVERB_HOST=ws.kostecki.dev
VITE_REVERB_PORT=443
VITE_REVERB_SCHEME=https
```

`npm run build` in the Laravel repo must have `VITE_REVERB_*` set.

---

## Deploy (example script)

Save in wallet-master repo as `scripts/deploy.sh`, or run manually:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd /srv/apps/wallet-master

git pull
docker compose -f docker-compose.prod.yml build app queue reverb
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml exec -T app php artisan migrate --force
docker compose -f docker-compose.prod.yml exec -T app php artisan config:cache
docker compose -f docker-compose.prod.yml exec -T app php artisan route:cache
docker compose -f docker-compose.prod.yml exec -T app php artisan view:cache
```

---

## Local dev — Sail

In wallet-master repo:

```bash
./vendor/bin/sail up -d
./vendor/bin/sail npm run dev
```

Sail and Traefik on VPS operate independently.

---

## To clarify before deployment

- [ ] `Dockerfile.prod` (multi-stage: composer + npm build + PHP-FPM)
- [ ] SMTP (instead of Mailpit)
- [ ] MySQL backup (cron)
- [ ] CI/CD
