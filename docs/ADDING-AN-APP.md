# Adding another application

Traefik discovers applications automatically via **Docker labels**. The **kostecki-dev-infra repo does not need changes** — you only add a new application repo.

---

## 3 steps

### 1. DNS

A record (or CNAME) → VPS IP, e.g.:

```text
app.kostecki.dev  →  VPS_IP
```

### 2. Directory on VPS

```bash
sudo mkdir -p /srv/apps/app-name
sudo chown $USER:$USER /srv/apps/app-name
git clone git@github.com:USER/app-name.git /srv/apps/app-name
```

### 3. docker-compose with Traefik labels

Each application must:

- join the `proxy` network,
- have `traefik.enable=true` and a `Host(...)` rule.

**Template:**

```yaml
services:
  myapp:
    image: nginx:alpine   # or your own build
    container_name: myapp
    restart: unless-stopped
    networks:
      - proxy
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.myapp.rule=Host(`app.kostecki.dev`)
      - traefik.http.routers.myapp.entrypoints=websecure
      - traefik.http.routers.myapp.tls.certresolver=letsencrypt
      - traefik.http.services.myapp.loadbalancer.server.port=80

networks:
  proxy:
    external: true
```

Run:

```bash
cd /srv/apps/app-name
docker compose up -d
```

Traefik will issue SSL and start routing traffic automatically.

---

## Multiple hosts in one app

```yaml
- traefik.http.routers.myapp.rule=Host(`kostecki.dev`) || Host(`www.kostecki.dev`)
```

(see the landing repo for an example)

---

## Multiple ports / services in one stack

Each **public** service gets its own Traefik router, e.g.:

- `app.kostecki.dev` → nginx (HTTP)
- `ws.kostecki.dev` → reverb (WebSocket, port 8080)

This is still **one repo, one docker-compose** — not separate applications. Example: [wallet-master.md](./wallet-master.md).

---

## Checklist

- [ ] DNS points to VPS
- [ ] Container on `proxy` network
- [ ] `traefik.enable=true`
- [ ] `traefik.docker.network=proxy`
- [ ] Correct `Host(...)` in rule
- [ ] `loadbalancer.server.port` = container's internal port
- [ ] `docker compose up -d`
- [ ] Test HTTPS in browser

---

## Troubleshooting

**502 / no routing** — check `docker network inspect proxy`, confirm container is attached

**SSL certificate** — DNS must be ready before first HTTPS request

**WebSocket** — Traefik handles upgrade automatically; ensure label port matches process port (e.g. Reverb: 8080)
