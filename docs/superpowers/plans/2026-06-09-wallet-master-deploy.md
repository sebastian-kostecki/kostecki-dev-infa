# wallet-master Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy wallet-master on the existing VPS at `budget.kostecki.dev` with WebSockets at `ws.budget.kostecki.dev`, using a supervisord-based Docker production stack behind Cloudflare Proxied + Traefik.

**Architecture:** Single `app` container (supervisord: `artisan serve`, Reverb, Horizon, `schedule:work`) plus MySQL, Redis, and Typesense. Traefik discovers routing via Docker labels on the `app` container. Multi-stage `Dockerfile.prod` bakes `vendor/` and `public/build/` into the image so the VPS does not need Node.

**Tech Stack:** Laravel 12, Sail PHP 8.5 image base, supervisord, Docker Compose, Traefik v3.6, Cloudflare Proxied, MySQL 8.4, Redis, Typesense 27.1

**Spec:** [2026-06-09-wallet-master-deploy-design.md](../specs/2026-06-09-wallet-master-deploy-design.md)

---

## File map

| Repo | File | Responsibility |
|------|------|----------------|
| wallet-master | `docker/8.5/supervisord.prod.conf` | Production process manager (HTTP, Reverb, Horizon, scheduler) |
| wallet-master | `docker/8.5/Dockerfile.prod` | Multi-stage prod image build |
| wallet-master | `docker-compose.prod.yml` | Prod stack + Traefik labels |
| wallet-master | `scripts/deploy.sh` | Pull, build, up, migrate, cache |
| wallet-master | `.env.example` | Production env documentation + Horizon/redis notes |
| kostecki-dev-infra | `scripts/deploy-wallet-master.sh` | Infra-side deploy wrapper |
| kostecki-dev-infra | `scripts/bootstrap-vps.sh` | Add wallet-master directory |
| kostecki-dev-infra | `.env.example` | `VPS_WALLET_DIR` variable |
| kostecki-dev-infra | `docs/wallet-master.md` | Updated deployment guide |
| kostecki-dev-infra | `docs/ARCHITECTURE.md` | wallet-master in current state |
| kostecki-dev-infra | `docs/SETUP.md` | Link to wallet-master deploy |
| kostecki-dev-landing | `.env.example` | `VITE_APP_URL=https://budget.kostecki.dev` |

---

## Task 1: Production supervisord config

**Files:**
- Create: `wallet-master/docker/8.5/supervisord.prod.conf`

- [ ] **Step 1: Create supervisord.prod.conf**

```ini
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:php]
command=%(ENV_SUPERVISOR_PHP_COMMAND)s
user=%(ENV_SUPERVISOR_PHP_USER)s
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:reverb]
command=php /var/www/html/artisan reverb:start --host=0.0.0.0 --port=8080
autostart=true
autorestart=true
user=%(ENV_SUPERVISOR_PHP_USER)s
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/reverb.log

[program:horizon]
command=php /var/www/html/artisan horizon
autostart=true
autorestart=true
user=%(ENV_SUPERVISOR_PHP_USER)s
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/horizon.log

[program:scheduler]
command=php /var/www/html/artisan schedule:work
autostart=true
autorestart=true
user=%(ENV_SUPERVISOR_PHP_USER)s
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/scheduler.log
```

- [ ] **Step 2: Commit**

```bash
cd /home/sebastian/my-projects/wallet-master
git add docker/8.5/supervisord.prod.conf
git commit -m "Add production supervisord config with scheduler."
```

---

## Task 2: Production Dockerfile (multi-stage)

**Files:**
- Create: `wallet-master/docker/8.5/Dockerfile.prod`

- [ ] **Step 1: Create Dockerfile.prod**

