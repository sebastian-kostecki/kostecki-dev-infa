# Setup — Traefik + landing

Step-by-step guide to deploy **kostecki-dev-infra** and the landing page on **kostecki.dev**.

Other apps (e.g. wallet-master): [ADDING-AN-APP.md](./ADDING-AN-APP.md) · Laravel details: [wallet-master.md](./wallet-master.md)

---

## Checklist

### kostecki-dev-infra repo

- [ ] Files in repo (docker-compose, scripts, .env.example)
- [ ] `git init` + push to GitHub

### kostecki-dev-landing repo

- [ ] `npm create vue@latest kostecki-dev-landing`
- [ ] Tailwind, `docker-compose.yml`, `docker/nginx.conf`
- [ ] `npm run dev` works locally
- [ ] Push to GitHub

### VPS

- [ ] DNS: `kostecki.dev`, `www.kostecki.dev` → VPS IP
- [ ] `./scripts/bootstrap-vps.sh`
- [ ] Clone infra → `/srv/infra`, `docker compose up -d`
- [ ] Clone landing → `/srv/apps/landing`, build, `docker compose up -d`
- [ ] https://kostecki.dev works with SSL

---

## Purpose of this repo

- Traefik (reverse proxy, SSL)
- Landing deploy script
- Documentation

**Does not include:** Vue code, Laravel, databases. Landing lives in a separate repo: `kostecki-dev-landing`.

---

## Repo structure

```text
kostecki-dev-infra/
├── README.md
├── .env.example
├── .gitignore
├── docker-compose.yml
├── docker-compose.dev.yml      # optional, local dev
├── scripts/
│   ├── bootstrap-vps.sh
│   └── deploy-landing.sh
└── docs/
    ├── SETUP.md
    ├── ARCHITECTURE.md
    ├── ADDING-AN-APP.md
    └── wallet-master.md
```

---

## `.env` (only what you need now)

```env
ACME_EMAIL=admin@kostecki.dev
VPS_LANDING_DIR=/srv/apps/landing
DOMAIN=kostecki.dev
DOMAIN_WWW=www.kostecki.dev
```

On VPS: `cp .env.example .env`

---

## VPS — first run

```bash
# Bootstrap (Docker, firewall, proxy network, directories)
./scripts/bootstrap-vps.sh

# Infra
git clone git@github.com:USER/kostecki-dev-infra.git /srv/infra
cd /srv/infra
cp .env.example .env
docker compose up -d

# Verify
docker compose ps
docker compose logs traefik
```

DNS must point to the VPS **before** Let's Encrypt can issue a certificate.

---

## Landing — connect to Traefik

In **kostecki-dev-landing** — `docker-compose.yml`:

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

`docker/nginx.conf`:

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

Deploy on VPS:

```bash
cd /srv/apps/landing
git clone git@github.com:USER/kostecki-dev-landing.git .
npm ci && npm run build
docker compose up -d
```

Updates: `./scripts/deploy-landing.sh` (from `/srv/infra`)

---

## Local dev — landing

```bash
cd kostecki-dev-landing
npm install
npm run dev
# → http://localhost:5173
```

Traefik on the VPS is **not required** for day-to-day landing development.

### Test Traefik locally (optional)

1. `docker network create proxy`
2. `docker compose -f docker-compose.dev.yml up -d`
3. In landing, temporarily use: `Host(\`landing.localhost\`)`, entrypoint `web`
4. `npm run build && docker compose up -d`

---

## Troubleshooting

**SSL not issued** — DNS → VPS, port 80 open, logs: `docker compose logs traefik`

**Traefik does not see landing** — container on `proxy` network, labels `traefik.enable=true` and `traefik.docker.network=proxy`

**404** — missing `dist/index.html` or missing `try_files` in nginx

**Redirect loop** — landing nginx must not force HTTPS (Traefik handles TLS)

---

## Next application?

See [ADDING-AN-APP.md](./ADDING-AN-APP.md) — **no changes to this repo**, only a new repo + Traefik labels + DNS.
