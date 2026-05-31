# Setup — Traefik + landing

Step-by-step guide to deploy **kostecki-dev-infra** and the landing page on **kostecki.dev**.

- Landing repo details: [LANDING.md](./LANDING.md)
- Other apps later: [ADDING-AN-APP.md](./ADDING-AN-APP.md) · Laravel: [wallet-master.md](./wallet-master.md)

---

## Checklist

### kostecki-dev-infra

- [x] Files in repo (docker-compose, scripts, .env.example)
- [x] Push to GitHub

### kostecki-dev-landing

- [x] Vue 3 project created (`pnpm create vue`)
- [x] Local dev works (`pnpm dev`)
- [x] Push to GitHub
- [x] Add `docker-compose.yml` + `docker/nginx.conf` — see [LANDING.md](./LANDING.md)
- [x] Push Docker files to GitHub

### VPS

- [ ] DNS: `kostecki.dev`, `www.kostecki.dev` → VPS IP
- [ ] Node.js + pnpm on VPS (for build)
- [ ] `./scripts/bootstrap-vps.sh`
- [ ] Clone infra → `/srv/infra`, `docker compose up -d`
- [ ] Clone landing → `/srv/apps/landing`, `pnpm build`, `docker compose up -d`
- [ ] https://kostecki.dev works with SSL

---

## Purpose of this repo

- Traefik (reverse proxy, SSL)
- Landing deploy script
- Documentation

**Does not include:** Vue code, Laravel, databases. Landing lives in **kostecki-dev-landing**.

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
│   └── deploy-landing.sh       # uses pnpm
└── docs/
    ├── SETUP.md
    ├── LANDING.md
    ├── ARCHITECTURE.md
    ├── ADDING-AN-APP.md
    └── wallet-master.md
```

---

## `.env` (infra only)

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
git clone git@github.com:USER/kostecki-dev-infra.git /srv/infra
cd /srv/infra
./scripts/bootstrap-vps.sh
cp .env.example .env
docker compose up -d

# Verify
docker compose ps
docker compose logs traefik
```

DNS must point to the VPS **before** Let's Encrypt can issue a certificate.

---

## VPS — landing deploy

Prerequisites: [LANDING.md](./LANDING.md) (Node, pnpm, Docker files in landing repo).

```bash
# One-time on VPS: Node + pnpm
curl -fsSL https://get.docker.com | sh   # if not done by bootstrap
# Install Node (e.g. via nvm) — see LANDING.md

corepack enable
corepack prepare pnpm@latest --activate

# Deploy landing
git clone git@github.com:USER/kostecki-dev-landing.git /srv/apps/landing
cd /srv/apps/landing
pnpm install --frozen-lockfile
pnpm build
docker compose up -d
```

Updates from `/srv/infra`:

```bash
./scripts/deploy-landing.sh
```

---

## Troubleshooting

**403 / site unreachable, but `docker exec landing wget http://127.0.0.1/` works** — Traefik cannot talk to Docker API. Check logs:

```bash
docker logs traefik 2>&1 | grep "client version"
```

If you see `client version 1.24 is too old`, ensure `docker-compose.yml` has `DOCKER_API_VERSION: "1.44"` under `traefik`, then:

```bash
cd /srv/infra
git pull
docker compose up -d --force-recreate traefik
```

**SSL not issued** — DNS → VPS, port 80 open, logs: `docker compose logs traefik`

**Traefik does not see landing** — container on `proxy` network, labels `traefik.enable=true` and `traefik.docker.network=proxy`

**404** — missing `dist/index.html` or missing `try_files` in nginx

**Redirect loop** — landing nginx must not force HTTPS (Traefik handles TLS)

**Build fails on VPS** — check Node version (`^20.19.0 || >=22.12.0` in landing `package.json`), pnpm installed

---

## Next application?

See [ADDING-AN-APP.md](./ADDING-AN-APP.md) — **no changes to this repo**, only a new repo + Traefik labels + DNS.
