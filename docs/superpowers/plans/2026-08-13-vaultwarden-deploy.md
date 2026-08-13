# Vaultwarden Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Vaultwarden behind Traefik at `https://vault.kostecki.dev` with signups disabled and first-user creation via admin invite.

**Architecture:** Separate app repo `kostecki-dev-vaultwarden` holds pinned `vaultwarden/server` compose + Traefik labels on the external `proxy` network. Infra repo only adds docs, bootstrap path, and a deploy wrapper. No Traefik compose changes.

**Tech Stack:** Vaultwarden `1.37.1`, Docker Compose, Traefik v3.6 (existing), Cloudflare Proxied, SQLite in Docker volume

**Spec:** [2026-08-13-vaultwarden-deploy-design.md](../specs/2026-08-13-vaultwarden-deploy-design.md)

## Global Constraints

- Domain: `vault.kostecki.dev` (HTTPS only via Traefik)
- Image: pin `vaultwarden/server:1.37.1` (not `latest`)
- `SIGNUPS_ALLOWED=false`, `INVITATIONS_ALLOWED=true`, `ADMIN_TOKEN` required
- No host port publish; join external network `proxy`
- App code/config lives in sibling repo; infra does not vendor the image compose as the source of truth
- Docs and comments in English; user-facing chat may be Polish

---

## File map

| Repo | File | Responsibility |
|------|------|----------------|
| kostecki-dev-vaultwarden | `docker-compose.yml` | Vaultwarden service, volume, Traefik labels |
| kostecki-dev-vaultwarden | `.env.example` | Documented env (no secrets) |
| kostecki-dev-vaultwarden | `.gitignore` | Ignore `.env` |
| kostecki-dev-vaultwarden | `README.md` | Deploy, invite bootstrap, updates |
| kostecki-dev-infra | `docs/vaultwarden.md` | Full ops guide for this stack |
| kostecki-dev-infra | `docs/ARCHITECTURE.md` | Add vault to current diagram/tables |
| kostecki-dev-infra | `docs/ADDING-AN-APP.md` | Short pointer to third-party image example |
| kostecki-dev-infra | `docs/SETUP.md` | Vaultwarden checklist + link |
| kostecki-dev-infra | `README.md` | Repo table entry |
| kostecki-dev-infra | `scripts/bootstrap-vps.sh` | Create `/srv/apps/vaultwarden` |
| kostecki-dev-infra | `scripts/deploy-vaultwarden.sh` | Pull + compose up wrapper |
| kostecki-dev-infra | `.env.example` | `VPS_VAULTWARDEN_DIR` |

---

### Task 1: Create `kostecki-dev-vaultwarden` compose stack

**Files:**
- Create: `/home/sebastian/my-projects/kostecki-dev-vaultwarden/docker-compose.yml`
- Create: `/home/sebastian/my-projects/kostecki-dev-vaultwarden/.env.example`
- Create: `/home/sebastian/my-projects/kostecki-dev-vaultwarden/.gitignore`

**Interfaces:**
- Consumes: external Docker network named `proxy` (from infra)
- Produces: service `vaultwarden` on Traefik router name `vaultwarden`, host `vault.kostecki.dev`, LB port `80`

- [ ] **Step 1: Create the app directory and git repo**

```bash
mkdir -p /home/sebastian/my-projects/kostecki-dev-vaultwarden
cd /home/sebastian/my-projects/kostecki-dev-vaultwarden
git init
```

Expected: empty git repo in that path.

- [ ] **Step 2: Write `.gitignore`**

```gitignore
.env
```

- [ ] **Step 3: Write `.env.example`**

```env
# Public URL (used for links, clients, WebSocket)
DOMAIN=https://vault.kostecki.dev

# Keep public registration off — create users via /admin invite
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true

# Required for https://vault.kostecki.dev/admin
# Prefer an Argon2 hash from: docker run --rm -it vaultwarden/server:1.37.1 /vaultwarden hash
# Plain tokens also work but hashed is recommended.
ADMIN_TOKEN=
```

- [ ] **Step 4: Write `docker-compose.yml`**

