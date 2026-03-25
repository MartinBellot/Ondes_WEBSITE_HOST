# Ondes HOST — Infrastructure Dashboard

A modern, self-hosted alternative to cPanel/Plesk — manage Docker stacks, GitHub repos, NGINX, SSH and more from a single Flutter interface.

```
.
├── api/          # Django 5 backend (REST + WebSocket via Channels/Daphne)
├── app/          # Flutter frontend (macOS / web)
├── docker-compose.yml
├── .env.example
└── .gitignore
```

---

## Features

| Module | What it does |
|---|---|
| **Auth** | JWT login / register |
| **GitHub Integration** | OAuth App link, repo browser, branch selector, auto-detect `docker-compose.yml` |
| **Stacks** | Clone a GitHub repo, pick a compose file, set env vars and deploy — real-time streaming logs via WebSocket. nginx/certbot services in the repo's compose are automatically stripped and replaced by the platform's. |
| **Docker Manager** | List, start, stop, restart, remove containers; live status |
| **NGINX Manager** | Per-stack multi-domain vhost management — generate NGINX configs, reload without downtime, run Certbot on-demand, track cert expiry with auto-renewal every 12 h |
| **Domaine & SSL** | "Domaine & SSL" tab in Stack Detail — add/remove vhosts, smart DNS propagation check, Auto-SSL Pipeline wizard (DNS check → Certbot), cert expiry countdown |
| **DNS Propagation Checker** | Before activating SSL, the app automatically checks whether the domain's A record resolves to the server's public IP. Auto-polls every 15 s until propagated; shows server IP vs. resolved IP side by side. |
| **Live Infrastructure Canvas** | Interactive zoomable canvas (0.3×–2.5×) showing all running Docker containers as draggable node cards, grouped by Compose project. CPU and memory bars update live every 3 s via a dedicated `ws/metrics/` WebSocket. Animated pulsing status dot and per-container resource thresholds (green < 40 %, yellow < 80 %, red ≥ 80 %). Click any node to open a side-panel with full details. |
| **SSH Terminal** | Live WebSocket shell (Paramiko) |

---

## VPS Deployment — Single Line

> **Tested on:** Ubuntu 20.04 / 22.04 / 24.04 · Debian 11/12 · CentOS/RHEL/Rocky/AlmaLinux 8+ · Fedora 37+  
> **Requirements:** root access (or sudo), 1 GB RAM, 5 GB free disk, ports 80 & 443 available.

```bash
sudo bash deploy.sh
```

### What the script does, step by step

| Step | Action |
|---|---|
| 1 | **Privilege check** — aborts immediately if not run as root |
| 2 | **OS detection** — auto-selects `apt-get` / `dnf` for Ubuntu, Debian, CentOS, RHEL, Rocky, AlmaLinux, Fedora |
| 3 | **Resource sanity** — warns if < 1 GB RAM or < 5 GB free disk |
| 4 | **Port audit** — detects anything already bound to 80, 443, 3000, 8000, 5432, 6379 |
| 5 | **System NGINX removal** — detects binary + installed packages; stops, disables, and purges system NGINX (which would conflict with the Dockerised reverse-proxy on ports 80/443); also stops Apache / Lighttpd / Caddy if detected |
| 6 | **System dependencies** — installs `curl`, `git`, `openssl`, `ca-certificates`, `gnupg` |
| 7 | **Docker Engine** — skips if already installed; otherwise runs the official `get.docker.com` bootstrap, then `systemctl enable --now docker` |
| 8 | **Docker Compose v2** — installs the `docker-compose-plugin` via the distro package manager or downloads the standalone binary; validates with `docker compose version` |
| 9 | **Project directory** — uses the current folder if a `docker-compose.yml` is present; otherwise clones the repo into `/opt/ondes-host` (override with `ONDES_DIR`) |
| 10 | **`.env` security validation** (interactive) |
| | — creates `.env` from `.env.example` if missing |
| | — **SECRET_KEY**: auto-generates 100-char hex key if default/empty |
| | — **DEBUG**: prompts to set `False` if still `True` |
| | — **POSTGRES_PASSWORD**: auto-generates 48-char hex if default (`ondes_password`, `postgres`, etc.) and rebuilds `DATABASE_URL` |
| | — **CERTBOT_EMAIL**: prompts for a real address if placeholder `admin@example.com` detected |
| | — **ALLOWED_HOSTS**: prompts for your domain/IP when `*` is set in production mode |
| | — **CORS_ALLOWED_ORIGINS**: prompts to replace `localhost` with your domain |
| | — prints a sanitised summary (secrets truncated) before proceeding |
| 11 | **Docker socket** — sets `chmod 660 /var/run/docker.sock` so the API container can manage user stacks |
| 12 | **Pull base images** — `postgres`, `redis`, `nginx`, `certbot` pre-pulled for faster builds |
| 13 | **Build images** — `docker compose build --parallel` for `api` (Django/Daphne) and `app` (Flutter web) |
| 14 | **Launch** — `docker compose up -d --remove-orphans` |
| 15 | **Health polling** — waits up to 180 s for the API to respond; reports per-service status |
| 16 | **Migrations** — `python manage.py migrate --noinput` (idempotent) |
| 17 | **Superuser** — interactive prompt to create a Django admin account |
| 18 | **UFW firewall** (optional) — allows 22/80/443, explicitly denies 5432/6379/8000/3000 from outside |
| 19 | **Summary** — detects public IP via `icanhazip.com`, prints service URLs and handy commands |

