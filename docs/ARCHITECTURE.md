# kostecki.dev architecture

## Current state

```text
Internet :443
      │
      ▼
┌─────────────┐
│ Traefik     │  kostecki-dev-infra, network: proxy
└──────┬──────┘
       │
       ▼
 kostecki.dev / www.kostecki.dev
 landing (nginx + dist/)   ← kostecki-dev-landing repo
```

| Layer | Repo | Domain |
|-------|------|--------|
| Proxy | kostecki-dev-infra | — |
| Landing | kostecki-dev-landing | kostecki.dev |

Public exposure: **Traefik only** (ports 80/443).

---

## Planned state (later)

```text
Traefik
├── kostecki.dev           → landing
├── app.kostecki.dev       → wallet-master (Laravel + Inertia)
└── ws.kostecki.dev        → Reverb (WebSocket, same stack as Laravel)
```

Details: [wallet-master.md](./wallet-master.md)

---

## Repositories

```text
kostecki-dev-infra/     ← Traefik, scripts (this repo)
kostecki-dev-landing/   ← Vue landing (now)
wallet-master/          ← Laravel (later)
```

Separate repo per application — **no** monorepo or submodules.

On VPS:

```text
/srv/
├── infra/              ← kostecki-dev-infra
└── apps/
    └── landing/        ← kostecki-dev-landing
    # wallet-master/    ← add later
```

---

## Landing stack

| Layer | Choice |
|-------|--------|
| Package manager | pnpm |
| Runtime | Node.js `^20.19.0 \|\| >=22.12.0` |
| Language | TypeScript |
| Framework | Vue 3 + Vite + vue-router |
| Production | `pnpm build` → `dist/` → nginx container |

Dev: `pnpm dev` (:5173), no Traefik required. Details: [LANDING.md](./LANDING.md).

---

## Why Traefik

- Routing via **labels** in each app's docker-compose,
- New app = labels + DNS — **no Traefik config edits**,
- Automatic Let's Encrypt.

Network (one-time): `docker network create proxy`

---

## Adding another application

Generic guide: [ADDING-AN-APP.md](./ADDING-AN-APP.md)

Laravel-specific: [wallet-master.md](./wallet-master.md)

---

## Security (minimum)

- Firewall: 22, 80, 443
- HTTPS via Traefik
- `.env` on server only
- Traefik dashboard not public without auth
