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
# In Docker Compose: NGINX_VHOSTS_DIR + LETSENCRYPT_DIR are injected via env.
# In local dev (no env vars set): fall back to writable paths under /tmp.
VHOSTS_DIR      = Path(os.environ.get('NGINX_VHOSTS_DIR',  '/tmp/ondes-nginx-vhosts'))
LETSENCRYPT_DIR = Path(os.environ.get('LETSENCRYPT_DIR',   '/tmp/ondes-letsencrypt'))


# ─────────────────────────────────────────────────────────────────────────────
# Docker helpers
# ─────────────────────────────────────────────────────────────────────────────

def _docker_client():
    return docker.from_env()


# The platform nginx belongs to the 'ondes-host' compose project.
# Filtering by project name prevents accidentally sending SIGHUP to a stack's
# own nginx container when multiple stacks expose a service named 'nginx'.
_PLATFORM_PROJECT = 'ondes-host'


def _get_nginx_container():
    """Return the platform nginx container, matched by both compose service and project labels."""
    try:
        client = _docker_client()
        containers = client.containers.list(
            filters={
                'label': [
                    'com.docker.compose.service=nginx',
                    f'com.docker.compose.project={_PLATFORM_PROJECT}',
                ],
                'status': 'running',
            },
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


def _location_blocks(route_overrides: list | None, upstream_port: int) -> str:
    """
    Build nginx ``location { }`` blocks from *route_overrides*.

    If *route_overrides* is a non-empty list of ``{path, upstream_port}`` dicts,
    produces one ``location`` block per entry sorted most-specific-first
    (``/`` always last).  Falls back to a single ``location /``.
    """
    if not route_overrides:
        return f"    location / {{\n{_proxy_block(upstream_port)}    }}\n"

    sorted_routes = sorted(
        route_overrides,
        key=lambda r: (r.get('path', '/') == '/', -len(r.get('path', '/'))),
    )
    blocks = []
    for r in sorted_routes:
        path = r.get('path', '/').strip() or '/'
        port = int(r.get('upstream_port', upstream_port))
        blocks.append(
            f"    location {path} {{\n"
            f"{_proxy_block(port)}"
            "    }\n"
        )
    return '\n'.join(blocks) + '\n'


def generate_vhost_config(
    domain: str,
    upstream_port: int,
    ssl: bool,
    route_overrides: list | None = None,
    include_www: bool = False,
) -> str:
    """
    Generate a complete nginx server block for *domain*.

    - HTTP only  → proxy on port 80 + ACME challenge path
    - SSL active → HTTP only serves ACME + 301 redirect; HTTPS proxies upstream

    *route_overrides* — optional list of ``{path, upstream_port}`` dicts.
    When provided, each path gets its own ``location`` block with the correct
    upstream port (e.g. ``/api/ → :8001``, ``/ → :3001`` for Next.js + Django).
    When omitted a single ``location /`` is generated from *upstream_port*.

    *include_www* — when True, adds a separate ``www.{domain}`` server block
    that redirects all traffic to the canonical ``{domain}``.  For SSL this
    also requires the certificate to cover ``www.{domain}`` (pass the same
    flag to :func:`run_certbot_for_domain`).
    """
    locations = _location_blocks(route_overrides, upstream_port)
    www_domain = f'www.{domain}'

    if ssl:
        # HTTP block: handles both domain + www (ACME + 301 to https://domain)
        http_server_names = f'{domain} {www_domain}' if include_www else domain
        http_server = (
            "server {\n"
            "    listen 80;\n"
            f"    server_name {http_server_names};\n\n"
            f"{_ACME_BLOCK}\n"
            "    location / {\n"
            f"        return 301 https://{domain}$request_uri;\n"
            "    }\n"
            "}\n\n"
        )
        # HTTPS www → canonical redirect block (only when include_www)
        www_https_block = (
            "server {\n"
            "    listen 443 ssl http2;\n"
            f"    server_name {www_domain};\n\n"
            f"    ssl_certificate     /etc/letsencrypt/live/{domain}/fullchain.pem;\n"
            f"    ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;\n"
            "    ssl_protocols       TLSv1.2 TLSv1.3;\n"
            "    ssl_ciphers         HIGH:!aNULL:!MD5;\n"
            "    ssl_session_cache   shared:SSL:10m;\n"
            "    ssl_session_timeout 1d;\n\n"
            f"    return 301 https://{domain}$request_uri;\n"
            "}\n\n"
        ) if include_www else ''
        https_server = (
            "server {\n"
            "    listen 443 ssl http2;\n"
            f"    server_name {domain};\n\n"
            f"    ssl_certificate     /etc/letsencrypt/live/{domain}/fullchain.pem;\n"
            f"    ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;\n"
            "    ssl_protocols       TLSv1.2 TLSv1.3;\n"
            "    ssl_ciphers         HIGH:!aNULL:!MD5;\n"
            "    ssl_session_cache   shared:SSL:10m;\n"
            "    ssl_session_timeout 1d;\n\n"
            "    client_max_body_size 2g;\n"
            "    proxy_read_timeout   600s;\n"
            "    proxy_connect_timeout 60s;\n"
            "    proxy_send_timeout   600s;\n\n"
            "    add_header Strict-Transport-Security "
            "\"max-age=31536000; includeSubDomains\" always;\n"
            "    add_header X-Content-Type-Options nosniff always;\n"
            "    add_header X-Frame-Options SAMEORIGIN always;\n\n"
            f"{_ACME_BLOCK}\n"
            f"{locations}"
            "}\n"
        )
        return http_server + www_https_block + https_server
    else:
        # HTTP-only: www redirect block (before SSL is set up)
        www_http_block = (
            "server {\n"
            "    listen 80;\n"
            f"    server_name {www_domain};\n"
            f"    return 301 http://{domain}$request_uri;\n"
            "}\n\n"
        ) if include_www else ''
        main_block = (
            "server {\n"
            "    listen 80;\n"
            f"    server_name {domain};\n\n"
            f"{_ACME_BLOCK}\n"
            f"{locations}"
            "}\n"
        )
        return www_http_block + main_block


# ─────────────────────────────────────────────────────────────────────────────
# Vhost file CRUD
# ─────────────────────────────────────────────────────────────────────────────

def write_vhost(
    domain: str,
    upstream_port: int,
    ssl: bool,
    route_overrides: list | None = None,
    include_www: bool = False,
) -> dict:
    """Write the vhost .conf file into the shared volume and reload nginx.

    The file write is critical — a failure returns status='error'.
    The nginx reload is best-effort; if the container is not found (e.g. local
    dev without Docker Compose) the config is still saved and status='saved'.

    *route_overrides* — optional list of ``{path, upstream_port}`` dicts for
    multi-service routing.  When omitted, a single ``location /`` is generated.

    *include_www* — when True includes a www.{domain} redirect server block.
    """
    try:
        VHOSTS_DIR.mkdir(parents=True, exist_ok=True)
    except PermissionError:
        return {'status': 'error', 'message': f'Permission refusée sur {VHOSTS_DIR}'}
    except OSError as exc:
        return {'status': 'error', 'message': str(exc)}

    config = generate_vhost_config(domain, upstream_port, ssl, route_overrides, include_www)
    config_path = VHOSTS_DIR / f'{domain}.conf'
    try:
        config_path.write_text(config)
    except PermissionError:
        return {'status': 'error', 'message': f'Impossible d\'écrire {config_path}'}
    except Exception as exc:
        return {'status': 'error', 'message': str(exc)}

    reload_result = reload_nginx()
    nginx_ok = reload_result['status'] == 'success'
    return {
        'status': 'success' if nginx_ok else 'saved',
        'config_path': str(config_path),
        'config': config,
        'message': '' if nginx_ok else (
            'Config sauvegardée. Reload nginx impossible : '
            + reload_result.get('message', '')
        ),
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

def run_certbot_for_domain(domain: str, email: str, include_www: bool = False) -> dict:
    """
    Run certbot in a one-shot container using the webroot challenge.
    Prerequisite: an HTTP vhost must already be deployed and nginx running
    so that /.well-known/acme-challenge/ is reachable from Let's Encrypt.

    *include_www* — when True, also requests a certificate for www.{domain}.
    """
    try:
        client = _docker_client()
        le_vol      = _find_volume_name(client, 'letsencrypt')
        webroot_vol = _find_volume_name(client, 'certbot_webroot')

        if not le_vol or not webroot_vol:
            # Fallback for bare-metal / test environments
            return _run_certbot_subprocess(domain, email, include_www)

        domains_flag = f'-d {domain}' + (f' -d www.{domain}' if include_www else '')
        output = client.containers.run(
            'certbot/certbot:latest',
            command=(
                f'certonly --webroot -w /var/www/certbot '
                f'{domains_flag} '
                f'--email {email} '
                '--agree-tos --non-interactive --keep-until-expiring --expand '
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


def _run_certbot_subprocess(domain: str, email: str, include_www: bool = False) -> dict:
    """Fallback: certbot binary on the host."""
    try:
        result = subprocess.run(
            [
                'certbot', 'certonly', '--webroot',
                '-w', '/var/www/certbot',
                '-d', domain,
                *(['-d', f'www.{domain}'] if include_www else []),
                '--email', email,
                '--agree-tos', '--non-interactive', '--keep-until-expiring', '--expand',
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


# ─────────────────────────────────────────────────────────────────────────────
# DNS propagation check
# ─────────────────────────────────────────────────────────────────────────────

def get_server_ip() -> str | None:
    """Return the server's public IP address.

    Priority:
    1. SERVER_PUBLIC_IP env var (set at deploy time — most reliable in Docker)
    2. External IP detection service (bypasses Docker NAT)
    3. UDP routing trick (fallback; may return Docker internal IP)
    """
    import os as _os
    import socket as _socket

    # Priority 1: explicit env var injected at deploy time
    env_ip = _os.environ.get('SERVER_PUBLIC_IP', '').strip()
    if env_ip:
        return env_ip

    # Priority 2: external service — works when the container has outbound internet
    try:
        import urllib.request as _ur
        with _ur.urlopen('https://api.ipify.org', timeout=3) as _resp:  # noqa: S310
            return _resp.read().decode().strip()
    except Exception:
        pass

    # Priority 3: routing trick (may return Docker bridge IP, not public IP)
    try:
        with _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM) as s:
            s.settimeout(3)
            s.connect(('8.8.8.8', 80))
            return s.getsockname()[0]
    except Exception:
        return None


def resolve_domain_dns(domain: str) -> str | None:
    """Resolve *domain* to an IPv4 address via the system resolver."""
    import socket as _socket
    try:
        return _socket.gethostbyname(domain)
    except Exception:
        return None


def check_dns_propagation(domain: str) -> dict:
    """
    Check whether *domain* currently resolves to this server's IP.

    Returns a dict:
      {
        "domain":      str,
        "server_ip":   str | None,
        "resolved_ip": str | None,
        "propagated":  bool,
      }
    """
    server_ip = get_server_ip()
    resolved_ip = resolve_domain_dns(domain)
    propagated = bool(server_ip and resolved_ip and resolved_ip == server_ip)
    return {
        'domain':      domain,
        'server_ip':   server_ip,
        'resolved_ip': resolved_ip,
        'propagated':  propagated,
    }


# ─────────────────────────────────────────────────────────────────────────────
# Nginx config parsing — auto-import vhosts from repo configs
# ─────────────────────────────────────────────────────────────────────────────
import re
from pathlib import Path as _Path


def _extract_server_blocks(content: str) -> list[str]:
    """Extract all top-level ``server { … }`` block contents using brace counting."""
    blocks = []
    pattern = re.compile(r'\bserver\s*\{')
    i = 0
    while i < len(content):
        m = pattern.search(content, i)
        if not m:
            break
        start = m.end()
        depth = 1
        j = start
        while j < len(content) and depth > 0:
            c = content[j]
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
            j += 1
        blocks.append(content[start : j - 1])
        i = m.start() + 1
    return blocks


def _extract_directive(block: str, name: str) -> list[str]:
    """Return all values for a directive like ``server_name`` or ``listen``."""
    return [m.group(1).strip() for m in re.finditer(rf'\b{name}\s+([^;]+);', block)]


def _extract_location_blocks(block: str) -> list[tuple[str, str]]:
    """Return ``[(path, block_content), …]`` for every ``location`` block."""
    locations: list[tuple[str, str]] = []
    pattern = re.compile(r'\blocation\s+([^\{]+?)\s*\{')
    i = 0
    while i < len(block):
        m = pattern.search(block, i)
        if not m:
            break
        path = m.group(1).strip()
        start = m.end()
        depth = 1
        j = start
        while j < len(block) and depth > 0:
            if block[j] == '{':
                depth += 1
            elif block[j] == '}':
                depth -= 1
            j += 1
        locations.append((path, block[start : j - 1]))
        i = m.start() + 1
    return locations


def _parse_proxy_pass(content: str) -> tuple[str, int] | None:
    """
    Extract ``(service_name, port)`` from a ``proxy_pass`` directive.
    Returns ``None`` if not found or if already managed by the platform
    (``host.docker.internal``).
    """
    m = re.search(r'proxy_pass\s+https?://([^:/\s;]+)(?::(\d+))?', content)
    if not m:
        return None
    service = m.group(1)
    if service == 'host.docker.internal':
        return None
    port = int(m.group(2)) if m.group(2) else 80
    return (service, port)


_WILDCARD_NAMES = frozenset({'_', 'localhost', '127.0.0.1', '::1'})


def parse_nginx_conf_file(content: str) -> list[dict]:
    """
    Parse raw nginx config content and return a list of discovered server specs.

    Each spec::

        {
          'server_name':      str,
          'all_names':        list[str],
          'ssl':              bool,
          'is_redirect_only': bool,
          'service_refs': [
              {'service': str, 'port': int, 'path': str, 'is_primary': bool}
          ],
        }
    """
    clean = re.sub(r'#[^\n]*', '', content)
    results = []

    for block in _extract_server_blocks(clean):
        all_names: list[str] = []
        for raw in _extract_directive(block, 'server_name'):
            all_names.extend(raw.split())

        real_names = [
            n for n in all_names
            if n not in _WILDCARD_NAMES and not n.startswith('~') and not n.startswith('*')
        ]
        server_name = (real_names or all_names or ['_'])[0]

        listens = _extract_directive(block, 'listen')
        ssl = any('443' in lst or 'ssl' in lst for lst in listens)

        service_refs: list[dict] = []
        has_return = bool(re.search(r'\breturn\s+30[12]\b', block))

        for path, loc_content in _extract_location_blocks(block):
            if '.well-known' in path:
                continue
            proxy = _parse_proxy_pass(loc_content)
            if proxy:
                service, port = proxy
                service_refs.append({
                    'service':    service,
                    'port':       port,
                    'path':       path,
                    'is_primary': (path.strip('/') == ''),
                })

        is_redirect_only = has_return and not service_refs

        results.append({
            'server_name':      server_name,
            'all_names':        all_names,
            'ssl':              ssl,
            'is_redirect_only': is_redirect_only,
            'service_refs':     service_refs,
        })

    return results


_NGINX_CONFIG_CANDIDATES = [
    'nginx/nginx.conf',
    'nginx/conf.d/default.conf',
    'nginx/conf.d/app.conf',
    'nginx/default.conf',
    'nginx.conf',
    'default.conf',
    'app.conf',
]


def scan_project_nginx_configs(project_dir: str) -> list[dict]:
    """
    Walk *project_dir* and parse every nginx config file found.

    Returns ``[{'file': str, 'specs': list[dict]}, …]`` — only files that
    contain at least one useful (non-redirect) server block with a service ref.
    """
    root = _Path(project_dir)
    found: list[_Path] = []

    for candidate in _NGINX_CONFIG_CANDIDATES:
        p = root / candidate
        if p.is_file():
            found.append(p)

    for nginx_dir in root.glob('*/nginx/'):
        for conf in nginx_dir.glob('**/*.conf'):
            if conf not in found:
                found.append(conf)

    for conf in root.glob('nginx/conf.d/*.conf'):
        if conf not in found:
            found.append(conf)

    results = []
    for conf_path in found:
        try:
            content = conf_path.read_text(errors='replace')
            specs = parse_nginx_conf_file(content)
            useful = [s for s in specs if not s['is_redirect_only'] and s['service_refs']]
            # Collect www.* redirect-only server names so build_vhost_suggestions
            # can detect which domains should have a www redirect block.
            www_redirects = [
                s['server_name'] for s in specs
                if s['is_redirect_only'] and s['server_name'].startswith('www.')
            ]
            if useful:
                results.append({
                    'file':          str(conf_path.relative_to(root)),
                    'specs':         useful,
                    'www_redirects': www_redirects,
                })
        except Exception:
            pass

    return results


def build_vhost_suggestions(
    parsed_files: list[dict],
    running_containers: list[dict],
    existing_info: dict[str, int],
    gateway_port: int | None = None,
) -> list[dict]:
    """
    Match parsed nginx specs with running containers by Docker service name.

    Each suggestion::

        {
          'domain':          str,
          'upstream_port':   int | None,   # host port of the primary service
          'service_label':   str,          # primary Docker service name
          'container_name':  str,
          'route_overrides': list[dict],   # [{path, upstream_port}, …] — all routes
          'ssl':             bool,
          'source_file':     str,
          'already_exists':  bool,
          'auto_create':     bool,
        }

    *gateway_port* — when provided, is used as a fallback upstream for domains
    whose primary service has no host-port binding.  This covers the pattern
    where the repo includes a gateway nginx on a custom port (e.g. 8081) and
    the platform should proxy to that port instead of directly to the app:
    the gateway nginx handles all internal routing (static/media/sub-services).
    """
    # Build service → {host_port, container_name} lookup
    service_map: dict[str, dict] = {}
    for c in running_containers:
        svc = c.get('service', '')
        ports = sorted(c.get('ports', []), key=lambda p: int(p.get('container_port') or 0))
        if ports:
            service_map[svc] = {
                'host_port':      ports[0].get('host_port'),
                'container_name': c.get('name', ''),
            }

    suggestions: list[dict] = []
    seen_domains: set[str] = set()

    # Collect www-redirect domains from all parsed files
    all_www_redirects: set[str] = set()
    for file_entry in parsed_files:
        all_www_redirects.update(file_entry.get('www_redirects', []))

    for file_entry in parsed_files:
        source_file = file_entry['file']
        for spec in file_entry['specs']:
            if spec['is_redirect_only']:
                continue

            domain = spec['server_name']
            # Skip wildcard / placeholder server names
            if domain in _WILDCARD_NAMES or domain.startswith('~') or domain.startswith('*'):
                continue
            if domain in seen_domains:
                continue

            primary_refs = [r for r in spec['service_refs'] if r['is_primary']]
            all_refs = spec['service_refs']
            main_ref = (primary_refs or all_refs or [None])[0]
            if not main_ref:
                continue

            svc_name = main_ref['service']
            container_info = service_map.get(svc_name)
            host_port = container_info['host_port'] if container_info else None
            container_name = container_info['container_name'] if container_info else ''

            # Build full route_overrides from all service_refs
            route_overrides: list[dict] = []
            for ref in all_refs:
                ref_svc = ref['service']
                ref_info = service_map.get(ref_svc)
                ref_host_port = ref_info['host_port'] if ref_info else None
                if ref_host_port is not None:
                    route_overrides.append({
                        'path':          ref['path'],
                        'upstream_port': ref_host_port,
                    })

            # Only include route_overrides when we have multiple distinct upstreams
            unique_ports = {r['upstream_port'] for r in route_overrides}
            if len(unique_ports) > 1:
                # Multi-service stack — also expose /static/ and /media/ via the
                # Django service port so WhiteNoise / Django serve view can handle them.
                # This covers cases where the original nginx served them via `alias`
                # (which the platform nginx cannot replicate without volume mounts).
                api_port = next(
                    (r['upstream_port'] for r in route_overrides
                     if r.get('path', '').startswith('/api') or r.get('path', '') == '/admin/'),
                    None,
                )
                if api_port:
                    existing_paths = {r['path'] for r in route_overrides}
                    for static_path in ('/static/', '/media/'):
                        if static_path not in existing_paths:
                            route_overrides.append({'path': static_path, 'upstream_port': api_port})

            effective_routes = route_overrides if len(unique_ports) > 1 else []

            # Detect www: either a separate redirect-only block OR both canonical and
            # www.domain appear in the same server_name directive.
            include_www = (
                f'www.{domain}' in all_www_redirects
                or f'www.{domain}' in spec.get('all_names', [])
            )

            # Gateway nginx fallback: when the primary service has no host-port binding
            # (internal-only) but the project exposes a gateway nginx on a custom port,
            # proxy to that gateway — it handles all internal routing itself.
            if host_port is None and gateway_port is not None:
                host_port = gateway_port
                svc_name = 'nginx'
                container_name = next(
                    (c.get('name', '') for c in running_containers
                     if 'nginx' in (c.get('service') or '').lower()),
                    container_name,
                )
                # The gateway nginx handles all routes internally — no platform-level
                # route_overrides needed (they would conflict with the internal routing).
                effective_routes = []

            seen_domains.add(domain)
            suggestions.append({
                'domain':          domain,
                'upstream_port':   host_port,
                'service_label':   svc_name,
                'container_name':  container_name,
                'route_overrides': effective_routes,
                'include_www':     include_www,
                'ssl':             spec['ssl'],
                'source_file':     source_file,
                'already_exists':  domain in existing_info,
                'vhost_id':        existing_info.get(domain),
                'auto_create':     bool(host_port and domain not in existing_info),
            })

    return suggestions


def auto_detect_and_create_vhosts(app, project_dir: str, project_name: str) -> dict:
    """
    Called after a successful ``deploy_app()``.

    - Scans the repo for nginx configs
    - Matches parsed service names to running container host ports
    - Creates new NginxVhost records for unknown domains (HTTP only — SSL activated from UI)
    - Updates upstream_port / container_name for already-tracked domains and re-writes the conf

    Returns ``{'created': […], 'updated': […], 'skipped': [domain…]}``.
    """
    from apps.nginx_manager.models import NginxVhost
    from apps.stacks.services import get_stack_containers

    parsed_files = scan_project_nginx_configs(project_dir)
    if not parsed_files:
        return {'created': [], 'updated': [], 'skipped': [], 'message': 'No nginx config found in repo.'}

    containers = get_stack_containers(project_name)

    existing_qs = NginxVhost.objects.filter(stack=app)
    existing_by_domain: dict[str, object] = {v.domain: v for v in existing_qs}
    existing_info: dict[str, int] = {v.domain: v.id for v in existing_qs}

    # Detect a gateway nginx: a running nginx container with a non-platform host port
    # (i.e. not 80/443).  Such containers act as internal routers for their compose
    # project.  When found, build_vhost_suggestions uses this port as a fallback upstream
    # for domains whose app service has no direct host-port binding.
    _PLATFORM_PORTS = frozenset({80, 443})
    gateway_port: int | None = None
    for _c in containers:
        if 'nginx' not in (_c.get('service') or '').lower():
            continue
        for _p in (_c.get('ports') or []):
            try:
                _hp = int(_p.get('host_port', 0))
                if _hp and _hp not in _PLATFORM_PORTS:
                    gateway_port = _hp
                    break
            except (TypeError, ValueError):
                pass
        if gateway_port:
            break

    suggestions = build_vhost_suggestions(parsed_files, containers, existing_info, gateway_port=gateway_port)

    created: list[dict] = []
    updated: list[dict] = []
    skipped: list[str] = []

    for s in suggestions:
        domain = s['domain']
        host_port = s['upstream_port']
        route_overrides = s.get('route_overrides') or []
        include_www = s.get('include_www', False)

        if not host_port:
            skipped.append(domain)
            continue

        if domain in existing_by_domain:
            vhost = existing_by_domain[domain]
            port_changed = (vhost.upstream_port != host_port)
            vhost.upstream_port = host_port
            vhost.container_name = s['container_name']
            vhost.route_overrides = route_overrides
            vhost.include_www = include_www
            vhost.save(update_fields=['upstream_port', 'container_name', 'route_overrides', 'include_www'])
            write_vhost(domain, host_port, vhost.ssl_enabled, route_overrides or None, include_www)
            updated.append({'domain': domain, 'upstream_port': host_port, 'port_changed': port_changed,
                            'routes': len(route_overrides)})
        else:
            vhost = NginxVhost.objects.create(
                stack=app,
                domain=domain,
                upstream_port=host_port,
                service_label=s['service_label'][:50],
                container_name=s['container_name'][:255],
                ssl_enabled=False,
                route_overrides=route_overrides,
                include_www=include_www,
            )
            write_vhost(domain, host_port, False, route_overrides or None, include_www)
            created.append({'domain': domain, 'upstream_port': host_port, 'vhost_id': vhost.id,
                            'routes': len(route_overrides)})

    return {'created': created, 'updated': updated, 'skipped': skipped}


