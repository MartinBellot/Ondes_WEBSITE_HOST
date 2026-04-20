import secrets
import urllib.error
import urllib.parse

from django.conf import settings
from django.core.cache import cache
from django.http import HttpResponse
from django.views import View

from rest_framework import status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated

from .models import GitHubProfile, GitHubOAuthConfig
from . import services


# ── OAuth App configuration (stored in DB, managed from app UI) ───────────────

class GitHubOAuthConfigView(APIView):
    """GET/POST/DELETE the GitHub OAuth App credentials."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        cfg = GitHubOAuthConfig.get()
        callback_url = request.build_absolute_uri('/api/github/oauth/callback/')
        if cfg:
            secret = cfg.decrypted_secret
            hint = secret[:4] + '*' * max(0, len(secret) - 4)
            return Response({
                'configured': True,
                'client_id': cfg.client_id,
                'client_secret_hint': hint,
                'callback_url': callback_url,
                'configured_at': cfg.configured_at,
            })
        return Response({
            'configured': False,
            'callback_url': callback_url,
        })

    def post(self, request):
        client_id = (request.data.get('client_id') or '').strip()
        client_secret = (request.data.get('client_secret') or '').strip()
        if not client_id or not client_secret:
            return Response(
                {'error': 'client_id et client_secret sont requis'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        cfg, _ = GitHubOAuthConfig.objects.update_or_create(
            pk=1,
            defaults={'client_id': client_id, 'client_secret': client_secret},
        )
        return Response({'configured': True, 'client_id': cfg.client_id})

    def delete(self, request):
        GitHubOAuthConfig.objects.all().delete()
        return Response({'configured': False})


# ── OAuth flow ────────────────────────────────────────────────────────────────

class GitHubOAuthStartView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        cfg = GitHubOAuthConfig.get()
        callback_url = request.build_absolute_uri('/api/github/oauth/callback/')
        if not cfg:
            return Response({
                'configured': False,
                'callback_url': callback_url,
            })

        state = secrets.token_urlsafe(32)
        cache.set(f'gh_oauth_{state}', request.user.id, timeout=600)

        params = urllib.parse.urlencode({
            'client_id': cfg.client_id,
            'scope': 'repo read:user',
            'state': state,
        })
        return Response({
            'configured': True,
            'auth_url': f'https://github.com/login/oauth/authorize?{params}',
        })


class GitHubOAuthCallbackView(View):
    """GitHub redirects here — no DRF auth needed, uses state→user_id cache."""

    def get(self, request):
        frontend_url = settings.FRONTEND_URL
        code = request.GET.get('code', '')
        state = request.GET.get('state', '')
        error = request.GET.get('error', '')

        def _page(success, msg=''):
            js = 'true' if success else 'false'
            text = '&#10003; Connexion reussie ! Fermeture...' if success else f'&#10007; Erreur : {msg}'
            html = (
                '<!DOCTYPE html><html><head><meta charset="utf-8"><title>GitHub OAuth</title>'
                '<style>body{font-family:sans-serif;display:flex;align-items:center;'
                'justify-content:center;height:100vh;margin:0;background:#0d1117;'
                'color:#f0f6fc;font-size:18px}</style></head>'
                f'<body><p>{text}</p>'
                '<script>'
                'try{'
                'if(window.opener){'
                f'window.opener.postMessage({{type:"github_oauth",success:{js}}},"{frontend_url}");'
                'setTimeout(function(){window.close();},800);'
                '}else{'
                f'setTimeout(function(){{window.location.href="{frontend_url}";}},1500);'
                '}'
                '}catch(e){'
                f'setTimeout(function(){{window.location.href="{frontend_url}";}},1500);'
                '}'
                '</script></body></html>'
            )
            return HttpResponse(html)

        if error:
            return _page(False, error)
        if not code or not state:
            return _page(False, 'Parametres manquants')

        user_id = cache.get(f'gh_oauth_{state}')
        if not user_id:
            return _page(False, 'Session expiree, veuillez reessayer')

        cache.delete(f'gh_oauth_{state}')

        cfg = GitHubOAuthConfig.get()
        if not cfg:
            return _page(False, 'OAuth non configure')

        try:
            token_data = services.exchange_code_for_token(cfg.client_id, cfg.decrypted_secret, code)
            access_token = token_data.get('access_token', '')
            if not access_token:
                return _page(False, token_data.get('error_description', 'Token manquant'))

            user_info = services.get_authenticated_user(access_token)

            from django.contrib.auth.models import User as DjangoUser
            user = DjangoUser.objects.get(id=user_id)

            GitHubProfile.objects.update_or_create(
                user=user,
                defaults={
                    'login': user_info['login'],
                    'name': user_info.get('name', ''),
                    'avatar_url': user_info.get('avatar_url', ''),
                    'access_token': access_token,
                    'token_scope': token_data.get('scope', ''),
                },
            )
            return _page(True)
        except Exception as exc:
            return _page(False, str(exc))


# ── Profile ───────────────────────────────────────────────────────────────────

class GitHubProfileView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        try:
            p = request.user.github_profile
            return Response({
                'connected': True,
                'login': p.login,
                'name': p.name,
                'avatar_url': p.avatar_url,
                'token_scope': p.token_scope,
                'connected_at': p.connected_at,
            })
        except GitHubProfile.DoesNotExist:
            return Response({'connected': False})

    def delete(self, request):
        try:
            request.user.github_profile.delete()
        except GitHubProfile.DoesNotExist:
            pass
        return Response({'disconnected': True})


# ── Repo browser ──────────────────────────────────────────────────────────────

def _github_http_status(github_code: int) -> int:
    """Map a GitHub API HTTP status to a safe DRF response status.

    GitHub 401 (bad OAuth token) and 403 (rate-limit / forbidden) must NOT be
    forwarded as-is because Dio's JWT interceptor treats any HTTP 401 from the
    backend as an expired JWT and enters an infinite refresh-retry loop.
    Map them to 502 Bad Gateway (our server failed to talk to GitHub).
    """
    if github_code in (401, 403):
        return status.HTTP_502_BAD_GATEWAY
    return github_code


class GitHubReposView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from cryptography.fernet import InvalidToken
        try:
            token = request.user.github_profile.decrypted_token
        except GitHubProfile.DoesNotExist:
            return Response({'error': 'GitHub non connecte'}, status=status.HTTP_403_FORBIDDEN)
        except InvalidToken:
            # SECRET_KEY rotation made the stored OAuth token undecryptable.
            # Tell the client the GitHub connection must be re-established.
            return Response(
                {'error': 'Token GitHub invalide — veuillez reconnecter GitHub'},
                status=status.HTTP_403_FORBIDDEN,
            )

        page = int(request.GET.get('page', 1))
        try:
            repos = services.list_repos(token, page=page)
            return Response([
                {
                    'full_name':        r['full_name'],
                    'name':             r['name'],
                    'owner':            r['owner']['login'],
                    'description':      r.get('description') or '',
                    'private':          r['private'],
                    'html_url':         r['html_url'],
                    'default_branch':   r['default_branch'],
                    'updated_at':       r['updated_at'],
                    'language':         r.get('language') or '',
                    'stargazers_count': r.get('stargazers_count', 0),
                }
                for r in repos
            ])
        except urllib.error.HTTPError as e:
            return Response(
                {'error': f'GitHub API error: {e.code}'},
                status=_github_http_status(e.code),
            )
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)


class GitHubBranchesView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, owner, repo):
        from cryptography.fernet import InvalidToken
        try:
            token = request.user.github_profile.decrypted_token
        except GitHubProfile.DoesNotExist:
            return Response({'error': 'GitHub non connecte'}, status=status.HTTP_403_FORBIDDEN)
        except InvalidToken:
            return Response(
                {'error': 'Token GitHub invalide — veuillez reconnecter GitHub'},
                status=status.HTTP_403_FORBIDDEN,
            )
        try:
            branches = services.list_branches(token, owner, repo)
            return Response([b['name'] for b in branches])
        except urllib.error.HTTPError as e:
            return Response(
                {'error': f'GitHub API error: {e.code}'},
                status=_github_http_status(e.code),
            )
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)


class GitHubComposeFilesView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, owner, repo):
        from cryptography.fernet import InvalidToken
        try:
            token = request.user.github_profile.decrypted_token
        except GitHubProfile.DoesNotExist:
            return Response({'error': 'GitHub non connecte'}, status=status.HTTP_403_FORBIDDEN)
        except InvalidToken:
            return Response(
                {'error': 'Token GitHub invalide — veuillez reconnecter GitHub'},
                status=status.HTTP_403_FORBIDDEN,
            )

        branch = request.GET.get('branch', 'main')
        try:
            compose_files = services.find_compose_files(token, owner, repo, branch)
            env_template = services.detect_env_template(token, owner, repo, branch)
            return Response({'compose_files': compose_files, 'env_template': env_template})
        except urllib.error.HTTPError as e:
            return Response(
                {'error': f'GitHub API error: {e.code}'},
                status=_github_http_status(e.code),
            )
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)

