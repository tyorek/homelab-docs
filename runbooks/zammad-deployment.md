# Zammad Deployment — Home Ticket System

Replaces the Vikunja plan (`vikunja-deployment.md`) — Vikunja is a task manager, not a real
ticket system. Zammad gives actual ticket semantics: New Ticket button → template → editable
ticket → Type/Category/State → Resolution field, which is what was actually asked for.

Deployed as a dedicated Proxmox VM running the official `zammad-docker-compose` stack, fronted
by the existing `caddy` VM (`10.20.0.7`) for HTTPS on a `.local` domain — same pattern as the
other Caddy sites.

## 1. Proxmox VM

| Setting | Value |
|---|---|
| Name | `zammad` |
| OS | Ubuntu 24.04 LTS |
| vCPU | 4 |
| RAM | 6 GB (official min is 4GB; this instance is single-user so the extra 2GB is margin, not need — host has ~32GB free so no strain) |
| Disk | 40 GB, thin-provisioned (Postgres + Elasticsearch index + Rails/nginx/ES images + attachments add up faster than Vikunja's SQLite setup did) |
| Network | `vmbr0`, DMZ subnet `10.20.0.0/25` — pick a real free IP (placeholder below: `10.20.0.8`) |

## 2. Host prerequisites

Elasticsearch refuses to start without this kernel setting — make it persistent:

```bash
sudo tee /etc/sysctl.d/99-elasticsearch.conf <<'EOF'
vm.max_map_count=262144
EOF
sudo sysctl --system
```

Install Docker the same way as the Vikunja VM:

```bash
sudo apt update && sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

## 3. Get the official compose stack

```bash
cd ~
git clone https://github.com/zammad/zammad-docker-compose.git zammad
cd zammad
cp .env.dist .env
```

Edit `.env` — key values to change:

```ini
ZAMMAD_FQDN=zammad.home.arpa
ZAMMAD_HTTP_TYPE=https
NGINX_SERVER_SCHEME=https
NGINX_SERVER_NAME=zammad.home.arpa

NGINX_EXPOSE_PORT=8080

# Elasticsearch heap — default is already conservative for this use case, leave as-is:
ELASTICSEARCH_JAVA_OPTS=-Xms1g -Xmx1g

POSTGRES_PASS=<pick a real password>
ELASTICSEARCH_PASS=<pick a real password>
```

**Do NOT set `RAILS_TRUSTED_PROXIES`** — leave it unset. Rails' default trusted-proxy list
already covers both hops in this chain (Caddy at `10.20.0.7` falls under the default
`10.0.0.0/8` trust range, and the internal Docker bridge between `zammad-nginx` and
`zammad-railsserver` falls under `172.16.0.0/12`). Setting it to a single IP *replaces* that
default list instead of extending it, which breaks trust for the internal hop.

**`NGINX_SERVER_SCHEME=https` is the actual fix for CSRF failures behind Caddy.** Zammad's
bundled `zammad-nginx` container dynamically renders its vhost config from a template at every
container start (via `/opt/zammad/bin/docker-entrypoint`), and by default hardcodes
`X-Forwarded-Proto` to its own listener scheme (`$scheme`, always `http` since it only listens
on plain 8080) — silently overwriting the correct `https` value Caddy already sent. This causes
Rails to think every request arrived over plain HTTP, which mismatches the `https` FQDN it's
configured for and fails CSRF/origin checks with `Exceptions::InvalidCSRFToken`, on every
request, not just the first. `NGINX_SERVER_SCHEME=https` tells the entrypoint's template to
report `https` correctly instead. **Do not try to fix this by hand-editing/bind-mounting a
replacement `/etc/nginx/sites-available/default`** — the entrypoint rewrites that path (and
`sites-enabled/default`) on every container start, and a static bind-mount fights that process
and crash-loops the container (`Read-only file system` on `sites-enabled/default`).

## 4. Apply the built-in resource-limits overlay

The repo ships a `scenarios/apply-resource-limits.yml` overlay that caps every service (Postgres,
Redis, memcached, nginx, rails, scheduler, websocket, backup, init at 0.5-1GB each; ES at 1GB) so
nothing balloons unbounded even though the host has RAM to spare:

```bash
docker compose -f docker-compose.yml -f scenarios/apply-resource-limits.yml up -d
```

Watch it come up (Elasticsearch is the slowest to become healthy):

```bash
docker compose ps
docker compose logs -f zammad-init
```

## 5. Caddyfile addition (on the existing `caddy` VM, `10.20.0.7`)

```
zammad.home.arpa {
    reverse_proxy 10.20.0.8:8080
}
```

No TLS transport block — Zammad's nginx container serves plain HTTP on 8080, Caddy handles TLS
for the LAN. Reload:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## 6. DNS

Add `zammad.home.arpa` → `10.20.0.8` (or your real chosen IP) to the local DNS zone,
same as the other `.local` entries.

## 7. First run — setup wizard

Visit `https://zammad.home.arpa/`, create the admin account, skip the channel setup
(email/social — not needed for personal use), and land on the dashboard.

## 8. Configure the ticket workflow you asked for

This is the part that makes Zammad fit what you described, not just "a ticket system in general."

**Add custom ticket fields** — Admin → *Objects* → Ticket → add:

- **Category** (Select field, single) — options: `Networking`, `Hardware`, `Software`,
  `Plumbing`, `Electrical`, `HVAC`, `General Maintenance`, `Other`
- **Type** (Select field, single) — options: `Incident`, `Repair`, `Upgrade`,
  `Preventive Maintenance`, `Question`
- **Resolution** (Textarea) — free text, filled in when you close a ticket out

After adding each, click *Update* — Zammad migrates the DB and the fields appear on the ticket
form immediately.

**Create a ticket template** — Admin → *Manage* → *Ticket Templates* → New Template:

- Pre-fill Group (default `Users` is fine for solo use)
- Pre-fill the initial article body with a scaffold, e.g.:
  ```
  ## What was done

  ## Symptoms / issue

  ## Resolution
  ```
- Save as something like "Home Ticket"

Now the **New Ticket** button (top of the ticket list) lets you pick that template, which opens
the form pre-filled with the scaffold — you fill in "what was done," set Category/Type, and the
ticket is created. States (`New` → `Open` → `Pending` → `Closed`) are built in and need no
config; update the ticket anytime by adding a new article (note), and fill in **Resolution**
before moving it to `Closed`.

## Notes / open items

- This VM is the repurposed Vikunja VM (hostname renamed `vik` → `zam`), reused rather than
  built fresh — IP `10.20.0.8` stayed the same, only the OS/RAM/disk sizing and running
  containers changed.
- `docker compose logs -f zammad-elasticsearch` is the first place to check if `zammad-init`
  hangs — it means ES isn't healthy yet, usually the `vm.max_map_count` step above.
- Back up `~/zammad/` volumes (Postgres + ES data live under Docker volumes, not bind mounts in
  the official compose — check `docker volume ls` for the `zammad_*` volumes) alongside whatever
  backup routine you already use for the other VMs.