```yaml
services:
  vaultwarden:
    image: vaultwarden/server:1.37.1
    container_name: vaultwarden
    restart: unless-stopped
    env_file: .env
    volumes:
      - vw-data:/data
    networks:
      - proxy
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.vaultwarden.rule=Host(`vault.kostecki.dev`)
      - traefik.http.routers.vaultwarden.entrypoints=websecure
      - traefik.http.routers.vaultwarden.tls.certresolver=letsencrypt
      - traefik.http.services.vaultwarden.loadbalancer.server.port=80

networks:
  proxy:
    external: true

volumes:
  vw-data:
```

- [ ] **Step 5: Validate compose locally**

```bash
cd /home/sebastian/my-projects/kostecki-dev-vaultwarden
cp .env.example .env
# Set a throwaway ADMIN_TOKEN for config validation only
printf 'test-admin-token\n' | sed 's/^/ADMIN_TOKEN=/' >> .env
docker compose config
```

Expected: rendered YAML with image `vaultwarden/server:1.37.1`, external network `proxy`, no `ports:` section.

- [ ] **Step 6: Commit app repo files (without committing real `.env`)**

```bash
cd /home/sebastian/my-projects/kostecki-dev-vaultwarden
rm -f .env
git add .gitignore .env.example docker-compose.yml
git commit -m "$(cat <<'EOF'
Add Vaultwarden compose stack for vault.kostecki.dev.

EOF
)"
```

---

### Task 2: App repo README (invite bootstrap + deploy)

**Files:**
- Create: `/home/sebastian/my-projects/kostecki-dev-vaultwarden/README.md`

**Interfaces:**
- Consumes: compose + `.env.example` from Task 1
- Produces: operator instructions for VPS path `/srv/apps/vaultwarden`

- [ ] **Step 1: Write `README.md`**

Create the file with this exact content (no outer fence in the real file):

~~~~
# kostecki-dev-vaultwarden

Production Vaultwarden stack for **https://vault.kostecki.dev** behind Traefik on the `kostecki.dev` VPS.

Upstream: https://github.com/dani-garcia/vaultwarden

Infra docs: kostecki-dev-infra → docs/vaultwarden.md

## Requirements

- Traefik already running from kostecki-dev-infra (Docker network `proxy` exists)
- DNS: vault.kostecki.dev → VPS IP (Cloudflare Proxied, SSL Full strict)

## First deploy (VPS)

    sudo mkdir -p /srv/apps/vaultwarden
    sudo chown "$USER:$USER" /srv/apps/vaultwarden
    git clone git@github.com:YOUR_USER/kostecki-dev-vaultwarden.git /srv/apps/vaultwarden
    cd /srv/apps/vaultwarden
    cp .env.example .env

Edit `.env`:

1. Keep SIGNUPS_ALLOWED=false and INVITATIONS_ALLOWED=true
2. Generate admin token hash:

    docker run --rm -it vaultwarden/server:1.37.1 /vaultwarden hash

Paste the hash into ADMIN_TOKEN=...

    docker compose up -d

## First user (no public signup)

1. Open https://vault.kostecki.dev/admin and log in with the admin token (the plaintext you typed into the hash tool).
2. Invite a user and copy the invitation link (SMTP optional).
3. Open the link and create the account.
4. Point Bitwarden-compatible clients at https://vault.kostecki.dev.

Emergency only: temporarily set SIGNUPS_ALLOWED=true, register once, set back to false, then docker compose up -d again.

## Updates

    cd /srv/apps/vaultwarden
    git pull
    docker compose pull
    docker compose up -d

Or from infra: ./scripts/deploy-vaultwarden.sh

Data persists in the vw-data Docker volume.
~~~~

- [ ] **Step 2: Commit**

```bash
cd /home/sebastian/my-projects/kostecki-dev-vaultwarden
git add README.md
git commit -m "$(cat <<'EOF'
Document Vaultwarden deploy and admin invite bootstrap.

EOF
)"
```

---

### Task 3: Infra docs — `docs/vaultwarden.md`

