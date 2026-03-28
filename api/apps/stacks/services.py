"""
Deploy pipeline for ComposeApp:
  1. Clone the GitHub repo using the user's stored OAuth token
  2. Write a .env file from app.env_vars
  3. Run `docker compose up -d --build`
  4. Stream logs in real-time via Django Channels groups

Each log line is broadcast to group `deploy_{app_id}` so the WebSocket
consumer can forward it to the connected client.
"""
import os
import shutil
import subprocess
import tempfile
import threading
from datetime import datetime, timezone

import docker as _docker_sdk

from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer

from .models import ComposeApp

# Persistent base directory for cloned repos.
# Overridable via env var; defaults to /app/stacks-data which is expected
# to be a named volume so repos survive container restarts.
_STACKS_DATA_DIR = os.environ.get('STACKS_DATA_DIR', '/app/stacks-data')

# Compose bypass — pyyaml is an explicit dependency (see requirements.txt)
try:
    import yaml
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

# Service names or image fragments that should be bypassed on user repos
# because the platform provides its own managed nginx + certbot.
_BYPASS_SERVICE_NAMES = frozenset({'nginx', 'certbot', 'certbot-companion', 'letsencrypt'})
_BYPASS_IMAGE_FRAGMENTS = ('nginx', 'certbot')

_ONDES_COMPOSE_FILE = 'docker-compose.ondes.yml'


def _resolve_compose_file(app: 'ComposeApp') -> str:
    """Return the effective compose filename to use for docker compose commands.

    After a successful deploy, ``_strip_platform_services`` may have written a
    trimmed copy as ``docker-compose.ondes.yml``.  Subsequent stop / start /
    restart / get_logs calls must use that file so Docker Compose targets the
    same project state.
    """
    if app.project_dir:
        ondes_path = os.path.join(app.project_dir, _ONDES_COMPOSE_FILE)
        if os.path.isfile(ondes_path):
            return _ONDES_COMPOSE_FILE
    return app.compose_file

# Host ports claimed by the Ondes HOST platform NGINX container.
# A user nginx binding these ports conflicts → strip it.
# A user nginx binding any OTHER port is an internal gateway router → keep it.
_PLATFORM_PORTS = frozenset({80, 443})


def _nginx_gateway_host_port(service_def: dict) -> int | None:
    """
    Return the non-platform host port bound by a nginx-like service, or None.

    A nginx service publishing e.g. ``"8081:80"`` is acting as an internal
    gateway router for its own compose project.  The platform must NOT strip
    it — instead it wraps around it by proxying to host port 8081.
    Returns None when the service has no host-port binding or only binds
    platform ports (80/443).
    """
    ports = service_def.get('ports') or []
    for spec in ports:
        if isinstance(spec, str):
            host_part = spec.split(':')[0] if ':' in spec else spec
            try:
                hp = int(host_part.strip())
                if hp not in _PLATFORM_PORTS:
                    return hp
            except ValueError:
                pass
        elif isinstance(spec, dict):
            published = spec.get('published') or spec.get('target')
            try:
                hp = int(published)
                if hp not in _PLATFORM_PORTS:
                    return hp
            except (TypeError, ValueError):
                pass
    return None


def _is_managed_by_platform(service_name: str, service_def: dict) -> bool:
    """
    Return True if this service should be removed (nginx / certbot handled by core).

    A nginx-like service is stripped ONLY when it would conflict with the
    platform NGINX (i.e. it binds host port 80 or 443, or has no host-port
    binding at all).  A gateway nginx that exposes a custom port (e.g. 8081)
    to allow the platform to proxy into the compose project is preserved.
    """
    is_nginx_like = (
        service_name.lower() in _BYPASS_SERVICE_NAMES
        or any(frag in (service_def.get('image') or '').lower() for frag in _BYPASS_IMAGE_FRAGMENTS)
    )
    if not is_nginx_like:
        return False
    # Keep gateway nginx (custom host port) — only strip if it claims 80/443 or has no port.
    return _nginx_gateway_host_port(service_def) is None


