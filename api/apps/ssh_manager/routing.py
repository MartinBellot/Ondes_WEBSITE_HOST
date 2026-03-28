from django.urls import re_path
from .consumers import SSHConsumer, DockerExecConsumer

websocket_urlpatterns = [
    re_path(r'ws/ssh/$', SSHConsumer.as_asgi()),
    re_path(r'ws/exec/(?P<container_id>[^/]+)/$', DockerExecConsumer.as_asgi()),
]
