import os
from django.core.asgi import get_asgi_application
from channels.routing import ProtocolTypeRouter, URLRouter
from channels.auth import AuthMiddlewareStack
import apps.ssh_manager.routing
import apps.stacks.routing
import apps.docker_manager.routing

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')

_ws_patterns = (
    apps.ssh_manager.routing.websocket_urlpatterns
    + apps.stacks.routing.websocket_urlpatterns
    + apps.docker_manager.routing.websocket_urlpatterns
)

application = ProtocolTypeRouter({
    'http': get_asgi_application(),
    'websocket': AuthMiddlewareStack(
        URLRouter(_ws_patterns)
    ),
})