```dockerfile
# syntax=docker/dockerfile:1

FROM composer:2 AS vendor
WORKDIR /var/www/html
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist
COPY . .
RUN composer install --no-dev --optimize-autoloader --no-interaction

FROM node:24-alpine AS assets
WORKDIR /var/www/html
COPY package.json package-lock.json ./
RUN npm ci
COPY --from=vendor /var/www/html/vendor ./vendor
COPY vite.config.ts tsconfig.json tsconfig.*.json ./
COPY resources ./resources
COPY public ./public
ARG VITE_APP_NAME="Wallet Master"
ARG VITE_REVERB_APP_KEY
ARG VITE_REVERB_HOST=ws.budget.kostecki.dev
ARG VITE_REVERB_PORT=443
ARG VITE_REVERB_SCHEME=https
ENV VITE_APP_NAME="${VITE_APP_NAME}" \
    VITE_REVERB_APP_KEY="${VITE_REVERB_APP_KEY}" \
    VITE_REVERB_HOST="${VITE_REVERB_HOST}" \
    VITE_REVERB_PORT="${VITE_REVERB_PORT}" \
    VITE_REVERB_SCHEME="${VITE_REVERB_SCHEME}"
RUN npm run build

FROM ubuntu:24.04 AS runtime

LABEL maintainer="wallet-master"

ARG WWWGROUP=1000
ARG NODE_VERSION=24

WORKDIR /var/www/html

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC
ENV LANG=C.UTF-8
ENV SUPERVISOR_PHP_COMMAND="/usr/bin/php -d variables_order=EGPCS /var/www/html/artisan serve --host=0.0.0.0 --port=80"
ENV SUPERVISOR_PHP_USER="sail"

RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apt-get update && apt-get upgrade -y \
    && mkdir -p /etc/apt/keyrings \
    && apt-get install -y gnupg gosu curl ca-certificates zip unzip git supervisor sqlite3 libcap2-bin libpng-dev python3 dnsutils librsvg2-bin nano \
    && curl -sS 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xb8dc7e53946656efbce4c1dd71daeaab4ad4cab6' | gpg --dearmor | tee /etc/apt/keyrings/ppa_ondrej_php.gpg > /dev/null \
    && echo "deb [signed-by=/etc/apt/keyrings/ppa_ondrej_php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu noble main" > /etc/apt/sources.list.d/ppa_ondrej_php.list \
    && apt-get update \
    && apt-get install -y \
        libgd3 \
        php8.5-cli \
        php8.5-dev \
        php8.5-pgsql \
        php8.5-sqlite3 \
        php8.5-gd \
        php8.5-curl \
        php8.5-mysql \
        php8.5-mbstring \
        php8.5-xml \
        php8.5-zip \
        php8.5-bcmath \
        php8.5-intl \
        php8.5-readline \
        php8.5-redis \
        php8.5-igbinary \
        php8.5-msgpack \
        mysql-client \
    && curl -sLS https://getcomposer.org/installer | php -- --install-dir=/usr/bin/ --filename=composer \
    && apt-get -y autoremove \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN setcap "cap_net_bind_service=+ep" /usr/bin/php8.5

RUN groupadd --force -g $WWWGROUP sail \
    && useradd -ms /bin/bash --no-user-group -g $WWWGROUP -u 1337 sail \
    && git config --global --add safe.directory /var/www/html

COPY docker/8.5/start-container /usr/local/bin/start-container
COPY docker/8.5/supervisord.prod.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/8.5/php.ini /etc/php/8.5/cli/conf.d/99-sail.ini
RUN chmod +x /usr/local/bin/start-container

COPY --from=vendor --chown=sail:sail /var/www/html /var/www/html
COPY --from=assets --chown=sail:sail /var/www/html/public/build /var/www/html/public/build

RUN mkdir -p storage/framework/{cache,sessions,views} storage/logs bootstrap/cache \
    && chown -R sail:sail storage bootstrap/cache

EXPOSE 80/tcp 8080/tcp

ENTRYPOINT ["start-container"]
```

- [ ] **Step 2: Verify Docker syntax locally**

Run:

```bash
cd /home/sebastian/my-projects/wallet-master
docker build -f docker/8.5/Dockerfile.prod \
  --build-arg VITE_REVERB_APP_KEY=test-key \
  --build-arg WWWGROUP=1000 \
  -t wallet-master-prod:test .
```

Expected: image builds successfully (may take several minutes on first run).

- [ ] **Step 3: Commit**

```bash
git add docker/8.5/Dockerfile.prod
git commit -m "Add multi-stage production Dockerfile."
```

---

## Task 3: Production docker-compose

**Files:**
- Create: `wallet-master/docker-compose.prod.yml`

- [ ] **Step 1: Create docker-compose.prod.yml**

