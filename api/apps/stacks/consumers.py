"""
WebSocket consumer for real-time deploy logs.

Frontend connects to: ws://host/ws/deploy/{stack_id}/?token=ACCESS_TOKEN

Messages received:
  { "type": "ping" }  — keep-alive

Messages sent:
  { "type": "log",    "message": "...", "level": "info|error|success" }
  { "type": "status", "status": "running|error|...", "message": "..." }
"""
import json

from channels.generic.websocket import AsyncWebsocketConsumer
from channels.db import database_sync_to_async
from rest_framework_simplejwt.tokens import AccessToken
from django.contrib.auth.models import AnonymousUser, User


@database_sync_to_async
def _get_user(token_str: str):
    try:
        token = AccessToken(token_str)
        return User.objects.get(id=token['user_id'])
    except Exception:
        return AnonymousUser()


class DeployConsumer(AsyncWebsocketConsumer):

    async def connect(self):
        from urllib.parse import parse_qs
        qs = parse_qs(self.scope.get('query_string', b'').decode())
        token_str = (qs.get('token', [None]) or [None])[0]

        if token_str:
            self.user = await _get_user(token_str)
        else:
            self.user = self.scope.get('user', AnonymousUser())

        if not self.user or not self.user.is_authenticated:
            # accept() must come before close() to avoid a Daphne protocol deadlock
            await self.accept()
            await self.close(code=4001)
            return

        self.stack_id = self.scope['url_route']['kwargs']['stack_id']
        self.group_name = f'deploy_{self.stack_id}'
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        await self.accept()

    async def disconnect(self, code):
        if hasattr(self, 'group_name'):
            await self.channel_layer.group_discard(self.group_name, self.channel_name)

    async def receive(self, text_data):
        # Only ping/pong keepalives expected from client
        try:
            data = json.loads(text_data)
            if data.get('type') == 'ping':
                await self.send(json.dumps({'type': 'pong'}))
        except Exception:
            pass

    # ── Channel layer message handlers ────────────────────────────────────────

    async def deploy_log(self, event):
        await self.send(text_data=json.dumps({
            'type': 'log',
            'message': event['message'],
            'level': event.get('level', 'info'),
        }))

    async def deploy_status(self, event):
        await self.send(text_data=json.dumps({
            'type': 'status',
            'status': event['status'],
            'message': event.get('message', ''),
        }))
