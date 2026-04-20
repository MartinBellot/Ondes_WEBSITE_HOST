from django.urls import re_path
from .consumers import MetricsConsumer, ExecConsumer

websocket_urlpatterns = [
    re_path(r'^ws/metrics/$', MetricsConsumer.as_asgi()),
    re_path(r'^ws/exec/(?P<container_id>[\w-]+)/$', ExecConsumer.as_asgi()),
]
