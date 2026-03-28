#!/usr/bin/env bash
# ==============================================================================
#  Ondes HOST — VPS Deployment Script
#  Supports: Ubuntu 20+, Debian 11+, CentOS/RHEL/Rocky/AlmaLinux 8+, Fedora 37+
# ==============================================================================
set -euo pipefail

# ── ANSI colours ──────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  BOLD='\033[1m'; NC='\033[0m'

# ── Logging helpers ───────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
fatal()   { error "$*"; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}━━━  $*  ━━━${NC}"; }
ask()     { echo -e "${YELLOW}[?]${NC}    $*"; }  # prompt prefix (cosmetic)

# ── Non-interactive / CI mode ────────────────────────────────────────────────
# Set ONDES_CI=1 to skip all interactive prompts (used by send_to_vps.sh).
#   - System nginx / conflicting web servers: auto-removed
#   - Superuser creation: skipped (create manually afterwards)
#   - UFW: auto-configured with recommended rules
ONDES_CI="${ONDES_CI:-0}"

# ── Image sourcing ────────────────────────────────────────────────────────────
# Default: pull pre-built images from GHCR (fast — no compile step on the VPS).
# Set ONDES_BUILD=1 to force a local build from source instead.
ONDES_BUILD="${ONDES_BUILD:-0}"