```yaml
services:
  app:
    build:
      context: .
      dockerfile: docker/8.5/Dockerfile.prod
      args:
        WWWGROUP: ${WWWGROUP:-1000}
        VITE_REVERB_APP_KEY: ${REVERB_APP_KEY}
        VITE_REVERB_HOST: ${VITE_REVERB_HOST:-ws.budget.kostecki.dev}
        VITE_REVERB_PORT: ${VITE_REVERB_PORT:-443}
        VITE_REVERB_SCHEME: ${VITE_REVERB_SCHEME:-https}
    image: wallet-master-app:prod
    container_name: wallet-app
    restart: unless-stopped
    environment:
      WWWUSER: ${WWWUSER:-1000}
      SUPERVISOR_PHP_USER: sail
    volumes:
      - ./storage:/var/www/html/storage
      - ./bootstrap/cache:/var/www/html/bootstrap/cache
      - ./.env:/var/www/html/.env:ro
    networks:
      - wallet-internal
      - proxy
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.wallet.rule=Host(`budget.kostecki.dev`)
      - traefik.http.routers.wallet.entrypoints=websecure
      - traefik.http.routers.wallet.tls.certresolver=letsencrypt
      - traefik.http.services.wallet.loadbalancer.server.port=80
      - traefik.http.routers.wallet-ws.rule=Host(`ws.budget.kostecki.dev`)
      - traefik.http.routers.wallet-ws.entrypoints=websecure
      - traefik.http.routers.wallet-ws.tls.certresolver=letsencrypt
      - traefik.http.services.wallet-ws.loadbalancer.server.port=8080

  mysql:
    image: mysql:8.4
    container_name: wallet-mysql
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: ${DB_DATABASE}
      MYSQL_USER: ${DB_USERNAME}
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
    volumes:
      - wallet-mysql:/var/lib/mysql
    networks:
      - wallet-internal
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-p${DB_PASSWORD}"]
      retries: 5
      timeout: 5s
      interval: 10s

  redis:
    image: redis:alpine
    container_name: wallet-redis
    restart: unless-stopped
    volumes:
      - wallet-redis:/data
    networks:
      - wallet-internal
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      retries: 5
      timeout: 5s
      interval: 10s

  typesense:
    image: typesense/typesense:27.1
    container_name: wallet-typesense
    restart: unless-stopped
    environment:
      TYPESENSE_API_KEY: ${TYPESENSE_API_KEY}
      TYPESENSE_DATA_DIR: /typesense-data
    volumes:
      - wallet-typesense:/typesense-data
    networks:
      - wallet-internal
    healthcheck:
      test:
        [
          "CMD",
          "bash",
          "-c",
          "exec 3<>/dev/tcp/localhost/8108 && printf 'GET /health HTTP/1.1\r\nConnection: close\r\n\r\n' >&3 && head -n1 <&3 | grep '200' && exec 3>&-",
        ]
      retries: 5
      timeout: 7s
      interval: 15s

networks:
  wallet-internal:
    driver: bridge
  proxy:
    external: true

volumes:
  wallet-mysql:
  wallet-redis:
  wallet-typesense:
```

- [ ] **Step 2: Validate compose file**

Run:

```bash
cd /home/sebastian/my-projects/wallet-master
docker compose -f docker-compose.prod.yml config --quiet
```

Expected: no output (exit 0). Requires a `.env` with `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `REVERB_APP_KEY`, `TYPESENSE_API_KEY` set (copy from `.env.example` and fill placeholders for local validation).

- [ ] **Step 3: Commit**

```bash
git add docker-compose.prod.yml
git commit -m "Add production docker-compose with Traefik labels."
```

---

## Task 4: Deploy script (wallet-master)

**Files:**
- Create: `wallet-master/scripts/deploy.sh`

- [ ] **Step 1: Create scripts/deploy.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose -f docker-compose.prod.yml"

echo "==> Pulling latest..."
git pull

echo "==> Building app image..."
$COMPOSE build app

echo "==> Starting stack..."
$COMPOSE up -d

echo "==> Running migrations..."
$COMPOSE exec -T app php artisan migrate --force

echo "==> Caching config/routes/views..."
$COMPOSE exec -T app php artisan config:cache
$COMPOSE exec -T app php artisan route:cache
$COMPOSE exec -T app php artisan view:cache

echo "==> Done. Check https://budget.kostecki.dev/up"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/deploy.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/deploy.sh
git commit -m "Add production deploy script."
```

---

## Task 5: Update .env.example (wallet-master)

**Files:**
- Modify: `wallet-master/.env.example`

- [ ] **Step 1: Add production section and fix queue default comment**

After the existing `APP_URL` production comment block, ensure these lines exist (add or update):

```env
# Production (budget.kostecki.dev behind Cloudflare Proxied + Traefik):
# APP_ENV=production
# APP_DEBUG=false
# APP_URL=https://budget.kostecki.dev
# LOG_LEVEL=info
# DB_CONNECTION=mysql
# DB_HOST=mysql
# QUEUE_CONNECTION=redis          # required for Horizon (config/horizon.php uses redis)
# CACHE_STORE=redis
# REDIS_HOST=redis
# BROADCAST_CONNECTION=reverb
# REVERB_HOST=ws.budget.kostecki.dev
# REVERB_PORT=443
# REVERB_SCHEME=https
# REVERB_SERVER_HOST=0.0.0.0
# REVERB_SERVER_PORT=8080
# VITE_REVERB_HOST=ws.budget.kostecki.dev
# VITE_REVERB_PORT=443
# VITE_REVERB_SCHEME=https
# SESSION_ENCRYPT=true
# SESSION_SECURE_COOKIE=true
# TYPESENSE_ENABLED=true
# TYPESENSE_HOST=typesense
# HORIZON_ALLOWED_EMAILS=you@example.com
# REGISTRATION_ENABLED=false
```

