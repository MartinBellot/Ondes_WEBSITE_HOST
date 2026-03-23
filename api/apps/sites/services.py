import os
import shutil
import subprocess
import tempfile

import docker
from docker.errors import APIError

from .models import Site


def deploy_site(site: Site) -> dict:
    """
    Full deploy pipeline:
      1. Clone the GitHub repo
      2. Detect project type
      3. Build Docker image
      4. Run container with correct port mapping
    """
    site.status = 'deploying'
    site.save(update_fields=['status'])

    try:
        workdir = tempfile.mkdtemp(prefix=f'ondes_{site.name}_')
        _clone_repo(site, workdir)

        project_type = _detect_project_type(workdir)
        _ensure_dockerfile(workdir, project_type)

        image_tag = f'ondes_{site.name.lower().replace(" ", "_")}:latest'
        _docker_build(workdir, image_tag)

        container_name = f'ondes_site_{site.name.lower().replace(" ", "_")}'
        port = site.web_port or _find_free_port()

        _stop_and_remove_if_exists(container_name)
        _docker_run(image_tag, container_name, port)

        site.web_container_name = container_name
        site.web_port = port
        site.status = 'running'
        site.save(update_fields=['web_container_name', 'web_port', 'status'])

        return {'status': 'success', 'container': container_name, 'port': port}

    except Exception as exc:
        site.status = 'error'
        site.save(update_fields=['status'])
        return {'status': 'error', 'message': str(exc)}

    finally:
        if 'workdir' in dir():
            shutil.rmtree(workdir, ignore_errors=True)


def _clone_repo(site: Site, dest: str):
    """Clone using HTTPS with token auth."""
    repo = site.github_repo.strip('/')
    token = site.github_token
    branch = site.github_branch or 'main'

    if token:
        url = f'https://{token}@github.com/{repo}.git'
    else:
        url = f'https://github.com/{repo}.git'

    result = subprocess.run(
        ['git', 'clone', '--depth', '1', '--branch', branch, url, dest],
        capture_output=True, text=True, timeout=120,
    )
    if result.returncode != 0:
        raise RuntimeError(f'git clone failed: {result.stderr}')


def _detect_project_type(path: str) -> str:
    if os.path.exists(os.path.join(path, 'Dockerfile')):
        return 'dockerfile'
    if os.path.exists(os.path.join(path, 'package.json')):
        return 'node'
    if os.path.exists(os.path.join(path, 'requirements.txt')):
        return 'python'
    if os.path.exists(os.path.join(path, 'go.mod')):
        return 'go'
    return 'static'


def _ensure_dockerfile(path: str, project_type: str):
    """Write a sensible Dockerfile if one doesn't exist."""
    dockerfile = os.path.join(path, 'Dockerfile')
    if os.path.exists(dockerfile):
        return

    templates = {
        'node': (
            'FROM node:20-alpine\nWORKDIR /app\n'
            'COPY package*.json ./\nRUN npm ci --omit=dev\n'
            'COPY . .\nRUN npm run build 2>/dev/null || true\n'
            'EXPOSE 3000\nCMD ["node", "index.js"]\n'
        ),
        'python': (
            'FROM python:3.12-slim\nWORKDIR /app\n'
            'COPY requirements.txt .\nRUN pip install --no-cache-dir -r requirements.txt\n'
            'COPY . .\nEXPOSE 8000\n'
            'CMD ["python", "-m", "gunicorn", "app:app", "--bind", "0.0.0.0:8000"]\n'
        ),
        'go': (
            'FROM golang:1.22-alpine AS builder\nWORKDIR /app\n'
            'COPY . .\nRUN go build -o server .\n'
            'FROM alpine:latest\nCOPY --from=builder /app/server /server\n'
            'EXPOSE 8080\nCMD ["/server"]\n'
        ),
        'static': (
            'FROM nginx:alpine\nCOPY . /usr/share/nginx/html\nEXPOSE 80\n'
        ),
    }
    content = templates.get(project_type, templates['static'])
    with open(dockerfile, 'w') as f:
        f.write(content)


def _docker_build(path: str, tag: str):
    client = docker.from_env()
    client.images.build(path=path, tag=tag, rm=True)


def _docker_run(image_tag: str, container_name: str, host_port: int):
    client = docker.from_env()
    # Detect exposed port from image
    image = client.images.get(image_tag)
    exposed = list(image.attrs.get('Config', {}).get('ExposedPorts', {}).keys())
    container_port = exposed[0].split('/')[0] if exposed else '80'

    client.containers.run(
        image=image_tag,
        name=container_name,
        ports={f'{container_port}/tcp': host_port},
        detach=True,
        restart_policy={'Name': 'unless-stopped'},
    )


def _stop_and_remove_if_exists(name: str):
    client = docker.from_env()
    try:
        container = client.containers.get(name)
        container.stop()
        container.remove()
    except docker.errors.NotFound:
        pass


def _find_free_port() -> int:
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(('', 0))
        return s.getsockname()[1]