banner() {
  echo -e "${BOLD}${CYAN}"
  cat << 'ONDES'
   ___  _  _ ___  ___ ___
  / _ \| \| |   \| __/ __|
 | (_) | .` | |) | _|\__ \
  \___/|_|\_|___/|___|___/  HOST
ONDES
  echo -e "${NC}${BOLD}  VPS Deployment Script — $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
  echo -e "  ─────────────────────────────────────────────────────"
  echo ""
}

# ── Default / weak placeholder values that must NOT reach production ──────────
DEFAULT_SECRET_KEYS=(
  "your-secret-key-change-in-production"
  "dev-secret-key-change-in-production"
  "local-dev-secret-not-for-production"
)
DEFAULT_PG_PASSWORDS=("ondes_password" "postgres" "password" "changeme" "secret")
DEFAULT_CERTBOT_EMAILS=("admin@example.com" "user@example.com" "")

# ── Script location (works even when piped through bash) ──────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
# If called remotely (curl | bash), BASH_SOURCE[0] is empty → fallback to cwd
[[ "$SCRIPT_DIR" == "/" ]] && SCRIPT_DIR="$PWD"

# ── Where to clone the repo when this script is run remotely ─────────────────
REPO_URL="${ONDES_REPO_URL:-https://github.com/MartinBellot/ONDES_HOST.git}"
INSTALL_DIR="${ONDES_DIR:-/opt/ondes-host}"

# ==============================================================================
#  STEP 0 — Banner
# ==============================================================================
banner

# ==============================================================================
#  STEP 1 — Root / sudo check
# ==============================================================================
step "Privilege check"
if [[ $EUID -ne 0 ]]; then
  fatal "Please run this script as root:  sudo bash $0"
fi
success "Running as root"

# ==============================================================================
#  STEP 2 — OS detection
# ==============================================================================
step "Operating system detection"
[[ -f /etc/os-release ]] || fatal "Cannot detect OS — /etc/os-release not found."
# shellcheck source=/dev/null
source /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-0}"
info "Detected: ${PRETTY_NAME:-$OS_ID $OS_VER}"

case "$OS_ID" in
  ubuntu|debian|raspbian)
    PKG_UPDATE="apt-get update -qq"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_REMOVE="apt-get remove --purge -y"
    PKG_AUTOREMOVE="apt-get autoremove -y"
    ;;
  centos|rhel|rocky|almalinux)
    PKG_UPDATE="dnf check-update --quiet || true"
    PKG_INSTALL="dnf install -y"
    PKG_REMOVE="dnf remove -y"
    PKG_AUTOREMOVE="dnf autoremove -y"
    ;;
  fedora)
    PKG_UPDATE="dnf check-update --quiet || true"
    PKG_INSTALL="dnf install -y"
    PKG_REMOVE="dnf remove -y"
    PKG_AUTOREMOVE="dnf autoremove -y"
    ;;
  *)
    warn "Unsupported OS '$OS_ID' — defaulting to apt-get. Results may vary."
    PKG_UPDATE="apt-get update -qq"
    PKG_INSTALL="apt-get install -y --no-install-recommends"
    PKG_REMOVE="apt-get remove --purge -y"
    PKG_AUTOREMOVE="apt-get autoremove -y"
    ;;
esac
success "Package manager configured"

# ==============================================================================
#  STEP 3 — System resource sanity checks
# ==============================================================================
step "System resources"

# RAM
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
if [[ $TOTAL_RAM_MB -lt 900 ]]; then
  warn "Low RAM: ${TOTAL_RAM_MB} MB detected. Recommended minimum: 1 GB."
else
  success "RAM: ${TOTAL_RAM_MB} MB"
fi

# Available disk space on / (need ≥ 5 GB)
FREE_DISK_KB=$(df / | awk 'NR==2 {print $4}')
FREE_DISK_GB=$((FREE_DISK_KB / 1024 / 1024))
if [[ $FREE_DISK_GB -lt 5 ]]; then
  warn "Low free disk space: ${FREE_DISK_GB} GB on /. Recommended minimum: 5 GB."
else
  success "Free disk: ${FREE_DISK_GB} GB"
fi

# ==============================================================================
#  STEP 4 — Port conflict detection
# ==============================================================================
step "Port availability"

REQUIRED_PORTS=(80 443 3000 8000 5432 6379)
PORT_CONFLICT_FOUND=false

for port in "${REQUIRED_PORTS[@]}"; do
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    warn "Port ${port} is already in use ($(ss -tlnp | grep ":${port} " | awk '{print $NF}' | head -1))"
    PORT_CONFLICT_FOUND=true
  fi
done

if $PORT_CONFLICT_FOUND; then
  warn "Port conflicts detected above — they will be resolved in the next steps."
else
  success "All required ports are free"
fi

# ==============================================================================
#  STEP 5 — Remove system NGINX (conflicts with Docker NGINX on ports 80/443)
# ==============================================================================
step "Checking for system-level NGINX"

NGINX_PKG_VARIANTS=(nginx nginx-common nginx-full nginx-light nginx-extras nginx-core)
NGINX_BINARY_FOUND=false

if command -v nginx &>/dev/null; then
  NGINX_V=$(nginx -v 2>&1 | head -1)
  warn "System NGINX found: $NGINX_V"
  warn "It will conflict with the Dockerised NGINX container on ports 80 and 443."
  NGINX_BINARY_FOUND=true
fi

# Also check if any nginx package is installed even without a running binary
if ! $NGINX_BINARY_FOUND; then
  case "$OS_ID" in
    ubuntu|debian|raspbian)
      if dpkg -l nginx 2>/dev/null | grep -q "^ii"; then
        NGINX_V=$(dpkg -l nginx | awk '/^ii/{print $3}')
        warn "NGINX package installed (v${NGINX_V}) but binary not in PATH."
        NGINX_BINARY_FOUND=true
      fi ;;
    centos|rhel|rocky|almalinux|fedora)
      if rpm -q nginx &>/dev/null; then
        NGINX_V=$(rpm -q nginx)
        warn "NGINX RPM installed: $NGINX_V"
        NGINX_BINARY_FOUND=true
      fi ;;
  esac
fi

if $NGINX_BINARY_FOUND; then
  echo ""
  if [[ "$ONDES_CI" == "1" ]]; then
    REMOVE_NGINX="Y"
    info "[CI] Auto-removing system NGINX."
  else
    ask "Remove system NGINX now? (required to free ports 80/443) [Y/n]: "
    read -r REMOVE_NGINX
    REMOVE_NGINX="${REMOVE_NGINX:-Y}"
  fi

  if [[ "$REMOVE_NGINX" =~ ^[Yy]$ ]]; then
    info "Stopping and disabling system NGINX…"
    systemctl stop  nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true

    info "Removing NGINX packages…"
    case "$OS_ID" in
      ubuntu|debian|raspbian)
        # shellcheck disable=SC2086
        $PKG_REMOVE ${NGINX_PKG_VARIANTS[*]} 2>/dev/null || true
        $PKG_AUTOREMOVE 2>/dev/null || true ;;
      centos|rhel|rocky|almalinux|fedora)
        $PKG_REMOVE nginx 2>/dev/null || true
        $PKG_AUTOREMOVE 2>/dev/null || true ;;
    esac

    # Clean leftover configs/logs
    rm -rf /etc/nginx /var/log/nginx /var/cache/nginx /run/nginx.pid 2>/dev/null || true

    success "System NGINX removed"
  else
    fatal "System NGINX must be removed before deploying. Re-run and answer Y, or remove it manually."
  fi
else
  success "No system NGINX detected"
fi

# ── Also check for other web servers that may hold port 80 ───────────────────
for ws in apache2 httpd lighttpd caddy; do
  if systemctl is-active --quiet "$ws" 2>/dev/null; then
    warn "Service '${ws}' is active and may hold port 80/443."
    if [[ "$ONDES_CI" == "1" ]]; then
      STOP_WS="Y"
      info "[CI] Auto-stopping ${ws}."
    else
      ask "Stop and disable '${ws}'? [Y/n]: "
      read -r STOP_WS; STOP_WS="${STOP_WS:-Y}"
    fi
    if [[ "$STOP_WS" =~ ^[Yy]$ ]]; then
      systemctl stop    "$ws" 2>/dev/null || true
      systemctl disable "$ws" 2>/dev/null || true
      success "${ws} stopped and disabled"
    else
      warn "${ws} left running — Docker NGINX may fail to bind port 80/443."
    fi
  fi
done

# ==============================================================================
#  STEP 6 — Install required system packages
# ==============================================================================
step "Installing system dependencies"

info "Updating package lists…"
eval "$PKG_UPDATE" 2>/dev/null || true

DEPS=(curl git openssl ca-certificates gnupg lsb-release)
info "Installing: ${DEPS[*]}"
# shellcheck disable=SC2086
$PKG_INSTALL ${DEPS[*]} 2>/dev/null || true

# Verify the must-have binaries are present
for bin in curl git openssl; do
  command -v "$bin" &>/dev/null || fatal "'$bin' is missing after install — cannot continue."
done

success "System dependencies ready"

# ==============================================================================
#  STEP 7 — Docker Engine
# ==============================================================================
step "Docker Engine"

if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
  success "Docker already installed: v${DOCKER_VER}"
else
  info "Docker not found — installing via official script…"
  curl -fsSL https://get.docker.com | bash || \
    fatal "Docker installation failed. Try manually: https://docs.docker.com/engine/install/"
  success "Docker Engine installed"
fi

# Enable + start Docker daemon
systemctl enable --now docker
# Quick smoke test
docker info &>/dev/null || fatal "Docker daemon not responding. Run: systemctl status docker"
success "Docker daemon is running"

# ==============================================================================
#  STEP 8 — Docker Compose v2
# ==============================================================================
step "Docker Compose v2"

COMPOSE_PLUGIN_DIR="/usr/local/lib/docker/cli-plugins"

install_compose_plugin() {
  info "Downloading Docker Compose plugin…"
  mkdir -p "$COMPOSE_PLUGIN_DIR"
  ARCH=$(uname -m)
  COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${ARCH}"
  curl -fsSL "$COMPOSE_URL" -o "${COMPOSE_PLUGIN_DIR}/docker-compose"
  chmod +x "${COMPOSE_PLUGIN_DIR}/docker-compose"
}

if docker compose version &>/dev/null 2>&1; then
  DC_VER=$(docker compose version --short 2>/dev/null || echo "v2+")
  success "Docker Compose v2 available: ${DC_VER}"
else
  # Try to install via package manager first (cleaner), fall back to direct download
  case "$OS_ID" in
    ubuntu|debian|raspbian)
      $PKG_INSTALL docker-compose-plugin 2>/dev/null || install_compose_plugin ;;
    centos|rhel|rocky|almalinux|fedora)
      $PKG_INSTALL docker-compose-plugin 2>/dev/null || install_compose_plugin ;;
    *)
      install_compose_plugin ;;
  esac
  docker compose version &>/dev/null || fatal "Docker Compose v2 installation failed."
  success "Docker Compose v2 installed"
fi

DC="docker compose"  # canonical command for the rest of this script

# ==============================================================================
#  STEP 9 — Locate or clone the project
# ==============================================================================
step "Project directory"

if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
  PROJECT_DIR="$SCRIPT_DIR"
  info "Project already present at: $PROJECT_DIR"
else
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Repository already cloned at $INSTALL_DIR — pulling latest…"
    git -C "$INSTALL_DIR" pull --ff-only || warn "git pull failed — continuing with existing files."
    PROJECT_DIR="$INSTALL_DIR"
  else
    info "Cloning repository into $INSTALL_DIR…"
    git clone "$REPO_URL" "$INSTALL_DIR" || \
      fatal "git clone failed. Check REPO_URL or set ONDES_REPO_URL env var."
    PROJECT_DIR="$INSTALL_DIR"
  fi
fi

cd "$PROJECT_DIR"
success "Working directory: $PROJECT_DIR"

# ==============================================================================
#  STEP 10 — .env setup and security validation
# ==============================================================================
step "Environment configuration (.env)"

ENV_FILE="$PROJECT_DIR/.env"
ENV_EXAMPLE="$PROJECT_DIR/.env.example"

# ── 10a. Ensure .env exists ───────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ENV_EXAMPLE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "Created .env from .env.example"
  else
    fatal ".env not found and .env.example is missing — cannot continue."
  fi
fi

# ── .env read/write helpers ───────────────────────────────────────────────────
env_get() {
  # Use 'grep ... || true' so a missing key does not trigger 'set -e / pipefail'
  grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true
}
env_set() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

# ── 10b. SECRET_KEY ──────────────────────────────────────────────────────────
CURRENT_SECRET=$(env_get SECRET_KEY)
IS_WEAK_SECRET=false
for def in "${DEFAULT_SECRET_KEYS[@]}"; do
  [[ "$CURRENT_SECRET" == "$def" ]] && IS_WEAK_SECRET=true && break
done
[[ -z "$CURRENT_SECRET" ]] && IS_WEAK_SECRET=true

if $IS_WEAK_SECRET; then
  warn "SECRET_KEY is using a default/empty placeholder — auto-generating a cryptographically secure value…"
  NEW_SECRET=$(openssl rand -hex 50)
  env_set SECRET_KEY "$NEW_SECRET"
  success "SECRET_KEY auto-generated (100 hex chars)"
else
  success "SECRET_KEY — custom value detected ✓"
fi

# ── 10c. DEBUG ────────────────────────────────────────────────────────────────
CURRENT_DEBUG=$(env_get DEBUG)
if [[ "$CURRENT_DEBUG" == "True" ]]; then
  warn "DEBUG=True is unsafe on a public server — it leaks stack traces and disables security middleware."
  ask "Set DEBUG=False now? [Y/n]: "
  read -r SET_DEBUG; SET_DEBUG="${SET_DEBUG:-Y}"
  if [[ "$SET_DEBUG" =~ ^[Yy]$ ]]; then
    env_set DEBUG False
    success "DEBUG set to False"
  else
    warn "DEBUG remains True — DO NOT expose this server to the internet."
  fi
else
  success "DEBUG=False ✓"
fi

# ── 10d. POSTGRES_PASSWORD & DATABASE_URL ────────────────────────────────────
CURRENT_PG_PASS=$(env_get POSTGRES_PASSWORD)
IS_WEAK_PG=false
for def in "${DEFAULT_PG_PASSWORDS[@]}"; do
  [[ "$CURRENT_PG_PASS" == "$def" ]] && IS_WEAK_PG=true && break
done
[[ -z "$CURRENT_PG_PASS" ]] && IS_WEAK_PG=true

if $IS_WEAK_PG; then
  warn "POSTGRES_PASSWORD is a known weak/default value — auto-generating a secure password…"
  NEW_PG_PASS=$(openssl rand -hex 24)
  env_set POSTGRES_PASSWORD "$NEW_PG_PASS"
  # Rebuild DATABASE_URL with the new password
  PG_USER=$(env_get POSTGRES_USER); PG_USER="${PG_USER:-ondes_user}"
  PG_DB=$(env_get POSTGRES_DB);     PG_DB="${PG_DB:-ondes_db}"
  env_set DATABASE_URL "postgresql://${PG_USER}:${NEW_PG_PASS}@db:5432/${PG_DB}"
  success "POSTGRES_PASSWORD auto-generated and DATABASE_URL updated"
else
  success "POSTGRES_PASSWORD — custom value detected ✓"
fi

# ── 10e. CERTBOT_EMAIL ────────────────────────────────────────────────────────
CURRENT_EMAIL=$(env_get CERTBOT_EMAIL)
IS_DEFAULT_EMAIL=false
for def in "${DEFAULT_CERTBOT_EMAILS[@]}"; do
  [[ "$CURRENT_EMAIL" == "$def" ]] && IS_DEFAULT_EMAIL=true && break
done

if $IS_DEFAULT_EMAIL; then
  warn "CERTBOT_EMAIL is set to a placeholder — Let's Encrypt needs a real email address."
  while true; do
    ask "Enter your email for SSL certificate notifications: "
    read -r USER_EMAIL
    if [[ "$USER_EMAIL" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
      env_set CERTBOT_EMAIL "$USER_EMAIL"
      success "CERTBOT_EMAIL set to $USER_EMAIL"
      break
    else
      error "Invalid email address — please try again."
    fi
  done
else
  success "CERTBOT_EMAIL: ${CURRENT_EMAIL} ✓"
fi

# ── 10f. ALLOWED_HOSTS (production safety) ────────────────────────────────────
CURRENT_HOSTS=$(env_get ALLOWED_HOSTS)
CURRENT_DEBUG_NOW=$(env_get DEBUG)
if [[ "$CURRENT_DEBUG_NOW" == "False" && ("$CURRENT_HOSTS" == "*" || -z "$CURRENT_HOSTS") ]]; then
  warn "ALLOWED_HOSTS='*' or empty is insecure in production (DEBUG=False)."
  ask "Enter your server domain(s) / public IP (comma-separated, e.g. my.domain.com,1.2.3.4): "
  read -r USER_HOSTS
  if [[ -n "$USER_HOSTS" ]]; then
    FULL_HOSTS="${USER_HOSTS},localhost,127.0.0.1,localhost:8000,127.0.0.1:8000"
    env_set ALLOWED_HOSTS "$FULL_HOSTS"
    success "ALLOWED_HOSTS set to: $FULL_HOSTS"
  else
    warn "ALLOWED_HOSTS left as '$CURRENT_HOSTS' — ensure this is intentional."
  fi
else
  success "ALLOWED_HOSTS: ${CURRENT_HOSTS} ✓"
fi

# ── 10g. CORS_ALLOWED_ORIGINS ────────────────────────────────────────────────
CURRENT_CORS=$(env_get CORS_ALLOWED_ORIGINS)
if [[ "$CURRENT_CORS" == "http://localhost:3000" && "$CURRENT_DEBUG_NOW" == "False" ]]; then
  warn "CORS_ALLOWED_ORIGINS still points to localhost — this will block browser-based requests from your domain."
  ask "Enter your frontend URL (e.g. https://app.my.domain.com) [Enter to skip]: "
  read -r USER_CORS
  if [[ -n "$USER_CORS" ]]; then
    env_set CORS_ALLOWED_ORIGINS "$USER_CORS"
    success "CORS_ALLOWED_ORIGINS set to: $USER_CORS"
  else
    warn "CORS_ALLOWED_ORIGINS left as localhost."
  fi
else
  success "CORS_ALLOWED_ORIGINS: ${CURRENT_CORS} ✓"
fi

# ── 10h. FRONTEND_URL ────────────────────────────────────────────────────────
CURRENT_FE_URL=$(env_get FRONTEND_URL)
if [[ -z "$CURRENT_FE_URL" || "$CURRENT_FE_URL" == "http://localhost:3000" ]]; then
  CORS_AS_FRONTEND=$(env_get CORS_ALLOWED_ORIGINS)
  if [[ -n "$CORS_AS_FRONTEND" && "$CORS_AS_FRONTEND" != "http://localhost:3000" ]]; then
    env_set FRONTEND_URL "$CORS_AS_FRONTEND"
    success "FRONTEND_URL set to: $CORS_AS_FRONTEND (from CORS_ALLOWED_ORIGINS)"
  fi
fi

# ── 10i. SERVER_PUBLIC_IP — auto-detect and persist at deploy time ───────────
CURRENT_PUBLIC_IP=$(env_get SERVER_PUBLIC_IP || true)
if [[ -z "$CURRENT_PUBLIC_IP" ]]; then
  DETECTED_IP=$(curl -4 -s --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || true)
  if [[ -n "$DETECTED_IP" && "$DETECTED_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    env_set SERVER_PUBLIC_IP "$DETECTED_IP"
    success "SERVER_PUBLIC_IP auto-detected: $DETECTED_IP"
  else
    warn "Could not auto-detect public IP (no internet? firewall?). DNS check in UI may show internal IP."
    warn "Set SERVER_PUBLIC_IP manually in .env if needed."
  fi
else
  success "SERVER_PUBLIC_IP: $CURRENT_PUBLIC_IP ✓"
fi

# ── 10j. Print sanitised .env summary ────────────────────────────────────────
echo ""
info "Final .env summary (secrets truncated):"
printf "  %-28s %s\n" "SECRET_KEY"           "$(env_get SECRET_KEY | cut -c1-12)… (truncated)"
printf "  %-28s %s\n" "DEBUG"                "$(env_get DEBUG)"
printf "  %-28s %s\n" "POSTGRES_DB"          "$(env_get POSTGRES_DB)"
printf "  %-28s %s\n" "POSTGRES_USER"        "$(env_get POSTGRES_USER)"
printf "  %-28s %s\n" "POSTGRES_PASSWORD"    "$(env_get POSTGRES_PASSWORD | cut -c1-6)… (truncated)"
printf "  %-28s %s\n" "DATABASE_URL"         "$(env_get DATABASE_URL | sed 's|://[^:]*:[^@]*@|://***:***@|')"
printf "  %-28s %s\n" "REDIS_URL"            "$(env_get REDIS_URL)"
printf "  %-28s %s\n" "ALLOWED_HOSTS"        "$(env_get ALLOWED_HOSTS)"
printf "  %-28s %s\n" "CORS_ALLOWED_ORIGINS" "$(env_get CORS_ALLOWED_ORIGINS)"
printf "  %-28s %s\n" "CERTBOT_EMAIL"        "$(env_get CERTBOT_EMAIL)"

# ==============================================================================
#  STEP 11 — Docker socket permissions
# ==============================================================================
step "Docker socket permissions"

# The API container bind-mounts /var/run/docker.sock to manage user stacks.
DOCKER_SOCK="/var/run/docker.sock"
if [[ -S "$DOCKER_SOCK" ]]; then
  chmod 660 "$DOCKER_SOCK" 2>/dev/null || true
  getent group docker &>/dev/null || groupadd docker
  success "Docker socket is accessible (group: docker)"
else
  warn "$DOCKER_SOCK not found — Docker daemon may not be running."
fi

# Ensure stacks-data directory exists on the host (bind-mounted into API container)
mkdir -p "${PROJECT_DIR}/stacks-data"
success "Directory ${PROJECT_DIR}/stacks-data ready"

# Ensure the nginx-vhosts volume directory exists on the host
# (the Docker volume handles this automatically, but good to pre-confirm)

# ==============================================================================
#  STEP 12 — Pull base images (better layer caching for subsequent builds)
# ==============================================================================
step "Pulling upstream images"

info "Pulling postgres, redis, nginx, certbot base images…"
$DC pull db redis nginx certbot 2>/dev/null || true
success "Base images pulled (or already cached)"

# ==============================================================================
#  STEP 13 — Pull pre-built images or build from source (api + app)
# ==============================================================================
step "Docker images (api + app)"

if [[ "$ONDES_BUILD" == "1" ]]; then
  info "ONDES_BUILD=1 — building api and app from source (this can take 5–15 minutes)…"
  $DC build --parallel 2>&1 | sed 's/^/  /'
  success "All images built from source"
else
  info "Pulling pre-built images from GitHub Container Registry…"
  info "(set ONDES_BUILD=1 to build from source instead)"
  if $DC pull api app 2>&1 | sed 's/^/  /'; then
    success "Pre-built images pulled from GHCR — no build step needed ✓"
  else
    warn "GHCR pull failed (private repo? network issue?) — falling back to local build…"
    $DC build --parallel 2>&1 | sed 's/^/  /'
    success "All images built from source"
  fi
fi

# ==============================================================================
#  STEP 14 — Launch all services
# ==============================================================================
step "Starting services"

$DC up -d --remove-orphans
success "All services started in background"

# ==============================================================================
#  STEP 15 — Health checks: wait for API to be ready
# ==============================================================================
step "Waiting for services to become healthy"

MAX_WAIT=30    # seconds
INTERVAL=5
ELAPSED=0

info "Polling API readiness (max ${MAX_WAIT}s)…"
until curl -sf "http://localhost:8000/api/" &>/dev/null || \
      curl -sf "http://localhost:8000/admin/" &>/dev/null; do
  if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    warn "API did not respond within ${MAX_WAIT}s."
    warn "Check logs with:  docker compose logs --tail=50 api"
    break
  fi
  printf "  Waiting… %ds / %ds\r" "$ELAPSED" "$MAX_WAIT"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo ""

# Per-service status
for svc in db redis api nginx certbot app; do
  STATUS=$($DC ps "$svc" 2>/dev/null | tail -1 | awk '{print $NF}')
  if [[ -z "$STATUS" ]]; then
    warn "  $svc — no status info"
  elif echo "$STATUS" | grep -qi "up\|running\|healthy"; then
    success "  $svc — ${STATUS}"
  else
    warn "  $svc — ${STATUS}"
  fi
done

# ==============================================================================
#  STEP 16 — Django migrations check (idempotent)
# ==============================================================================
step "Running database migrations"

$DC exec -T api python manage.py migrate --noinput 2>&1 | sed 's/^/  /'
success "Migrations applied"

# ==============================================================================
#  STEP 17 — Create superuser (interactive, skippable)
# ==============================================================================
step "Admin superuser"

echo ""
if [[ "$ONDES_CI" == "1" ]]; then
  # In CI mode, use DJANGO_SUPERUSER_* env vars if provided, skip silently otherwise.
  if [[ -n "${DJANGO_SUPERUSER_USERNAME:-}" && -n "${DJANGO_SUPERUSER_PASSWORD:-}" ]]; then
    info "[CI] Creating superuser '${DJANGO_SUPERUSER_USERNAME}' non-interactively..."
    $DC exec -T api python manage.py createsuperuser --noinput \
      && success "Superuser '${DJANGO_SUPERUSER_USERNAME}' created" \
      || warn "Superuser creation failed (account may already exist)"
  else
    info "[CI] Superuser creation skipped (DJANGO_SUPERUSER_* not set)."
    info "     Run later:  docker compose exec api python manage.py createsuperuser"
  fi
else
  ask "Create a Django superuser now? (needed to access /admin) [Y/n]: "
  read -r CREATE_SU; CREATE_SU="${CREATE_SU:-Y}"
  if [[ "$CREATE_SU" =~ ^[Yy]$ ]]; then
    $DC exec api python manage.py createsuperuser
    success "Superuser created"
  else
    info "Skipped — you can create one later with:"
    info "  docker compose exec api python manage.py createsuperuser"
  fi
fi

# ==============================================================================
#  STEP 18 — UFW firewall (optional, interactive)
# ==============================================================================
step "Firewall (UFW)"

if command -v ufw &>/dev/null; then
  UFW_STATUS=$(ufw status 2>/dev/null | head -1)
  info "Current UFW status: $UFW_STATUS"
  echo ""
  if [[ "$ONDES_CI" == "1" ]]; then
    CONF_UFW="Y"
    info "[CI] Auto-configuring UFW."
  else
    ask "Configure UFW to allow ports 22 (SSH), 80 (HTTP), 443 (HTTPS) and block direct DB/cache access? [Y/n]: "
    read -r CONF_UFW; CONF_UFW="${CONF_UFW:-Y}"
  fi
  if [[ "$CONF_UFW" =~ ^[Yy]$ ]]; then
    ufw allow 22/tcp   comment "SSH"
    ufw allow 80/tcp   comment "HTTP — Ondes NGINX"
    ufw allow 443/tcp  comment "HTTPS — Ondes NGINX"
    # Explicitly block direct access to internal services from outside
    ufw deny  5432/tcp comment "PostgreSQL — internal only"
    ufw deny  6379/tcp comment "Redis — internal only"
    ufw deny  8000/tcp comment "API — proxied via NGINX"
    ufw deny  3000/tcp comment "App — proxied via NGINX"
    echo "y" | ufw enable 2>/dev/null || ufw reload 2>/dev/null || true
    success "UFW configured"
    ufw status numbered
  else
    warn "UFW not configured — make sure your cloud firewall blocks direct access to ports 5432, 6379, 8000, 3000."
  fi
else
  warn "UFW not installed — skipping firewall configuration."
  warn "Consider restricting ports 5432, 6379, 8000. 3000 via your cloud provider's firewall rules."
fi

# ==============================================================================
#  STEP 19 — Detect public IP for final summary
# ==============================================================================
SERVER_IP=$(curl -sf --max-time 5 https://icanhazip.com 2>/dev/null || \
            curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
            echo "YOUR_SERVER_IP")

# ==============================================================================
#  STEP 20 — Final status report
# ==============================================================================
step "Deployment complete"

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║            Ondes HOST deployed successfully!             ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Access URLs${NC} (replace IP with your domain once DNS is configured):"
echo -e "  ├─ Frontend    →  ${CYAN}http://${SERVER_IP}:3000${NC}"
echo -e "  ├─ API         →  ${CYAN}http://${SERVER_IP}:8000/api/${NC}"
echo -e "  └─ Admin panel →  ${CYAN}http://${SERVER_IP}:8000/admin/${NC}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  1. Point your domain's A record to ${CYAN}${SERVER_IP}${NC}"
echo -e "  2. Open the app → GitHub screen → connect your GitHub OAuth App"
echo -e "  3. Deploy your first stack and assign a domain in the Domaine & SSL tab"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "  ├─ Live logs (all)     :  cd ${PROJECT_DIR} && docker compose logs -f"
echo -e "  ├─ API logs only       :  docker compose logs -f api"
echo -e "  ├─ Stop everything     :  docker compose down"
echo -e "  ├─ Restart a service   :  docker compose restart <service>"
echo -e "  ├─ Run migration       :  docker compose exec api python manage.py migrate"
echo -e "  └─ Create superuser    :  docker compose exec api python manage.py createsuperuser"
echo ""
echo -e "  ${BOLD}Current service status:${NC}"
$DC ps
echo ""