def _strip_platform_services(compose_path: str, app_id: int) -> tuple[str, list[str]]:
    """
    Parse *compose_path*, remove nginx / certbot services (managed by the platform),
    and write the modified compose to <dir>/docker-compose.ondes.yml.

    Returns (effective_compose_filename, removed_service_names).
    If yaml is unavailable or parsing fails, returns the original filename unchanged.
    """
    if not _YAML_AVAILABLE:
        _broadcast(
            app_id,
            '⚠️  pyyaml non disponible — impossible de supprimer automatiquement '
            'les services nginx/certbot du compose. Installez pyyaml dans le venv.',
            'warning',
        )
        return os.path.basename(compose_path), []

    try:
        with open(compose_path) as f:
            data = yaml.safe_load(f)
    except Exception as exc:
        _broadcast(app_id, f'⚠️  Lecture du compose échouée ({exc}) — bypass ignoré.', 'warning')
        return os.path.basename(compose_path), []

    if not isinstance(data, dict) or 'services' not in data:
        return os.path.basename(compose_path), []

    services = data.get('services') or {}
    removed: list[str] = []

    for svc_name in list(services.keys()):
        svc_def = services[svc_name] or {}
        if _is_managed_by_platform(svc_name, svc_def):
            del services[svc_name]
            removed.append(svc_name)

    if not removed:
        return os.path.basename(compose_path), []

    # Clean up depends_on references pointing to removed services
    for svc_def in services.values():
        if not isinstance(svc_def, dict):
            continue
        dep = svc_def.get('depends_on')
        if isinstance(dep, list):
            svc_def['depends_on'] = [d for d in dep if d not in removed]
            if not svc_def['depends_on']:
                del svc_def['depends_on']
        elif isinstance(dep, dict):
            for r in removed:
                dep.pop(r, None)
            if not dep:
                del svc_def['depends_on']

    data['services'] = services
    bypass_filename  = 'docker-compose.ondes.yml'
    bypass_path      = os.path.join(os.path.dirname(compose_path), bypass_filename)
    try:
        with open(bypass_path, 'w') as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
    except Exception as exc:
        _broadcast(app_id, f'⚠️  Écriture du compose modifié échouée ({exc}) — compose original utilisé.', 'warning')
        return os.path.basename(compose_path), []

    return bypass_filename, removed


def _flush_deploy_group(app_id: int):
    """Delete stale channels from the Redis deploy group before a new deploy.

    Zombie channels accumulate when Daphne kills WebSocket connections without
    running disconnect() (e.g. client tab closed mid-deploy).  Clearing the
    group key at the very start of each deploy ensures group_send only reaches
    live consumers, preventing 'over capacity' log spam that can saturate
    Daphne's event loop.
    """
    try:
        from django.conf import settings
        import redis as _redis
        redis_url = settings.CHANNEL_LAYERS['default']['CONFIG']['hosts'][0]
        r = _redis.from_url(redis_url)
        r.delete(f'asgi:group:deploy_{app_id}')
    except Exception:
        pass


def _broadcast(app_id: int, message: str, level: str = 'info'):
    """Send a log line to the WebSocket group for this deploy."""
    try:
        layer = get_channel_layer()
        async_to_sync(layer.group_send)(
            f'deploy_{app_id}',
            {'type': 'deploy.log', 'message': message, 'level': level},
        )
    except Exception:
        pass  # Channel layer may not be available in some test contexts


def _set_status(app: ComposeApp, s: str, msg: str = ''):
    app.status = s
    app.status_message = msg
    app.save(update_fields=['status', 'status_message'])
    try:
        layer = get_channel_layer()
        async_to_sync(layer.group_send)(
            f'deploy_{app.id}',
            {'type': 'deploy.status', 'status': s, 'message': msg},
        )
    except Exception:
        pass


def _run_streaming(cmd: list, cwd: str, app_id: int, env: dict | None = None) -> int:
    """Run a subprocess and broadcast each output line to the WebSocket group."""
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    for line in proc.stdout:
        _broadcast(app_id, line.rstrip())
    proc.wait()
    return proc.returncode