- [ ] **Step 2: Commit**

```bash
git add .env.example
git commit -m "Document production environment variables for VPS deploy."
```

---

## Task 6: Infra deploy script and bootstrap

**Files:**
- Create: `kostecki-dev-infra/scripts/deploy-wallet-master.sh`
- Modify: `kostecki-dev-infra/scripts/bootstrap-vps.sh`
- Modify: `kostecki-dev-infra/.env.example`

- [ ] **Step 1: Create scripts/deploy-wallet-master.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

WALLET_DIR="${VPS_WALLET_DIR:-/srv/apps/wallet-master}"

cd "$WALLET_DIR"

echo "==> Deploying wallet-master..."
./scripts/deploy.sh

echo "==> Done. Check https://budget.kostecki.dev"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x /home/sebastian/my-projects/kostecki-dev-infra/scripts/deploy-wallet-master.sh
```

- [ ] **Step 3: Update bootstrap-vps.sh**

Change the mkdir line from:

```bash
sudo mkdir -p /srv/infra /srv/apps/landing
```

to:

```bash
sudo mkdir -p /srv/infra /srv/apps/landing /srv/apps/wallet-master
```

Add to the "Done. Next steps" echo block:

```bash
echo "  5. Clone wallet-master to /srv/apps/wallet-master — see docs/wallet-master.md"
```

- [ ] **Step 4: Update .env.example**

Add after `VPS_LANDING_DIR`:

```env
# Wallet-master deploy path on VPS
VPS_WALLET_DIR=/srv/apps/wallet-master
```

- [ ] **Step 5: Commit**

```bash
cd /home/sebastian/my-projects/kostecki-dev-infra
git add scripts/deploy-wallet-master.sh scripts/bootstrap-vps.sh .env.example
git commit -m "Add wallet-master deploy script and bootstrap directory."
```

---

## Task 7: Update infra documentation

**Files:**
- Modify: `kostecki-dev-infra/docs/wallet-master.md`
- Modify: `kostecki-dev-infra/docs/ARCHITECTURE.md`
- Modify: `kostecki-dev-infra/docs/SETUP.md`

- [ ] **Step 1: Rewrite docs/wallet-master.md header and domains**

Replace title `(later)` with active deployment guide. Update all `app.kostecki.dev` → `budget.kostecki.dev` and `ws.kostecki.dev` → `ws.budget.kostecki.dev`. Replace the architecture diagram to show supervisord single-container approach (no separate nginx/queue/reverb containers). Add a **Cloudflare** section:

```markdown
## Cloudflare (Proxied)