### Environment variables (override before running)

```bash
export ONDES_REPO_URL="https://github.com/MartinBellot/ONDES_HOST.git"  # default clone target
export ONDES_DIR="/opt/ondes-host"                                    # installation directory
sudo -E bash deploy.sh
```

---

## Quick Start
```bash
cp .env.example .env
# Edit .env — change SECRET_KEY and POSTGRES_PASSWORD at minimum
```

### 2. Start with Docker Compose
```bash
docker-compose up --build
```

| Service | URL |
|---|---|
| Frontend | http://localhost:3000 |
| API | http://localhost:8000/api/ |
| Admin | http://localhost:8000/admin/ |

### 3. Create a superuser (first run)
```bash
docker-compose exec api python manage.py createsuperuser
```

---

## Local Development (without Docker)

### Backend
```bash
cd api
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python manage.py migrate
# SQLite + InMemoryChannelLayer are used automatically (no Postgres/Redis needed)
python manage.py runserver
# or with WebSocket support:
daphne -b 0.0.0.0 -p 8000 config.asgi:application
```

### Flutter (macOS)
```bash
cd app
flutter pub get
flutter run -d macos
```

### Flutter (web)
```bash
flutter run -d chrome \
  --dart-define=API_URL=http://localhost:8000/api \
  --dart-define=WS_URL=ws://localhost:8000
```

---

## GitHub Integration Setup

OAuth credentials are **not stored in `.env`** — they are configured directly from the app UI so you never need to restart the server.

