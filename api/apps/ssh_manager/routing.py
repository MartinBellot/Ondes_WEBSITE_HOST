from django.urls import re_path
from .consumers import SSHConsumer

websocket_urlpatterns = [
    re_path(r'ws/ssh/$', SSHConsumer.as_asgi()),
]