def deploy_app(app_id: int):
    """
    Entry point called from the view in a background thread.
    Fetches a fresh copy of the app from DB (thread-safe).
    """
    app = ComposeApp.objects.select_related('user__github_profile').get(pk=app_id)

    try:
        token = app.user.github_profile.access_token
    except Exception:
        _set_status(app, 'error', 'Compte GitHub non connecté — connectez GitHub d\'abord.')
        _broadcast(app_id, '❌ Compte GitHub non connecté.', 'error')
        return

    project_dir = app.project_dir
    if not project_dir:
        os.makedirs(_STACKS_DATA_DIR, exist_ok=True)
        project_dir = os.path.join(_STACKS_DATA_DIR, f'ondes_{app.id}_{app.name.lower().replace(" ", "_")[:20]}')
    app.project_dir = project_dir
    app.save(update_fields=['project_dir'])

    _broadcast(app_id, f'🚀 Démarrage du déploiement de {app.name}...')

    # ── 1. Clone / pull ───────────────────────────────────────────────────────
    _set_status(app, 'cloning', 'Clonage du dépôt GitHub...')
    repo = app.github_repo.strip('/')
    branch = app.github_branch or 'main'
    clone_url = f'https://{token}@github.com/{repo}.git'

    if os.path.exists(os.path.join(project_dir, '.git')):
        _broadcast(app_id, f'📦 Mise à jour du dépôt (git pull origin {branch})...')
        rc = _run_streaming(
            ['git', 'pull', 'origin', branch],
            cwd=project_dir,
            app_id=app_id,
        )
    else:
        _broadcast(app_id, f'📦 Clonage de {repo}@{branch}...')
        # Clean dir before cloning
        if os.path.exists(project_dir):
            shutil.rmtree(project_dir)
        rc = _run_streaming(
            ['git', 'clone', '--depth', '1', '--branch', branch, clone_url, project_dir],
            cwd=tempfile.gettempdir(),
            app_id=app_id,
        )

    if rc != 0:
        _set_status(app, 'error', 'Échec du clonage — vérifiez le nom du dépôt et vos permissions GitHub.')
        _broadcast(app_id, '❌ Clonage échoué.', 'error')
        return

    _broadcast(app_id, '✅ Dépôt cloné avec succès.')

    # Capture the deployed commit SHA
    try:
        sha_result = subprocess.run(
            ['git', 'rev-parse', 'HEAD'],
            cwd=project_dir, capture_output=True, text=True,
        )
        if sha_result.returncode == 0:
            commit_sha = sha_result.stdout.strip()
            app.current_commit_sha = commit_sha
            app.save(update_fields=['current_commit_sha'])
            _broadcast(app_id, f'📌 Commit déployé : {commit_sha[:8]}')
    except Exception:
        pass

    # ── 2. Write .env ─────────────────────────────────────────────────────────
    if app.env_vars:
        env_path = os.path.join(project_dir, '.env')
        _broadcast(app_id, f'📝 Écriture du fichier .env ({len(app.env_vars)} variables)...')
        with open(env_path, 'w') as f:
            for k, v in app.env_vars.items():
                f.write(f'{k}={v}\n')

    # ── 3. docker compose up ──────────────────────────────────────────────────
    compose_path = os.path.join(project_dir, app.compose_file)
    if not os.path.exists(compose_path):
        _set_status(app, 'error', f'Fichier {app.compose_file} introuvable dans le dépôt.')
        _broadcast(app_id, f'❌ {app.compose_file} introuvable.', 'error')
        return

    # ── 3a. Bypass nginx / certbot services (platform manages them) ───────────
    effective_compose, stripped = _strip_platform_services(compose_path, app_id)
    if stripped:
        stripped_names = ', '.join(stripped)
        _broadcast(
            app_id,
            '\u26a0\ufe0f  Services g\u00e9r\u00e9s par la plateforme d\u00e9tect\u00e9s et ignor\u00e9s : '
            + stripped_names + '. '
            'Utilisez l\'onglet "Domaine & SSL" pour configurer NGINX et SSL.',
            'warning',
        )
        _broadcast(app_id, f'\ud83d\udcdd Compose modifi\u00e9 \u00e9crit dans {effective_compose}.')

    _set_status(app, 'building', 'Build et démarrage des containers...')
    _broadcast(app_id, f'🐳 Lancement de docker compose -f {effective_compose} up -d --build...')

    # Use a unique project name to avoid collisions between apps
    project_name = f'ondes_{app.id}_{app.name.lower().replace(" ", "_")}'

    rc = _run_streaming(
        ['docker', 'compose', '-f', effective_compose, '-p', project_name, 'up', '-d', '--build'],
        cwd=project_dir,
        app_id=app_id,
    )

    if rc != 0:
        _set_status(app, 'error', 'docker compose up a échoué — consultez les logs ci-dessus.')
        _broadcast(app_id, '❌ Déploiement échoué.', 'error')
        return

    app.status = 'running'
    app.status_message = ''
    app.last_deployed_at = datetime.now(tz=timezone.utc)
    app.save(update_fields=['status', 'status_message', 'last_deployed_at'])

    _broadcast(app_id, '🎉 Déploiement réussi ! Tous les containers sont démarrés.', 'success')
    _set_status(app, 'running')

    # ── 4. Auto-detect nginx vhosts from repo configs ─────────────────────────
    try:
        from apps.nginx_manager.services import auto_detect_and_create_vhosts
        detect = auto_detect_and_create_vhosts(app, project_dir, project_name)
        if detect.get('created'):
            _broadcast(app_id, f"🌐 {len(detect['created'])} VHost(s) NGINX détecté(s) et configuré(s).", 'success')
        if detect.get('updated'):
            _broadcast(app_id, f"🔄 {len(detect['updated'])} VHost(s) NGINX mis à jour depuis la config repo.")
        if detect.get('message'):
            pass  # No nginx config found — silent
    except Exception as _e:
        _broadcast(app_id, f'⚠️  Détection auto VHosts NGINX : {_e}', 'warning')