1. Open the app → **GitHub** screen.
2. The wizard shows your **Authorization callback URL** — copy it.
3. Go to [github.com/settings/developers](https://github.com/settings/developers) → *New OAuth App*.
   - Homepage URL: `http://localhost:3000` (or your domain)
   - Authorization callback URL: paste the URL from step 2
4. Copy the **Client ID** and generate a **Client Secret**.
5. Paste both into the wizard → **Enregistrer et continuer**.
6. Click **Se connecter avec GitHub** — OAuth flow opens in the system browser.

Credentials are stored in the database via the `GitHubOAuthConfig` singleton model. To reconfigure, click *Reconfigurer OAuth App* on the GitHub screen.

---

## Stacks (auto-deploy pipeline)

1. **Connect GitHub** (see above).
2. Browse your repos → tap a repo.
3. Select a branch, pick a `docker-compose.yml`, fill in optional env vars, give the project a name.
4. Click **Déployer** — the server clones the repo, automatically strips any `nginx` / `certbot` services from the compose file (using the platform's own managed instances instead), runs `docker compose up --build -d` and streams logs in real time.
5. Manage the running stack from **Stack Detail**: start/stop/restart/redeploy, edit env vars, view logs.
6. Open the **Domaine & SSL** tab → add a domain, follow the DNS guide, and activate Let's Encrypt SSL with one click.

---

## API Reference

### Auth
| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/auth/register/` | Register user |
| `POST` | `/api/auth/login/` | Obtain JWT tokens |
| `POST` | `/api/auth/refresh/` | Refresh access token |

### Docker
| Method | Endpoint | Description |
|---|---|---|
| `GET`  | `/api/docker/status/` | Docker daemon availability |
| `GET`  | `/api/docker/containers/` | List containers |
| `POST` | `/api/docker/containers/create/` | Deploy container |
| `POST` | `/api/docker/containers/{id}/start/` | Start |
| `POST` | `/api/docker/containers/{id}/stop/` | Stop |
| `POST` | `/api/docker/containers/{id}/remove/` | Remove |

### GitHub
| Method | Endpoint | Description |
|---|---|---|
| `GET`  | `/api/github/config/` | Get OAuth App config |
| `POST` | `/api/github/config/` | Save OAuth App credentials |
| `DELETE` | `/api/github/config/` | Delete OAuth App config |
| `GET`  | `/api/github/oauth/start/` | Get OAuth authorize URL |
| `GET`  | `/api/github/oauth/callback/` | OAuth redirect handler |
| `GET`  | `/api/github/profile/` | Connected GitHub profile |
| `DELETE` | `/api/github/profile/` | Disconnect GitHub |
| `GET`  | `/api/github/repos/` | List repos (paginated) |
| `GET`  | `/api/github/repos/{owner}/{repo}/branches/` | List branches |
| `GET`  | `/api/github/repos/{owner}/{repo}/compose-files/` | Find compose files |

### Stacks
| Method | Endpoint | Description |
|---|---|---|
| `GET`  | `/api/stacks/` | List stacks |
| `POST` | `/api/stacks/` | Create stack |
| `GET`  | `/api/stacks/{id}/` | Stack detail |
| `PUT`  | `/api/stacks/{id}/` | Update stack |
| `DELETE` | `/api/stacks/{id}/` | Delete stack |
| `POST` | `/api/stacks/{id}/deploy/` | Trigger deploy |
| `POST` | `/api/stacks/{id}/action/` | start / stop / restart |
| `GET`  | `/api/stacks/{id}/logs/` | Static logs |
| `GET`  | `/api/stacks/{id}/env/` | Get env vars |
| `PUT`  | `/api/stacks/{id}/env/` | Update env vars |
| `GET`  | `/api/stacks/{id}/vhosts/` | List NGINX vhosts for this stack |

### NGINX
| Method | Endpoint | Description |
|---|---|---|
| `GET`    | `/api/nginx/vhosts/` | List all vhosts (filter: `?stack=<id>`) |
| `POST`   | `/api/nginx/vhosts/` | Create vhost — writes NGINX config + reload |
| `GET`    | `/api/nginx/vhosts/{id}/` | Vhost detail |
| `PATCH`  | `/api/nginx/vhosts/{id}/` | Update vhost (rewrites config) |
| `DELETE` | `/api/nginx/vhosts/{id}/` | Delete vhost + reload |
| `POST`   | `/api/nginx/vhosts/{id}/certbot/` | Run Certbot for this domain; body: `{"email": "…"}` |
| `GET`    | `/api/nginx/vhosts/{id}/cert-status/` | Refresh cert expiry from disk |
| `GET`    | `/api/nginx/vhosts/{id}/check-dns/` | Check DNS propagation — returns `{domain, server_ip, resolved_ip, propagated}` |
| `POST`   | `/api/nginx/preview/` | *(legacy)* Preview raw config |
| `POST`   | `/api/nginx/configure/` | *(legacy)* Write raw config + reload |
| `POST`   | `/api/nginx/certbot/` | *(legacy)* Run Certbot (generic) |

### WebSocket endpoints
| URL | Purpose |
|---|---|
| `ws://…/ws/ssh/` | Live SSH terminal (send connect payload) |
| `ws://…/ws/stacks/{id}/logs/` | Real-time deploy logs |
| `ws://…/ws/metrics/?token=<jwt>` | Live container metrics (CPU %, mem %, status) — pushed every 3 s |

---

## Tech Stack

| Layer | Technology |
|---|---|
| Backend | Django 5, DRF, Django Channels 4, Daphne |
| Auth | JWT (djangorestframework-simplejwt) |
| Docker control | `docker` SDK 7.1+ |
| SSH | Paramiko |
| GitHub | OAuth 2.0 (credentials in DB, no env vars) |
| NGINX management | `pyyaml` (compose bypass), `cryptography` (cert expiry parsing) |
| SSL | Let's Encrypt via `certbot/certbot:latest` — on-demand + 12 h auto-renewal |
| Database | SQLite (local dev) / PostgreSQL 15 (production) |
| Cache / WS layer | InMemoryChannelLayer (local dev) / Redis 7 (production) |
| Frontend | Flutter 3.43 (macOS + web) |
| State management | Provider |
| HTTP client | Dio |
| Fonts | Google Fonts — Inter + JetBrains Mono |
