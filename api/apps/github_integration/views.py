import urllib.error

from rest_framework import status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated

from . import services


class GitHubUserView(APIView):
    """Verify a PAT and return the authenticated GitHub user."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        token = request.data.get('token', '').strip()
        if not token:
            return Response({'error': 'token is required'}, status=status.HTTP_400_BAD_REQUEST)
        try:
            user = services.get_authenticated_user(token)
            return Response({'login': user['login'], 'avatar_url': user.get('avatar_url', '')})
        except urllib.error.HTTPError as e:
            return Response({'error': f'GitHub API error: {e.code}'}, status=status.HTTP_401_UNAUTHORIZED)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)


class GitHubReposView(APIView):
    """List repos accessible with the provided PAT."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        token = request.data.get('token', '').strip()
        page  = int(request.data.get('page', 1))
        if not token:
            return Response({'error': 'token is required'}, status=status.HTTP_400_BAD_REQUEST)
        try:
            repos = services.list_repos(token, page=page)
            return Response([
                {
                    'full_name':    r['full_name'],
                    'name':         r['name'],
                    'description':  r.get('description', ''),
                    'private':      r['private'],
                    'html_url':     r['html_url'],
                    'default_branch': r['default_branch'],
                    'updated_at':   r['updated_at'],
                    'language':     r.get('language', ''),
                }
                for r in repos
            ])
        except urllib.error.HTTPError as e:
            return Response({'error': f'GitHub API error: {e.code}'}, status=e.code)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)


class GitHubBranchesView(APIView):
    """List branches for an owner/repo."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        token = request.data.get('token', '').strip()
        repo  = request.data.get('repo', '').strip()   # 'owner/repo'
        if not token or not repo:
            return Response({'error': 'token and repo are required'}, status=status.HTTP_400_BAD_REQUEST)
        try:
            owner, repo_name = repo.split('/', 1)
            branches = services.list_branches(token, owner, repo_name)
            return Response([b['name'] for b in branches])
        except ValueError:
            return Response({'error': 'repo must be in owner/repo format'}, status=status.HTTP_400_BAD_REQUEST)
        except urllib.error.HTTPError as e:
            return Response({'error': f'GitHub API error: {e.code}'}, status=e.code)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)