def _stop_containers_by_project(project_name: str) -> bool:
    """Stop all running containers of a compose project via Docker SDK (no compose file needed)."""
    try:
        client = _docker_sdk.from_env()
        containers = client.containers.list(
            filters={'label': f'com.docker.compose.project={project_name}', 'status': 'running'}
        )
        for c in containers:
            c.stop(timeout=30)
        return True
    except Exception:
        return False


def _start_containers_by_project(project_name: str) -> bool:
    """Start all stopped containers of a compose project via Docker SDK (no compose file needed)."""
    try:
        client = _docker_sdk.from_env()
        containers = client.containers.list(
            all=True,
            filters={'label': f'com.docker.compose.project={project_name}', 'status': 'exited'}
        )
        for c in containers:
            c.start()
        return True
    except Exception:
        return False


def stop_app(app_id: int):
    app = ComposeApp.objects.get(pk=app_id)
    project_name = f'ondes_{app.id}_{app.name.lower().replace(" ", "_")}'

    _set_status(app, 'stopping')

    if not app.project_dir or not os.path.exists(app.project_dir):
        # project_dir missing (e.g. /tmp cleared after restart) — fall back to Docker SDK
        if _stop_containers_by_project(project_name):
            _set_status(app, 'stopped')
            return {'status': 'stopped'}
        _set_status(app, 'error', 'Répertoire du projet introuvable et aucun container actif trouvé.')
        return {'error': 'Répertoire du projet introuvable et aucun container actif trouvé.'}

    try:
        result = subprocess.run(
            ['docker', 'compose', '-f', _resolve_compose_file(app), '-p', project_name, 'stop'],
            cwd=app.project_dir,
            capture_output=True, text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        _set_status(app, 'error', 'Timeout : docker compose stop a dépassé 120 s.')
        return {'error': 'Timeout'}
    if result.returncode == 0:
        _set_status(app, 'stopped')
        return {'status': 'stopped'}
    _set_status(app, 'error', result.stderr[:200])
    return {'error': result.stderr}


def start_app(app_id: int):
    app = ComposeApp.objects.get(pk=app_id)
    project_name = f'ondes_{app.id}_{app.name.lower().replace(" ", "_")}'

    _set_status(app, 'starting')

    if not app.project_dir or not os.path.exists(app.project_dir):
        # project_dir missing — try Docker SDK first, else trigger full re-deploy
        if _start_containers_by_project(project_name):
            _set_status(app, 'running')
            return {'status': 'running'}
        # No containers exist at all — need a full re-deploy
        threading.Thread(target=deploy_app, args=(app_id,), daemon=True).start()
        return {'status': 'deploying'}

    try:
        result = subprocess.run(
            ['docker', 'compose', '-f', _resolve_compose_file(app), '-p', project_name, 'start'],
            cwd=app.project_dir,
            capture_output=True, text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        _set_status(app, 'error', 'Timeout : docker compose start a dépassé 120 s.')
        return {'error': 'Timeout'}
    if result.returncode == 0:
        _set_status(app, 'running')
        return {'status': 'running'}
    _set_status(app, 'error', result.stderr[:200])
    return {'error': result.stderr}


def restart_app(app_id: int):
    app = ComposeApp.objects.get(pk=app_id)
    project_name = f'ondes_{app.id}_{app.name.lower().replace(" ", "_")}'

    _set_status(app, 'starting')

    if not app.project_dir or not os.path.exists(app.project_dir):
        # Fall back to Docker SDK stop+start
        _stop_containers_by_project(project_name)
        if _start_containers_by_project(project_name):
            _set_status(app, 'running')
            return {'status': 'running'}
        _set_status(app, 'error', 'Répertoire du projet introuvable et aucun container trouvé.')
        return {'error': 'Répertoire du projet introuvable et aucun container trouvé.'}

    try:
        result = subprocess.run(
            ['docker', 'compose', '-f', _resolve_compose_file(app), '-p', project_name, 'restart'],
            cwd=app.project_dir,
            capture_output=True, text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        _set_status(app, 'error', 'Timeout : docker compose restart a dépassé 120 s.')
        return {'error': 'Timeout'}
    if result.returncode == 0:
        _set_status(app, 'running')
        return {'status': 'running'}
    _set_status(app, 'error', result.stderr[:200])
    return {'error': result.stderr}


def remove_app(app_id: int):
    """docker compose down + cleanup of the cloned directory."""
    app = ComposeApp.objects.get(pk=app_id)
    project_name = f'ondes_{app.id}_{app.name.lower().replace(" ", "_")}'

    if app.project_dir and os.path.exists(app.project_dir):
        subprocess.run(
            ['docker', 'compose', '-f', _resolve_compose_file(app), '-p', project_name, 'down', '--volumes'],
            cwd=app.project_dir,
            capture_output=True,
        )
        shutil.rmtree(app.project_dir, ignore_errors=True)

    app.delete()
    return {'status': 'removed'}


def get_stack_containers(project_name: str) -> list[dict]:
    """
    Return running containers for a given compose project with host port bindings.
    Used by the 'Domaine & SSL' tab to let the user pick a container instead of
    manually entering the upstream port.
    """
    try:
        client = _docker_sdk.from_env()
        raw = client.containers.list(
            filters={'label': f'com.docker.compose.project={project_name}'}
        )
        result = []
        for c in raw:
            ports = []
            for container_port, bindings in (c.ports or {}).items():
                if not bindings:
                    continue
                # Docker SDK returns keys like '80/tcp' — keep only the numeric part
                cp_str = container_port.split('/')[0] if container_port else container_port
                try:
                    cp_int = int(cp_str)
                except (ValueError, TypeError):
                    cp_int = 0
                for b in bindings:
                    try:
                        hp = int(b.get('HostPort', 0))
                    except (ValueError, TypeError):
                        continue
                    if hp:
                        ports.append({
                            'container_port': cp_int,
                            'host_port': hp,
                        })
            result.append({
                'id': c.short_id,
                'name': c.name,
                'service': c.labels.get('com.docker.compose.service', c.name),
                'image': c.image.tags[0] if c.image.tags else c.image.short_id,
                'status': c.status,
                'ports': ports,
            })
        return result
    except Exception:
        return []


def get_logs(app_id: int, lines: int = 200) -> str:
    """Return recent logs from all containers in the compose project."""
    app = ComposeApp.objects.get(pk=app_id)
    if not app.project_dir or not os.path.exists(app.project_dir):
        return 'Aucun répertoire de projet trouvé.'

    project_name = f'ondes_{app.id}_{app.name.lower().replace(" ", "_")}'
    result = subprocess.run(
        ['docker', 'compose', '-f', _resolve_compose_file(app), '-p', project_name,
         'logs', '--tail', str(lines), '--no-color'],
        cwd=app.project_dir,
        capture_output=True, text=True,
    )
    return result.stdout + result.stderr