- A records for `budget` and `ws.budget` → VPS IP, **Proxied** (orange cloud)
- SSL/TLS mode: **Full (strict)**
- Network → WebSockets: **On**
- Origin TLS is handled by Traefik (Let's Encrypt), same as landing
```

Update the docker-compose outline to reference actual files: `docker-compose.prod.yml`, `docker/8.5/Dockerfile.prod`, `scripts/deploy.sh`.

Update deploy section to use `./scripts/deploy.sh` and infra wrapper `./scripts/deploy-wallet-master.sh`.

- [ ] **Step 2: Update docs/ARCHITECTURE.md**

Replace "Planned state" section with current state including wallet-master:

```text
Traefik
├── kostecki.dev           → landing
├── budget.kostecki.dev    → wallet-master (Laravel + Inertia)
└── ws.budget.kostecki.dev → Reverb (WebSocket)
```

Update repos table domain column. Remove `# wallet-master/ ← add later` comment from VPS directory tree.

- [ ] **Step 3: Update docs/SETUP.md checklist**

Add wallet-master section after landing deploy:

```markdown
### wallet-master

- [ ] DNS: `budget.kostecki.dev`, `ws.budget.kostecki.dev` → VPS IP (Cloudflare Proxied)
- [ ] Clone wallet-master → `/srv/apps/wallet-master`
- [ ] Configure `.env` (see docs/wallet-master.md)
- [ ] `docker compose -f docker-compose.prod.yml up -d`
- [ ] https://budget.kostecki.dev/up returns 200
```

- [ ] **Step 4: Commit**

```bash
cd /home/sebastian/my-projects/kostecki-dev-infra
git add docs/wallet-master.md docs/ARCHITECTURE.md docs/SETUP.md
git commit -m "Update docs for wallet-master deployment on budget.kostecki.dev."
```

---

## Task 8: Landing .env.example link

**Files:**
- Modify: `kostecki-dev-landing/.env.example`

- [ ] **Step 1: Update VITE_APP_URL**

```env
VITE_APP_URL=https://budget.kostecki.dev
```

- [ ] **Step 2: Commit**

```bash
cd /home/sebastian/my-projects/kostecki-dev-landing
git add .env.example
git commit -m "Point landing app link to budget.kostecki.dev."
```

---

## Task 9: Local smoke test (wallet-master)

**Files:** none (validation only)

- [ ] **Step 1: Prepare test .env**

```bash
cd /home/sebastian/my-projects/wallet-master
cp .env.example .env
```

Set at minimum:

```env
DB_CONNECTION=mysql
DB_HOST=mysql
DB_DATABASE=wallet_master
DB_USERNAME=wallet
DB_PASSWORD=secret
DB_PASSWORD=secret

QUEUE_CONNECTION=redis
CACHE_STORE=redis
REDIS_HOST=redis

REVERB_APP_KEY=test-key
REVERB_APP_ID=test-id
REVERB_APP_SECRET=test-secret

TYPESENSE_API_KEY=xyz
TYPESENSE_HOST=typesense
TYPESENSE_ENABLED=true

WWWGROUP=1000
WWWUSER=1000
```

- [ ] **Step 2: Build and start stack**

```bash
docker compose -f docker-compose.prod.yml build app
docker compose -f docker-compose.prod.yml up -d
```

Expected: all containers healthy within ~60s.

- [ ] **Step 3: Run migrations and verify health**

```bash
docker compose -f docker-compose.prod.yml exec -T app php artisan migrate --force
docker compose -f docker-compose.prod.yml exec -T app php artisan config:cache
curl -s -o /dev/null -w "%{http_code}" http://localhost/up
```

Note: `/up` is not exposed on host ports — verify via exec instead:

```bash
docker compose -f docker-compose.prod.yml exec -T app curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/up
```

Expected: `200`

- [ ] **Step 4: Verify supervisord processes**

```bash
docker compose -f docker-compose.prod.yml exec -T app supervisorctl status
```

Expected: `php`, `reverb`, `horizon`, `scheduler` all `RUNNING`.

- [ ] **Step 5: Tear down local test stack**

```bash
docker compose -f docker-compose.prod.yml down -v
```

---

## Task 10: VPS deployment (manual, post-merge)

**Files:** none (operations)

- [ ] **Step 1: Cloudflare DNS**

Add proxied A records: `budget`, `ws.budget` → VPS IP. Confirm SSL/TLS Full (strict) and WebSockets enabled.

- [ ] **Step 2: Clone and configure on VPS**

```bash
git clone git@github.com:USER/wallet-master.git /srv/apps/wallet-master
cd /srv/apps/wallet-master
cp .env.example .env
# Edit .env with production secrets (see spec)
php artisan key:generate   # run via temporary container if PHP not on host:
docker compose -f docker-compose.prod.yml run --rm app php artisan key:generate
```

- [ ] **Step 3: First deploy**

```bash
./scripts/deploy.sh
```

- [ ] **Step 4: Verify production**

```bash
curl -I https://budget.kostecki.dev/up
```

Expected: `HTTP/2 200`

Browser: login, import realtime progress, Horizon at `/horizon`, landing still at `https://kostecki.dev`.

---

## Plan self-review

| Spec requirement | Task |
|------------------|------|
| `budget.kostecki.dev` routing | Task 3 Traefik labels |
| `ws.budget.kostecki.dev` WebSocket | Task 3 Traefik labels + Task 1 reverb |
| Supervisord (serve, reverb, horizon, scheduler) | Task 1, Task 2 |
| Multi-stage build (no Node on VPS) | Task 2 |
| MySQL, Redis, Typesense | Task 3 |
| `QUEUE_CONNECTION=redis` documented | Task 5 |
| Infra deploy script | Task 6 |
| Docs update | Task 7 |
| Landing link | Task 8 |
| Cloudflare Proxied notes | Task 7 |
| No Traefik infra changes | Confirmed — labels only in wallet-master |
| Verification | Task 9 (local), Task 10 (VPS) |

No placeholders or TBD items remain in task steps.
