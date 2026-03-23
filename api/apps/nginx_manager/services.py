import subprocess
from pathlib import Path

NGINX_SITES_AVAILABLE = Path('/etc/nginx/sites-available')
NGINX_SITES_ENABLED = Path('/etc/nginx/sites-enabled')


def generate_reverse_proxy_config(domain: str, upstream_port: int, ssl: bool = False) -> str:
    if ssl:
        listen_block = (
            f"    listen 443 ssl;\n"
            f"    ssl_certificate /etc/letsencrypt/live/{domain}/fullchain.pem;\n"
            f"    ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;\n"
            f"    ssl_protocols TLSv1.2 TLSv1.3;\n"
            f"    ssl_ciphers HIGH:!aNULL:!MD5;\n"
        )
    else:
        listen_block = "    listen 80;\n"

    return (
        f"server {{\n"
        f"    server_name {domain};\n"
        f"{listen_block}"
        f"\n"
        f"    location / {{\n"
        f"        proxy_pass http://127.0.0.1:{upstream_port};\n"
        f"        proxy_set_header Host $host;\n"
        f"        proxy_set_header X-Real-IP $remote_addr;\n"
        f"        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
        f"        proxy_set_header X-Forwarded-Proto $scheme;\n"
        f"        proxy_http_version 1.1;\n"
        f"        proxy_set_header Upgrade $http_upgrade;\n"
        f"        proxy_set_header Connection \"upgrade\";\n"
        f"    }}\n"
        f"}}\n"
    )


def write_nginx_config(domain: str, config: str) -> dict:
    try:
        config_path = NGINX_SITES_AVAILABLE / domain
        config_path.write_text(config)
        enabled_link = NGINX_SITES_ENABLED / domain
        if not enabled_link.exists():
            enabled_link.symlink_to(config_path)
        _reload_nginx()
        return {'status': 'success', 'path': str(config_path)}
    except PermissionError:
        return {'status': 'error', 'message': 'Permission denied. The API container needs access to /etc/nginx.'}
    except Exception as exc:
        return {'status': 'error', 'message': str(exc)}


def _reload_nginx():
    result = subprocess.run(['nginx', '-s', 'reload'], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"NGINX reload failed: {result.stderr}")


def run_certbot(domain: str, email: str) -> dict:
    try:
        result = subprocess.run(
            [
                'certbot', '--nginx',
                '-d', domain,
                '--email', email,
                '--agree-tos',
                '--non-interactive',
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return {'status': 'success', 'output': result.stdout}
        return {'status': 'error', 'message': result.stderr}
    except FileNotFoundError:
        return {'status': 'error', 'message': 'certbot is not installed on the host'}
    except Exception as exc:
        return {'status': 'error', 'message': str(exc)}
