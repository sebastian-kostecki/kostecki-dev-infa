# kostecki-dev-infra

Traefik reverse proxy and deploy scripts for **kostecki.dev**.

This repo contains **infrastructure only** — no application code. Currently: landing page support.

## Repositories

| Repo | Status | Path on VPS |
|------|--------|-------------|
| **kostecki-dev-infra** (this) | on GitHub | `/srv/infra` |
| **kostecki-dev-landing** | on GitHub — add Docker before VPS deploy | `/srv/apps/landing` |
| wallet-master | later | see [docs/wallet-master.md](docs/wallet-master.md) |

## Documentation

| File | When to read |
|------|--------------|
| [docs/SETUP.md](docs/SETUP.md) | **Start here** — Traefik + VPS deploy checklist |
| [docs/LANDING.md](docs/LANDING.md) | **Landing repo** — Node, pnpm, Docker, local dev |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Overview (current + planned) |
| [docs/ADDING-AN-APP.md](docs/ADDING-AN-APP.md) | How to attach another app to Traefik |
| [docs/wallet-master.md](docs/wallet-master.md) | Laravel + Inertia + Reverb (when ready) |

## Quick start (VPS)

```bash
./scripts/bootstrap-vps.sh
cp .env.example .env   # set ACME_EMAIL
docker network create proxy
docker compose up -d
```

Deploy landing (after [Docker setup in landing repo](docs/LANDING.md)):

```bash
./scripts/deploy-landing.sh
```

Uses **pnpm** — install on VPS before first landing deploy (`corepack enable && corepack prepare pnpm@latest --activate`).