**Files:**
- Create: `/home/sebastian/my-projects/kostecki-dev-infra/docs/vaultwarden.md`

**Interfaces:**
- Consumes: decisions from the design spec
- Produces: canonical ops guide linked from ARCHITECTURE / SETUP / README

- [ ] **Step 1: Write `docs/vaultwarden.md`**

Create `/home/sebastian/my-projects/kostecki-dev-infra/docs/vaultwarden.md` with this exact content:

~~~~
# Vaultwarden deployment

Deployment guide for Vaultwarden on **vault.kostecki.dev**.

Related: [ADDING-AN-APP.md](./ADDING-AN-APP.md) · [ARCHITECTURE.md](./ARCHITECTURE.md)

App repo: **kostecki-dev-vaultwarden** (compose only — upstream image).

---

## Architecture

    Cloudflare (Proxied) → Traefik → vault.kostecki.dev → vaultwarden :80
                                                          volume vw-data → /data (SQLite)

- Image: `vaultwarden/server:1.37.1` (pin; bump deliberately)
- No host ports; container on external `proxy` network
- Traefik labels live in the **app** repo — do not edit infra `docker-compose.yml`

---

## DNS / Cloudflare

| Record | Type | Value | Proxy |
|--------|------|-------|-------|
| `vault` | A | VPS IP | Proxied |

- SSL/TLS mode: **Full (strict)**
- Same pattern as landing / budget

---

## VPS directory

    sudo mkdir -p /srv/apps/vaultwarden
    sudo chown "$USER:$USER" /srv/apps/vaultwarden
    git clone git@github.com:YOUR_USER/kostecki-dev-vaultwarden.git /srv/apps/vaultwarden

`bootstrap-vps.sh` creates `/srv/apps/vaultwarden` automatically.

---

## Environment

On the server only (`/srv/apps/vaultwarden/.env`):

    DOMAIN=https://vault.kostecki.dev
    SIGNUPS_ALLOWED=false
    INVITATIONS_ALLOWED=true
    ADMIN_TOKEN=<argon2-hash-or-secret>

Generate a hashed admin token:

    docker run --rm -it vaultwarden/server:1.37.1 /vaultwarden hash

---

## Traefik labels

Defined on the `vaultwarden` service in the app repo:

- Host rule: `vault.kostecki.dev`
- entrypoint `websecure`, certresolver `letsencrypt`
- loadbalancer port `80`

---

## First user

Public signup stays **off**.

1. `docker compose up -d` with `ADMIN_TOKEN` set
2. Open `https://vault.kostecki.dev/admin`
3. Invite user → copy link → register
4. Clients: server URL `https://vault.kostecki.dev`

Emergency fallback: briefly enable `SIGNUPS_ALLOWED=true`, register once, disable again, recreate container.

---

## Deploy / update

From infra:

    cd /srv/infra
    ./scripts/deploy-vaultwarden.sh

From app dir:

    cd /srv/apps/vaultwarden
    git pull
    docker compose pull
    docker compose up -d

---

## Verification

- `curl -I https://vault.kostecki.dev` — UI reachable over HTTPS
- Admin invite flow works
- `https://kostecki.dev` and `https://budget.kostecki.dev` unchanged

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| 502 | Not on `proxy` network | `docker network inspect proxy` |
| SSL errors | DNS / Cloudflare SSL mode | Proxied + Full strict; wait for cert |
| Cannot register | Signups disabled (expected) | Use `/admin` invite |
| Admin locked | Bad `ADMIN_TOKEN` | Fix `.env`, `docker compose up -d` |
~~~~

- [ ] **Step 2: Commit**

```bash
cd /home/sebastian/my-projects/kostecki-dev-infra
git add docs/vaultwarden.md
git commit -m "$(cat <<'EOF'
Add Vaultwarden ops guide for vault.kostecki.dev.

EOF
)"
```

---

### Task 4: Infra docs cross-links (ARCHITECTURE, ADDING, SETUP, README)

