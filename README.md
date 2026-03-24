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
| **Domaine & SSL** | "Domaine & SSL" tab in Stack Detail — add/remove vhosts, DNS guide, one-click SSL activation via Certbot, cert expiry countdown |
| **SSH Terminal** | Live WebSocket shell (Paramiko) |

---

## Quick Start

### 1. Configure environment
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
| `POST`   | `/api/nginx/preview/` | *(legacy)* Preview raw config |
| `POST`   | `/api/nginx/configure/` | *(legacy)* Write raw config + reload |
| `POST`   | `/api/nginx/certbot/` | *(legacy)* Run Certbot (generic) |

### WebSocket endpoints
| URL | Purpose |
|---|---|
| `ws://…/ws/ssh/` | Live SSH terminal (send connect payload) |
| `ws://…/ws/stacks/{id}/logs/` | Real-time deploy logs |

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
