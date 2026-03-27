import os
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')

from django.core.asgi import get_asgi_application

# Initialise Django app registry BEFORE importing anything that touches models/signals.
_django_app = get_asgi_application()

from channels.routing import ProtocolTypeRouter, URLRouter
from channels.auth import AuthMiddlewareStack
import apps.ssh_manager.routing
import apps.stacks.routing
import apps.docker_manager.routing

_ws_patterns = (
    apps.ssh_manager.routing.websocket_urlpatterns
    + apps.stacks.routing.websocket_urlpatterns
    + apps.docker_manager.routing.websocket_urlpatterns
)

application = ProtocolTypeRouter({
    'http': _django_app,
    'websocket': AuthMiddlewareStack(
        URLRouter(_ws_patterns)
    ),
})
