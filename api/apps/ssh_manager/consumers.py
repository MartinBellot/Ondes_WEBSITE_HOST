import asyncio
import io
import json
import os
import struct
import fcntl
import termios
import pty
import threading

import paramiko
from channels.generic.websocket import AsyncWebsocketConsumer
from rest_framework_simplejwt.tokens import AccessToken
from rest_framework_simplejwt.exceptions import TokenError
import docker


def _authenticate_token(token_str: str):
    """Validate a JWT access token and return the user, or raise TokenError."""
    token = AccessToken(token_str)
    from django.contrib.auth import get_user_model
    User = get_user_model()
    return User.objects.get(pk=token['user_id'])



class SSHConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer that opens a live SSH shell via Paramiko and
    streams I/O in real-time to the frontend.

    Protocol (JSON messages):
      Client → Server:
        { "type": "connect",  "host": "...", "port": 22, "username": "...",
          "password": "...", "private_key": "..." }
        { "type": "input",   "data": "ls -la\n" }
        { "type": "command", "command": "uptime" }   ← fire-and-forget exec

      Server → Client:
        { "type": "connected", "message": "..." }
        { "type": "output",    "data": "..." }
        { "type": "error",     "message": "..." }
    """

    async def connect(self):
        await self.accept()
        self.ssh_client: paramiko.SSHClient | None = None
        self.channel_obj: paramiko.Channel | None = None
        self._reading = False

    async def disconnect(self, close_code):
        self._reading = False
        if self.ssh_client:
            self.ssh_client.close()

    async def receive(self, text_data):
        try:
            data = json.loads(text_data)
        except json.JSONDecodeError:
            return

        msg_type = data.get('type')
        if msg_type == 'connect':
            await self._handle_connect(data)
        elif msg_type == 'input':
            await self._handle_input(data.get('data', ''))
        elif msg_type == 'command':
            await self._handle_command(data.get('command', ''))

    # ──────────────────────────────────────────────────────────────────────────

    async def _handle_connect(self, data: dict):
        host = data.get('host', '')
        port = int(data.get('port', 22))
        username = data.get('username', '')
        password = data.get('password', '')
        private_key_str = data.get('private_key', '')

        if not host or not username:
            await self._send_error('host and username are required')
            return

        try:
            client = paramiko.SSHClient()
            client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

            connect_kwargs: dict = {
                'hostname': host,
                'port': port,
                'username': username,
                'timeout': 10,
            }
            if private_key_str:
                pkey = paramiko.RSAKey.from_private_key(io.StringIO(private_key_str))
                connect_kwargs['pkey'] = pkey
            else:
                connect_kwargs['password'] = password

            loop = asyncio.get_event_loop()
            await loop.run_in_executor(None, lambda: client.connect(**connect_kwargs))

            self.ssh_client = client
            self.channel_obj = client.invoke_shell(term='xterm', width=220, height=50)
            self.channel_obj.setblocking(False)
            self._reading = True

            await self.send(json.dumps({'type': 'connected', 'message': f'Connected to {host}'}))
            asyncio.ensure_future(self._read_loop())

        except paramiko.AuthenticationException:
            await self._send_error('Authentication failed')
        except Exception as exc:
            await self._send_error(str(exc))

    async def _handle_input(self, data: str):
        if self.channel_obj and not self.channel_obj.closed:
            loop = asyncio.get_event_loop()
            await loop.run_in_executor(None, lambda: self.channel_obj.send(data))

    async def _handle_command(self, command: str):
        if not self.ssh_client:
            await self._send_error('Not connected')
            return
        try:
            loop = asyncio.get_event_loop()
            stdin, stdout, stderr = await loop.run_in_executor(
                None, lambda: self.ssh_client.exec_command(command, timeout=30)
            )
            out = await loop.run_in_executor(None, stdout.read)
            err = await loop.run_in_executor(None, stderr.read)
            await self.send(json.dumps({
                'type': 'output',
                'data': out.decode('utf-8', errors='replace') + err.decode('utf-8', errors='replace'),
            }))
        except Exception as exc:
            await self._send_error(str(exc))

    async def _read_loop(self):
        loop = asyncio.get_event_loop()
        while self._reading and self.channel_obj and not self.channel_obj.closed:
            try:
                if self.channel_obj.recv_ready():
                    chunk = await loop.run_in_executor(
                        None, lambda: self.channel_obj.recv(4096)
                    )
                    await self.send(json.dumps({
                        'type': 'output',
                        'data': chunk.decode('utf-8', errors='replace'),
                    }))
                await asyncio.sleep(0.05)
            except Exception:
                break

    async def _send_error(self, message: str):
        await self.send(json.dumps({'type': 'error', 'message': message}))


# ─────────────────────────────────────────────────────────────────────────────
# Docker exec consumer — interactive shell inside a running container
# ─────────────────────────────────────────────────────────────────────────────

class DockerExecConsumer(AsyncWebsocketConsumer):
    """
    Opens an interactive PTY shell inside a Docker container via docker-py's
    exec_run API and streams I/O to the Flutter client.

    URL: ws/exec/<container_id>/?token=ACCESS_TOKEN

    Protocol (JSON):
      Client → Server:
        { "type": "input",  "data": "<text>" }
        { "type": "resize", "cols": 220, "rows": 50 }
      Server → Client:
        { "type": "connected", "message": "..." }
        { "type": "output",    "data": "..." }
        { "type": "error",     "message": "..." }
    """

    async def connect(self):
        # ── JWT auth from query string ────────────────────────────────────────
        qs = self.scope.get('query_string', b'').decode()
        token_str = ''
        for part in qs.split('&'):
            if part.startswith('token='):
                token_str = part[6:]
                break
        try:
            loop = asyncio.get_event_loop()
            await loop.run_in_executor(None, lambda: _authenticate_token(token_str))
        except Exception:
            await self.close(code=4001)
            return

        self._container_id = self.scope['url_route']['kwargs']['container_id']
        self._exec_socket = None
        self._reading = False
        await self.accept()
        await self._start_exec()

    async def disconnect(self, close_code):
        self._reading = False
        if self._exec_socket:
            try:
                self._exec_socket.close()
            except Exception:
                pass

    async def receive(self, text_data):
        try:
            data = json.loads(text_data)
        except json.JSONDecodeError:
            return
        msg_type = data.get('type')
        if msg_type == 'input':
            await self._send_input(data.get('data', ''))
        elif msg_type == 'resize':
            await self._resize(int(data.get('cols', 220)), int(data.get('rows', 50)))

    # ─────────────────────────────────────────────────────────────────────────

    async def _start_exec(self):
        loop = asyncio.get_event_loop()
        try:
            def _open():
                client = docker.from_env()
                container = client.containers.get(self._container_id)
                # Probe for a shell — prefer bash, fall back to sh
                shells = ['/bin/bash', '/bin/sh']
                shell = '/bin/sh'
                for s in shells:
                    probe = container.exec_run(f'test -x {s}', demux=False)
                    if probe.exit_code == 0:
                        shell = s
                        break
                exec_id = client.api.exec_create(
                    container.id,
                    [shell],
                    stdin=True,
                    tty=True,
                    stdout=True,
                    stderr=True,
                )
                sock = client.api.exec_start(
                    exec_id,
                    detach=False,
                    tty=True,
                    socket=True,
                )
                # docker-py wraps the socket in a SocketIO on some versions;
                # unwrap to get the real socket for makefile / settimeout.
                raw = getattr(sock, '_sock', sock)
                raw.settimeout(0.05)
                return raw, container.name

            self._exec_socket, cname = await loop.run_in_executor(None, _open)
            self._reading = True
            await self.send(json.dumps({
                'type': 'connected',
                'message': f'Shell ouvert dans {cname}',
            }))
            asyncio.ensure_future(self._read_loop())
        except Exception as exc:
            await self.send(json.dumps({'type': 'error', 'message': str(exc)}))
            await self.close()

    async def _read_loop(self):
        import socket as _socket
        loop = asyncio.get_event_loop()
        while self._reading and self._exec_socket:
            try:
                chunk = await loop.run_in_executor(None, self._exec_socket.recv, 4096)
                if not chunk:
                    break
                await self.send(json.dumps({
                    'type': 'output',
                    'data': chunk.decode('utf-8', errors='replace'),
                }))
            except _socket.timeout:
                continue
            except Exception:
                break
        self._reading = False
        if self.channel_layer:
            pass  # no group to leave
        await self.send(json.dumps({'type': 'output', 'data': '\r\nSession terminée.\r\n'}))

    async def _send_input(self, data: str):
        if self._exec_socket:
            loop = asyncio.get_event_loop()
            try:
                await loop.run_in_executor(
                    None, lambda: self._exec_socket.send(data.encode('utf-8', errors='replace'))
                )
            except Exception:
                pass

    async def _resize(self, cols: int, rows: int):
        # PTY resize via docker-py low-level API is not straightforward;
        # the exec socket is a raw socket. We skip resize for now — the
        # terminal still works, just at fixed 220×50.
        pass

