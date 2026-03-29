"""
WebSocket consumer — live container metrics (docker stats).

Frontend connects to: ws://host/ws/metrics/?token=ACCESS_TOKEN

Messages sent every 3 seconds:
  {
    "type": "metrics",
    "containers": [
      {
        "id": "abc123",
        "name": "my_container",
        "status": "running",
        "image": "nginx:latest",
        "cpu_pct": 12.4,
        "mem_pct": 35.1,
        "mem_mb": 128.7,
        "labels": { ... }
      },
      ...
    ]
  }
"""
import asyncio
import json
import os
from concurrent.futures import ThreadPoolExecutor, as_completed

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncWebsocketConsumer
from rest_framework_simplejwt.tokens import AccessToken


def _get_user_id(token_str: str):
    """Validate a JWT access token synchronously (no DB hit) and return user_id."""
    try:
        token = AccessToken(token_str)
        return token['user_id']
    except Exception:
        return None


def _get_docker_client():
    """Return a Docker SDK client, trying fallback sockets for macOS Desktop."""
    import docker
    try:
        return docker.from_env()
    except Exception:
        sockets = [
            os.path.expanduser('~/.docker/run/docker.sock'),
            os.path.expanduser(
                '~/Library/Containers/com.docker.docker/Data/vms/0/docker.sock'
            ),
            '/var/run/docker.sock',
        ]
        for sock in sockets:
            if os.path.exists(sock):
                try:
                    return docker.DockerClient(base_url=f'unix://{sock}')
                except Exception:
                    continue
    return None


def _stats_for_container(c) -> dict:
    """Fetch and parse stats for a single container (blocking, ~1 s per call)."""
    try:
        raw = c.stats(stream=False)

        # ── CPU % ────────────────────────────────────────────────────────────
        cpu_now  = raw['cpu_stats']['cpu_usage']['total_usage']
        cpu_prev = raw['precpu_stats']['cpu_usage']['total_usage']
        sys_now  = raw['cpu_stats'].get('system_cpu_usage', 0)
        sys_prev = raw['precpu_stats'].get('system_cpu_usage', 0)
        num_cpus = raw['cpu_stats'].get('online_cpus', 1)

        cpu_delta = cpu_now  - cpu_prev
        sys_delta = sys_now  - sys_prev
        cpu_pct = 0.0
        if sys_delta > 0 and cpu_delta >= 0:
            cpu_pct = (cpu_delta / sys_delta) * num_cpus * 100.0

        # ── Memory ───────────────────────────────────────────────────────────
        mem       = raw.get('memory_stats', {})
        mem_use   = mem.get('usage', 0)
        mem_cache = mem.get('stats', {}).get('cache', 0)
        mem_real  = max(0, mem_use - mem_cache)
        mem_lim   = mem.get('limit', 1) or 1
        mem_pct   = (mem_real / mem_lim) * 100.0

        return {
            'id':      c.id[:12],
            'name':    c.name,
            'status':  c.status,
            'image':   c.image.tags[0] if c.image.tags else '',
            'cpu_pct': round(cpu_pct,  1),
            'mem_pct': round(mem_pct,  1),
            'mem_mb':  round(mem_real / (1024 * 1024), 1),
            'labels':  dict(c.labels),
        }
    except Exception:
        return {
            'id':      c.id[:12],
            'name':    c.name,
            'status':  c.status,
            'image':   '',
            'cpu_pct': 0.0,
            'mem_pct': 0.0,
            'mem_mb':  0.0,
            'labels':  {},
        }


def _collect_metrics() -> list:
    """Gather cpu/mem stats for every running container **in parallel**.

    docker stats(stream=False) blocks ~1 s per container while the daemon
    collects its CPU delta.  Running all containers concurrently reduces the
    wall-clock time from N×1 s to ~1 s regardless of container count.
    """
    client = _get_docker_client()
    if client is None:
        return []

    try:
        containers = client.containers.list()
    except Exception:
        return []

    if not containers:
        return []

    with ThreadPoolExecutor(max_workers=min(len(containers), 16)) as pool:
        futures = {pool.submit(_stats_for_container, c): c for c in containers}
        result = []
        for fut in as_completed(futures):
            try:
                result.append(fut.result())
            except Exception:
                pass

    return result


class MetricsConsumer(AsyncWebsocketConsumer):
    """Stream live Docker container metrics to an authenticated WebSocket client."""

    async def connect(self):
        from urllib.parse import parse_qs
        qs = parse_qs(self.scope.get('query_string', b'').decode())
        token_str = (qs.get('token', [None]) or [None])[0]

        user_id = _get_user_id(token_str) if token_str else None

        if not user_id:
            # accept() must come before close() to avoid a Daphne protocol deadlock
            await self.accept()
            await self.close(code=4001)
            return

        self._stopped = False
        await self.accept()
        self._task = asyncio.ensure_future(self._stream_loop())

    async def disconnect(self, code):
        self._stopped = True
        if hasattr(self, '_task') and self._task:
            self._task.cancel()

    async def receive(self, text_data):
        try:
            data = json.loads(text_data)
            if data.get('type') == 'ping':
                await self.send(json.dumps({'type': 'pong'}))
        except Exception:
            pass

    async def _stream_loop(self):
        while not self._stopped:
            try:
                metrics = await database_sync_to_async(_collect_metrics)()
                if not self._stopped:
                    await self.send(json.dumps({
                        'type': 'metrics',
                        'containers': metrics,
                    }))
            except Exception:
                pass
            await asyncio.sleep(3)
