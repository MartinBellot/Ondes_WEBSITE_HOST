"""
NGINX Manager — service layer.

Architecture (Docker Compose deployment):
  - A named volume  `nginx_vhosts`  is shared between the API container
    (mounted at $NGINX_VHOSTS_DIR, default /nginx-vhosts) and the nginx
    container (mounted at /etc/nginx/conf.d/vhosts).
  - The API writes one .conf file per domain into that volume.
  - To reload nginx the API sends SIGHUP to the nginx container via
    the Docker socket (already mounted for docker_manager features).
  - Certbot is run on-demand as a one-shot container against the same
    `letsencrypt` and `certbot_webroot` named volumes.
  - The API also mounts `letsencrypt` read-only to read cert expiry dates.
"""
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import docker

# ── Volume paths inside the API container ────────────────────────────────────
VHOSTS_DIR     = Path(os.environ.get('NGINX_VHOSTS_DIR',  '/nginx-vhosts'))
LETSENCRYPT_DIR = Path(os.environ.get('LETSENCRYPT_DIR', '/etc/letsencrypt'))


# ─────────────────────────────────────────────────────────────────────────────
# Docker helpers
# ─────────────────────────────────────────────────────────────────────────────

def _docker_client():
    return docker.from_env()


def _get_nginx_container():
    """Return the running nginx container (matched by compose service label)."""
    try:
        client = _docker_client()
        containers = client.containers.list(
            filters={'label': 'com.docker.compose.service=nginx', 'status': 'running'},
        )
        return containers[0] if containers else None
    except Exception:
        return None


def reload_nginx() -> dict:
    """Send SIGHUP to the nginx container so it hot-reloads its config."""
    container = _get_nginx_container()
    if container is None:
        return {'status': 'error', 'message': 'Container nginx introuvable ou arrêté.'}
    try:
        container.kill(signal='HUP')
        return {'status': 'success'}
    except Exception as exc:
        return {'status': 'error', 'message': str(exc)}


def _find_volume_name(client, suffix: str) -> str | None:
    """
    Find a named Docker volume whose name ends with *suffix*.
    Compose typically names volumes as `<project>_<volname>`.
    """
    try:
        for vol in client.volumes.list():
            if vol.name == suffix or vol.name.endswith(f'_{suffix}'):
                return vol.name
        return None
    except Exception:
        return None


# ─────────────────────────────────────────────────────────────────────────────
# Vhost config generation
# ─────────────────────────────────────────────────────────────────────────────

def _proxy_block(upstream_port: int) -> str:
    return (
        f"        proxy_pass         http://host.docker.internal:{upstream_port};\n"
        "        proxy_set_header   Host              $host;\n"
        "        proxy_set_header   X-Real-IP         $remote_addr;\n"
        "        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;\n"
        "        proxy_set_header   X-Forwarded-Proto $scheme;\n"
        "        proxy_http_version 1.1;\n"
        "        proxy_set_header   Upgrade    $http_upgrade;\n"
        "        proxy_set_header   Connection \"upgrade\";\n"
        "        proxy_read_timeout 300s;\n"
    )


_ACME_BLOCK = (
    "    # ACME challenge — Certbot webroot\n"
    "    location /.well-known/acme-challenge/ {\n"
    "        root /var/www/certbot;\n"
    "    }\n"
)


