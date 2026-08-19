# kostecki-dev-infra

Traefik reverse proxy and deploy scripts for **kostecki.dev**.

This repo contains **infrastructure only** — no application code. Apps (landing, wallet-master, vaultwarden) live in separate repos and attach via Traefik labels. **Exception:** Obsidian LiveSync CouchDB is a stack template here (`stacks/obsidian-livesync/`), copied onto the VPS by a deploy script — not a separate GitHub repo.

## Repositories

| Repo | Status | Path on VPS |
|------|--------|-------------|
| **kostecki-dev-infra** (this) | on GitHub | `/srv/infra` |
| **kostecki-dev-landing** | on GitHub | `/srv/apps/landing` |
| wallet-master | on GitHub | `/srv/apps/wallet-master` |
| **kostecki-dev-vaultwarden** | on GitHub | `/srv/apps/vaultwarden` |
| Obsidian LiveSync (CouchDB) | template in this repo | `/srv/apps/obsidian-livesync` |

## Documentation

| File | When to read |
|------|--------------|
| [docs/SETUP.md](docs/SETUP.md) | **Start here** — Traefik + VPS deploy checklist |
| [docs/LANDING.md](docs/LANDING.md) | **Landing repo** — Node, pnpm, Docker, local dev |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Overview (current + planned) |
| [docs/ADDING-AN-APP.md](docs/ADDING-AN-APP.md) | How to attach another app to Traefik |
| [docs/wallet-master.md](docs/wallet-master.md) | Laravel + Inertia + Reverb |
| [docs/vaultwarden.md](docs/vaultwarden.md) | Vaultwarden at vault.kostecki.dev |
| [docs/obsidian-livesync.md](docs/obsidian-livesync.md) | CouchDB LiveSync at obsidian.kostecki.dev |

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
