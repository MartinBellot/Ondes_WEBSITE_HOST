# Ondes — Infrastructure Dashboard

A modern, self-hosted alternative to cPanel/Plesk built as a monorepo.

```
.
├── api/          # Django backend (REST + WebSocket)
├── app/          # Flutter frontend (web)
├── docker-compose.yml
├── .env.example
└── .gitignore
```

---

## Quick Start

### 1. Configure environment
```bash
cp .env.example .env
# Edit .env — change SECRET_KEY and POSTGRES_PASSWORD at minimum
```

### 2. Start everything with Docker Compose
```bash
docker-compose up --build
```

| Service   | URL                          |
|-----------|------------------------------|
| Frontend  | http://localhost:3000        |
| API       | http://localhost:8000/api/   |
| Admin     | http://localhost:8000/admin/ |

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

# Start PostgreSQL & Redis locally, then:
python manage.py migrate
python manage.py runserver
# or with WebSocket support:
daphne -b 0.0.0.0 -p 8000 config.asgi:application
```

### Frontend
```bash
cd app
flutter pub get
flutter run -d chrome \
  --dart-define=API_URL=http://localhost:8000/api \
  --dart-define=WS_URL=ws://localhost:8000
```

---

## API Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/auth/register/` | Register a new user |
| `POST` | `/api/auth/login/` | Obtain JWT tokens |
| `POST` | `/api/auth/refresh/` | Refresh access token |
| `GET`  | `/api/docker/containers/` | List all containers |
| `POST` | `/api/docker/containers/create/` | Deploy a container |
| `POST` | `/api/docker/containers/{id}/start/` | Start a container |
| `POST` | `/api/docker/containers/{id}/stop/` | Stop a container |
| `POST` | `/api/docker/containers/{id}/remove/` | Remove a container |
| `POST` | `/api/nginx/preview/` | Preview NGINX config |
| `POST` | `/api/nginx/configure/` | Write NGINX config + reload |
| `POST` | `/api/nginx/certbot/` | Run Certbot SSL |

### WebSocket
```
ws://localhost:8000/ws/ssh/
```
Send `{ "type": "connect", "host": "…", "port": 22, "username": "…", "password": "…" }` to open a live shell.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Backend | Django 5, DRF, Django Channels, Daphne |
| Auth | JWT (djangorestframework-simplejwt) |
| Docker control | Python `docker` SDK |
| SSH | Paramiko |
| Database | PostgreSQL 15 |
| Cache / WS layer | Redis 7 |
| Frontend | Flutter (web) |
| State | Provider |
| HTTP client | Dio |
| Fonts | Google Fonts — Inter + JetBrains Mono |