def generate_vhost_config(domain: str, upstream_port: int, ssl: bool) -> str:
    """
    Generate a complete nginx server block for *domain*.
    - HTTP only  → proxy on port 80 + ACME challenge path
    - SSL active → HTTP only serves ACME + 301 redirect; HTTPS proxies upstream
    """
    proxy = _proxy_block(upstream_port)

    if ssl:
        http_server = (
            "server {\n"
            "    listen 80;\n"
            f"    server_name {domain};\n\n"
            f"{_ACME_BLOCK}\n"
            "    location / {\n"
            "        return 301 https://$host$request_uri;\n"
            "    }\n"
            "}\n\n"
        )
        https_server = (
            "server {\n"
            "    listen 443 ssl;\n"
            f"    server_name {domain};\n\n"
            f"    ssl_certificate     /etc/letsencrypt/live/{domain}/fullchain.pem;\n"
            f"    ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;\n"
            "    ssl_protocols       TLSv1.2 TLSv1.3;\n"
            "    ssl_ciphers         HIGH:!aNULL:!MD5;\n"
            "    ssl_session_cache   shared:SSL:10m;\n"
            "    ssl_session_timeout 1d;\n\n"
            "    add_header Strict-Transport-Security "
            "\"max-age=31536000; includeSubDomains\" always;\n"
            "    add_header X-Content-Type-Options nosniff always;\n"
            "    add_header X-Frame-Options SAMEORIGIN always;\n\n"
            f"{_ACME_BLOCK}\n"
            "    location / {\n"
            f"{proxy}"
            "    }\n"
            "}\n"
        )
        return http_server + https_server
    else:
        return (
            "server {\n"
            "    listen 80;\n"
            f"    server_name {domain};\n\n"
            f"{_ACME_BLOCK}\n"
            "    location / {\n"
            f"{proxy}"
            "    }\n"
            "}\n"
        )


# ─────────────────────────────────────────────────────────────────────────────
# Vhost file CRUD
# ─────────────────────────────────────────────────────────────────────────────

def write_vhost(domain: str, upstream_port: int, ssl: bool) -> dict:
    """Write the vhost .conf file into the shared volume and reload nginx."""
    try:
        VHOSTS_DIR.mkdir(parents=True, exist_ok=True)
    except PermissionError:
        return {'status': 'error', 'message': f'Permission refusée sur {VHOSTS_DIR}'}

    config = generate_vhost_config(domain, upstream_port, ssl)
    config_path = VHOSTS_DIR / f'{domain}.conf'
    try:
        config_path.write_text(config)
    except PermissionError:
        return {'status': 'error', 'message': f'Impossible d\'écrire {config_path}'}
    except Exception as exc:
        return {'status': 'error', 'message': str(exc)}

    reload_result = reload_nginx()
    return {
        'status': reload_result['status'],
        'config_path': str(config_path),
        'config': config,
        'message': reload_result.get('message', ''),
    }


def delete_vhost(domain: str) -> dict:
    """Remove the vhost config file and reload nginx."""
    config_path = VHOSTS_DIR / f'{domain}.conf'
    try:
        if config_path.exists():
            config_path.unlink()
        return reload_nginx()
    except Exception as exc:
        return {'status': 'error', 'message': str(exc)}


# ─────────────────────────────────────────────────────────────────────────────
# Certbot — on-demand via Docker SDK
# ─────────────────────────────────────────────────────────────────────────────

def run_certbot_for_domain(domain: str, email: str) -> dict:
    """
    Run certbot in a one-shot container using the webroot challenge.
    Prerequisite: an HTTP vhost must already be deployed and nginx running
    so that /.well-known/acme-challenge/ is reachable from Let's Encrypt.
    """
    try:
        client = _docker_client()
        le_vol      = _find_volume_name(client, 'letsencrypt')
        webroot_vol = _find_volume_name(client, 'certbot_webroot')

        if not le_vol or not webroot_vol:
            # Fallback for bare-metal / test environments
            return _run_certbot_subprocess(domain, email)

        output = client.containers.run(
            'certbot/certbot:latest',
            command=(
                f'certonly --webroot -w /var/www/certbot '
                f'-d {domain} '
                f'--email {email} '
                '--agree-tos --non-interactive --keep-until-expiring '
                '--preferred-challenges http'
            ),
            volumes={
                le_vol:      {'bind': '/etc/letsencrypt', 'mode': 'rw'},
                webroot_vol: {'bind': '/var/www/certbot',  'mode': 'rw'},
            },
            remove=True,
            stdout=True,
            stderr=True,
        )
        return {'status': 'success', 'output': output.decode('utf-8', errors='replace')}
    except docker.errors.ContainerError as exc:
        stderr = b''
        if hasattr(exc, 'stderr') and exc.stderr:
            stderr = exc.stderr
        return {'status': 'error', 'message': stderr.decode('utf-8', errors='replace')}
    except Exception as exc:
        return {'status': 'error', 'message': str(exc)}


