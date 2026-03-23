import asyncio
import io
import json

import paramiko
from channels.generic.websocket import AsyncWebsocketConsumer


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