**Files:**
- Modify: `/home/sebastian/my-projects/kostecki-dev-infra/docs/ARCHITECTURE.md`
- Modify: `/home/sebastian/my-projects/kostecki-dev-infra/docs/ADDING-AN-APP.md`
- Modify: `/home/sebastian/my-projects/kostecki-dev-infra/docs/SETUP.md`
- Modify: `/home/sebastian/my-projects/kostecki-dev-infra/README.md`

**Interfaces:**
- Consumes: `docs/vaultwarden.md` from Task 3
- Produces: discoverable links from existing entry points

- [ ] **Step 1: Update `docs/ARCHITECTURE.md` current-state diagram**

Replace the ASCII tree under `## Current state` so it includes vault:

```text
Internet :443
      │
      ▼
┌─────────────┐
│ Traefik     │  kostecki-dev-infra, network: proxy
└──────┬──────┘
       │
       ├── kostecki.dev / www.kostecki.dev
       │   landing (nginx + dist/)   ← kostecki-dev-landing repo
       │
       ├── budget.kostecki.dev
       │   wallet-master (Laravel + Inertia)   ← wallet-master repo
       │
       ├── budget.kostecki.dev/app, /apps
       │   Reverb (WebSocket, same app container)
       │
       └── vault.kostecki.dev
           vaultwarden   ← kostecki-dev-vaultwarden repo
```

Add a table row:

| vaultwarden | kostecki-dev-vaultwarden | vault.kostecki.dev |

Under **Repositories**, add `kostecki-dev-vaultwarden/` and on VPS tree add `vaultwarden/`.

Under **Adding another application**, add: `Third-party image example: [vaultwarden.md](./vaultwarden.md)`.

- [ ] **Step 2: Update `docs/ADDING-AN-APP.md`**

After the intro paragraph, add:

```markdown
Worked example with an upstream image (no app build): [vaultwarden.md](./vaultwarden.md) (`vault.kostecki.dev`).
```

- [ ] **Step 3: Update `docs/SETUP.md`**

In the checklist, add:

```markdown
### vaultwarden

- [ ] DNS: `vault.kostecki.dev` → VPS IP (Cloudflare Proxied)
- [ ] Clone kostecki-dev-vaultwarden → `/srv/apps/vaultwarden`
- [ ] Configure `.env` (see [vaultwarden.md](./vaultwarden.md))
- [ ] `docker compose up -d`
- [ ] First user via `/admin` invite
- [ ] https://vault.kostecki.dev works with SSL
```

In the documentation links / related list at the top, mention vaultwarden.md.

- [ ] **Step 4: Update root `README.md` repo table**

Add:

| **kostecki-dev-vaultwarden** | on GitHub | `/srv/apps/vaultwarden` |

Add docs row for [docs/vaultwarden.md](docs/vaultwarden.md).

Fix outdated “Currently: landing page support” wording to mention Traefik + deploy scripts for multiple apps.

- [ ] **Step 5: Commit**

```bash
cd /home/sebastian/my-projects/kostecki-dev-infra
git add docs/ARCHITECTURE.md docs/ADDING-AN-APP.md docs/SETUP.md README.md
git commit -m "$(cat <<'EOF'
Link Vaultwarden across architecture and setup docs.

EOF
)"
```

---

### Task 5: Infra scripts and `.env.example`

**Files:**
- Modify: `/home/sebastian/my-projects/kostecki-dev-infra/scripts/bootstrap-vps.sh`
- Create: `/home/sebastian/my-projects/kostecki-dev-infra/scripts/deploy-vaultwarden.sh`
- Modify: `/home/sebastian/my-projects/kostecki-dev-infra/.env.example`

**Interfaces:**
- Consumes: `VPS_VAULTWARDEN_DIR` (default `/srv/apps/vaultwarden`)
- Produces: deploy script callable from `/srv/infra`

- [ ] **Step 1: Extend `bootstrap-vps.sh` directory creation**

Change the `mkdir` line to include vaultwarden:

```bash
sudo mkdir -p /srv/infra /srv/apps/landing /srv/apps/wallet-master /srv/apps/vaultwarden /storage/wallet-master-backups
```

Add to the “Next steps” echo list:

