# kostecki-dev-infra

Traefik reverse proxy and deploy scripts for **kostecki.dev**.

This repo contains **infrastructure only** — no application code. Currently: landing page support.

## Repositories

| Repo | Status | Path on VPS |
|------|--------|-------------|
| **kostecki-dev-infra** (this) | active | `/srv/infra` |
| **kostecki-dev-landing** | active | `/srv/apps/landing` |
| wallet-master | later | see [docs/wallet-master.md](docs/wallet-master.md) |

## Documentation

| File | When to read |
|------|--------------|
| [docs/SETUP.md](docs/SETUP.md) | **Start here** — Traefik + landing deploy |
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

Deploy landing: `./scripts/deploy-landing.sh`
