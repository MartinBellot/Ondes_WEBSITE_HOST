"""
GitHub REST API v3 wrapper — uses a Personal Access Token (PAT).
No third-party library needed, just urllib.
"""
import json
import urllib.request
import urllib.error
from typing import Any

_GITHUB_API = 'https://api.github.com'


def _get(path: str, token: str) -> Any:
    url = f'{_GITHUB_API}{path}'
    req = urllib.request.Request(
        url,
        headers={
            'Authorization': f'Bearer {token}',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'Ondes-Dashboard/1.0',
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def get_authenticated_user(token: str) -> dict:
    return _get('/user', token)


def list_repos(token: str, page: int = 1, per_page: int = 50) -> list:
    return _get(f'/user/repos?sort=updated&per_page={per_page}&page={page}', token)


def list_branches(token: str, owner: str, repo: str) -> list:
    return _get(f'/repos/{owner}/{repo}/branches', token)


def get_repo(token: str, owner: str, repo: str) -> dict:
    return _get(f'/repos/{owner}/{repo}', token)