def _run_certbot_subprocess(domain: str, email: str) -> dict:
    """Fallback: certbot binary on the host."""
    try:
        result = subprocess.run(
            [
                'certbot', 'certonly', '--webroot',
                '-w', '/var/www/certbot',
                '-d', domain,
                '--email', email,
                '--agree-tos', '--non-interactive', '--keep-until-expiring',
            ],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode == 0:
            return {'status': 'success', 'output': result.stdout}
        return {'status': 'error', 'message': result.stderr}
    except FileNotFoundError:
        return {
            'status': 'error',
            'message': 'certbot introuvable — volumes Docker non détectés et binaire absent.',
        }
    except Exception as exc:
        return {'status': 'error', 'message': str(exc)}


# ─────────────────────────────────────────────────────────────────────────────
# Certificate status & expiry
# ─────────────────────────────────────────────────────────────────────────────

def get_cert_info(domain: str) -> dict:
    """
    Read certificate expiry from /etc/letsencrypt/live/{domain}/cert.pem.
    Returns a dict with keys: expires_at (ISO string|None), days_remaining (int|None),
    status ('active'|'warning'|'critical'|'expired'|'none'|'error').
    """
    cert_path = LETSENCRYPT_DIR / 'live' / domain / 'cert.pem'
    if not cert_path.exists():
        return {'expires_at': None, 'days_remaining': None, 'status': 'none'}

    expiry = _read_cert_expiry_cryptography(cert_path) or _read_cert_expiry_openssl(cert_path)
    if expiry is None:
        return {'expires_at': None, 'days_remaining': None, 'status': 'error'}

    now   = datetime.now(tz=timezone.utc)
    delta = expiry - now
    days  = delta.days

    if days < 0:
        cert_status = 'expired'
    elif days < 7:
        cert_status = 'critical'
    elif days < 30:
        cert_status = 'warning'
    else:
        cert_status = 'active'

    return {
        'expires_at':     expiry.isoformat(),
        'days_remaining': days,
        'status':         cert_status,
    }


def _read_cert_expiry_cryptography(cert_path: Path) -> datetime | None:
    try:
        from cryptography import x509
        from cryptography.hazmat.backends import default_backend
        pem_data = cert_path.read_bytes()
        cert     = x509.load_pem_x509_certificate(pem_data, default_backend())
        # not_valid_after_utc is available in cryptography ≥ 42
        try:
            return cert.not_valid_after_utc
        except AttributeError:
            # Older cryptography: timezone-naive UTC datetime
            return cert.not_valid_after.replace(tzinfo=timezone.utc)  # type: ignore[attr-defined]
    except ImportError:
        return None
    except Exception:
        return None


def _read_cert_expiry_openssl(cert_path: Path) -> datetime | None:
    try:
        result = subprocess.run(
            ['openssl', 'x509', '-enddate', '-noout', '-in', str(cert_path)],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            return None
        # notAfter=Mar 24 12:00:00 2026 GMT
        date_str = result.stdout.strip().split('=', 1)[1].strip()
        return datetime.strptime(date_str, '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
    except Exception:
        return None


def sync_cert_status(vhost) -> None:
    """
    Refresh vhost.ssl_status and vhost.ssl_expires_at from the cert on disk.
    Saves only those two fields.
    """
    info = get_cert_info(vhost.domain)

    if info['expires_at']:
        vhost.ssl_expires_at = datetime.fromisoformat(info['expires_at'])
    else:
        vhost.ssl_expires_at = None

    _status_map = {
        'active':   'active',
        'warning':  'active',
        'critical': 'active',
        'expired':  'expired',
        'error':    'error',
        'none':     'none',
    }
    vhost.ssl_status = _status_map.get(info.get('status', 'none'), 'none')
    vhost.save(update_fields=['ssl_status', 'ssl_expires_at'])

