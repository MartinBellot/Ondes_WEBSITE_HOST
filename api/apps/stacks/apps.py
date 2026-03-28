from django.apps import AppConfig


class StacksConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.stacks'
    verbose_name = 'Compose Stacks'

    def ready(self):
        # On startup, all previous Daphne WebSocket connections are dead.
        # Stale entries in deploy_* Redis groups cause "over capacity" spam that
        # saturates Daphne's event loop.  Flush them once at boot so every deploy
        # starts with a clean group.
        try:
            from django.conf import settings
            import redis as _redis
            cfg = settings.CHANNEL_LAYERS.get('default', {}).get('CONFIG', {})
            hosts = cfg.get('hosts', [])
            if hosts:
                r = _redis.from_url(hosts[0])
                for key in r.scan_iter('asgi:group:deploy_*'):
                    r.delete(key)
        except Exception:
            pass
