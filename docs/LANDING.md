# kostecki-dev-landing

Guide for the **kostecki-dev-landing** repo — local development and production deploy behind Traefik.

Infra / Traefik: [SETUP.md](./SETUP.md)

---

## Stack (current project)

| Layer | Choice |
|-------|--------|
| Package manager | **pnpm** |
| Runtime | **Node.js** `^20.19.0 \|\| >=22.12.0` |
| Language | **TypeScript** |
| Framework | **Vue 3** + **Vite** |
| Routing | **vue-router** |
| Lint | ESLint + Prettier + oxlint |

Tailwind (or other CSS) can be added later — not required for deploy.

---

## Prerequisites — local machine

You need **Node.js** and **pnpm** to develop and build. Docker is only required for production-style serving (nginx container on VPS).

### Install Node.js

Use [nvm](https://github.com/nvm-sh/nvm) or [fnm](https://github.com/Schniz/fnm), then:

```bash
nvm install --lts
node -v   # must satisfy engines in package.json
```

### Enable pnpm

```bash
corepack enable
corepack prepare pnpm@latest --activate
pnpm -v
```

---

## Local development

```bash
git clone git@github.com:USER/kostecki-dev-landing.git
cd kostecki-dev-landing
pnpm install
pnpm dev
# → http://localhost:5173
```

Other scripts:

```bash
pnpm build      # production build → dist/
pnpm preview    # preview production build locally
pnpm lint       # ESLint + oxlint
```

Traefik on the VPS is **not required** for day-to-day work.

---

## Production build

```bash
pnpm install --frozen-lockfile
pnpm build
```

Output: `dist/` — static HTML, JS, CSS served by nginx in Docker.

Optional env (in landing repo `.env`):

```env
VITE_APP_URL=https://app.kostecki.dev
```

Use for “Sign in” links to wallet-master (can 404 until the app exists).

---

## Docker — add to landing repo (before VPS deploy)

These files are **not in the repo yet**. Add them to **kostecki-dev-landing**, commit, push.

### `docker-compose.yml`

```yaml
services:
  landing:
    image: nginx:alpine
    container_name: landing
    restart: unless-stopped
    volumes:
      - ./dist:/usr/share/nginx/html:ro
      - ./docker/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - proxy
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.landing.rule=Host(`kostecki.dev`) || Host(`www.kostecki.dev`)
      - traefik.http.routers.landing.entrypoints=websecure
      - traefik.http.routers.landing.tls.certresolver=letsencrypt
      - traefik.http.services.landing.loadbalancer.server.port=80

networks:
  proxy:
    external: true
```

### `docker/nginx.conf`

```nginx
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

vue-router history mode requires the SPA fallback above.

### `.gitignore`

Ensure `dist/` is **not** ignored if you deploy by building on VPS. Default Vue `.gitignore` often excludes `dist/` — that is fine when you always build on the server.

---

## VPS deploy

Requires Traefik running from **kostecki-dev-infra** ([SETUP.md](./SETUP.md)).

```bash
# One-time: Node + pnpm on VPS
corepack enable && corepack prepare pnpm@latest --activate

git clone git@github.com:USER/kostecki-dev-landing.git /srv/apps/landing
cd /srv/apps/landing
pnpm install --frozen-lockfile
pnpm build
docker compose up -d
```

Updates (from infra repo):

```bash
/srv/infra/scripts/deploy-landing.sh
```

---

## Test Traefik locally (optional)

1. In infra repo: `docker network create proxy && docker compose -f docker-compose.dev.yml up -d`
2. In landing `docker-compose.yml`, temporarily:
   ```yaml
   - traefik.http.routers.landing.rule=Host(`landing.localhost`)
   - traefik.http.routers.landing.entrypoints=web
   ```
3. `pnpm build && docker compose up -d`
4. Open `http://landing.localhost`

---

## Checklist

- [x] Project created (Vue 3 + TypeScript + Vite + vue-router)
- [x] `pnpm dev` works locally
- [x] On GitHub
- [x] `docker-compose.yml` + `docker/nginx.conf` added
- [ ] VPS: Node + pnpm installed
- [ ] VPS: build + `docker compose up -d`
- [ ] https://kostecki.dev live