```bash
echo "  6. Clone kostecki-dev-vaultwarden to /srv/apps/vaultwarden — see docs/vaultwarden.md"
```

- [ ] **Step 2: Create `scripts/deploy-vaultwarden.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

VAULT_DIR="${VPS_VAULTWARDEN_DIR:-/srv/apps/vaultwarden}"

cd "$VAULT_DIR"

echo "==> Pulling latest..."
git pull

echo "==> Updating Vaultwarden image..."
docker compose pull
docker compose up -d

echo "==> Done. Check https://vault.kostecki.dev"
```

```bash
chmod +x /home/sebastian/my-projects/kostecki-dev-infra/scripts/deploy-vaultwarden.sh
```

- [ ] **Step 3: Update `.env.example`**

Add after wallet dir:

```env
# Vaultwarden deploy path on VPS
VPS_VAULTWARDEN_DIR=/srv/apps/vaultwarden
```

- [ ] **Step 4: Smoke-check scripts**

```bash
bash -n /home/sebastian/my-projects/kostecki-dev-infra/scripts/deploy-vaultwarden.sh
bash -n /home/sebastian/my-projects/kostecki-dev-infra/scripts/bootstrap-vps.sh
grep -n vaultwarden /home/sebastian/my-projects/kostecki-dev-infra/scripts/bootstrap-vps.sh
grep -n VPS_VAULTWARDEN_DIR /home/sebastian/my-projects/kostecki-dev-infra/.env.example
```

Expected: no syntax errors; vaultwarden path present in both files.

- [ ] **Step 5: Commit**

```bash
cd /home/sebastian/my-projects/kostecki-dev-infra
git add scripts/bootstrap-vps.sh scripts/deploy-vaultwarden.sh .env.example
git commit -m "$(cat <<'EOF'
Add Vaultwarden bootstrap path and deploy script.

EOF
)"
```

---

### Task 6: Publish app repo + VPS checklist (manual)

**Files:**
- None in git beyond ensuring remotes exist

**Interfaces:**
- Consumes: Tasks 1–5 complete
- Produces: GitHub remote for app repo; operator-ready VPS steps

- [ ] **Step 1: Create GitHub repo and push `kostecki-dev-vaultwarden`**

```bash
cd /home/sebastian/my-projects/kostecki-dev-vaultwarden
# Create empty private/public repo on GitHub named kostecki-dev-vaultwarden, then:
git branch -M master
git remote add origin git@github.com:YOUR_USER/kostecki-dev-vaultwarden.git
git push -u origin master
```

Replace `YOUR_USER` with the actual GitHub user/org used by landing/wallet.

- [ ] **Step 2: Push infra commits**

```bash
cd /home/sebastian/my-projects/kostecki-dev-infra
git status
git push
```

Only if the user explicitly wants remote updated; otherwise leave local commits for them.

- [ ] **Step 3: Operator VPS checklist (do not automate secrets)**

On VPS, after DNS:

1. `git pull` in `/srv/infra` (or clone updates)
2. Clone app to `/srv/apps/vaultwarden`
3. `cp .env.example .env` and set hashed `ADMIN_TOKEN`
4. `docker compose up -d`
5. Complete `/admin` invite for first user
6. Verify HTTPS + clients

Expected: `https://vault.kostecki.dev` serves Vaultwarden UI; registration without invite fails.

---

## Plan self-review

| Spec item | Task |
|-----------|------|
| Separate app repo + compose + labels | Task 1 |
| `.env` signups/invites/admin/domain | Task 1–2 |
| First-user invite docs | Task 2–3 |
| Infra docs + ARCHITECTURE | Task 3–4 |
| bootstrap + deploy script + env example | Task 5 |
| DNS/Cloudflare + VPS procedure | Task 2–3, 6 |
| No Traefik compose changes | Confirmed (no task edits `docker-compose.yml`) |
| Pin image version | Task 1 (`1.37.1`) |
| Out of scope (SMTP, backups, Postgres) | Not scheduled |

No TBD/placeholder steps remain except `YOUR_USER` which the implementer replaces with the real GitHub owner at push time.
