import threading

from rest_framework import generics, status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated

from .models import ComposeApp
from .serializers import ComposeAppSerializer, ComposeAppCreateSerializer
from . import services


class ComposeAppListCreateView(generics.ListCreateAPIView):
    permission_classes = [IsAuthenticated]

    def get_serializer_class(self):
        return ComposeAppCreateSerializer if self.request.method == 'POST' else ComposeAppSerializer

    def get_queryset(self):
        return ComposeApp.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        serializer.save(user=self.request.user)

    def create(self, request, *args, **kwargs):
        write_serializer = ComposeAppCreateSerializer(data=request.data)
        write_serializer.is_valid(raise_exception=True)
        instance = write_serializer.save(user=request.user)
        # Return the full object (including id) so the client can use it immediately.
        read_serializer = ComposeAppSerializer(instance)
        return Response(read_serializer.data, status=status.HTTP_201_CREATED)


class ComposeAppDetailView(generics.RetrieveUpdateDestroyAPIView):
    permission_classes = [IsAuthenticated]

    def get_serializer_class(self):
        return ComposeAppCreateSerializer if self.request.method in ('PUT', 'PATCH') else ComposeAppSerializer

    def get_queryset(self):
        return ComposeApp.objects.filter(user=self.request.user)

    def destroy(self, request, *args, **kwargs):
        instance = self.get_object()
        try:
            services.remove_app(instance.id)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)
        return Response(status=status.HTTP_204_NO_CONTENT)


class ComposeAppDeployView(APIView):
    """Kick off a fresh deploy. Runs in a background thread; responds immediately."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        app = ComposeApp.objects.filter(pk=pk, user=request.user).first()
        if not app:
            return Response({'error': 'Projet introuvable'}, status=status.HTTP_404_NOT_FOUND)
        if app.status in ('cloning', 'building', 'starting'):
            return Response({'error': 'Un déploiement est déjà en cours'}, status=status.HTTP_409_CONFLICT)

        threading.Thread(target=services.deploy_app, args=(app.id,), daemon=True).start()
        return Response({'status': 'deploying', 'app_id': app.id})


class ComposeAppActionView(APIView):
    """start | stop | restart"""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk, action):
        app = ComposeApp.objects.filter(pk=pk, user=request.user).first()
        if not app:
            return Response({'error': 'Projet introuvable'}, status=status.HTTP_404_NOT_FOUND)

        if action == 'start':
            threading.Thread(target=services.start_app, args=(app.id,), daemon=True).start()
            return Response({'status': 'starting'})
        elif action == 'stop':
            threading.Thread(target=services.stop_app, args=(app.id,), daemon=True).start()
            return Response({'status': 'stopping'})
        elif action == 'restart':
            threading.Thread(target=services.restart_app, args=(app.id,), daemon=True).start()
            return Response({'status': 'starting'})
        else:
            return Response({'error': 'Action invalide'}, status=status.HTTP_400_BAD_REQUEST)


class ComposeAppLogsView(APIView):
    """Return recent container logs for a stack."""
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        app = ComposeApp.objects.filter(pk=pk, user=request.user).first()
        if not app:
            return Response({'error': 'Projet introuvable'}, status=status.HTTP_404_NOT_FOUND)
        lines = int(request.GET.get('lines', 200))
        logs = services.get_logs(app.id, lines)
        return Response({'logs': logs})


class ComposeAppEnvView(APIView):
    """GET / PATCH env vars for a stack."""
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        app = ComposeApp.objects.filter(pk=pk, user=request.user).first()
        if not app:
            return Response({'error': 'Projet introuvable'}, status=status.HTTP_404_NOT_FOUND)
        return Response({'env_vars': app.env_vars})

    def patch(self, request, pk):
        app = ComposeApp.objects.filter(pk=pk, user=request.user).first()
        if not app:
            return Response({'error': 'Projet introuvable'}, status=status.HTTP_404_NOT_FOUND)

        env = request.data.get('env_vars')
        if not isinstance(env, dict):
            return Response({'error': 'env_vars must be a JSON object'}, status=status.HTTP_400_BAD_REQUEST)

        # Basic key validation — only allow safe env var names
        for key in env:
            if not key.replace('_', '').isalnum():
                return Response(
                    {'error': f'Nom de variable invalide : {key}'},
                    status=status.HTTP_400_BAD_REQUEST,
                )

        app.env_vars = env
        app.save(update_fields=['env_vars'])
        return Response({'env_vars': app.env_vars})


class ComposeAppVhostsView(APIView):
    """
    GET  /api/stacks/{id}/vhosts/  — list nginx vhosts for a stack
    Shortcut that delegates to the nginx_manager data joined by stack FK.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        app = ComposeApp.objects.filter(pk=pk, user=request.user).first()
        if not app:
            return Response({'error': 'Projet introuvable'}, status=status.HTTP_404_NOT_FOUND)
        from apps.nginx_manager.models import NginxVhost
        from apps.nginx_manager.serializers import NginxVhostSerializer
        vhosts = NginxVhost.objects.filter(stack=app)
        return Response(NginxVhostSerializer(vhosts, many=True).data)


class ComposeAppContainersView(APIView):
    """
    GET /api/stacks/{id}/containers/
    Returns running Docker containers for this stack's compose project,
    with their host port bindings. Used by the frontend to let the user
    pick a container instead of manually entering the upstream port.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        app = ComposeApp.objects.filter(pk=pk, user=request.user).first()
        if not app:
            return Response({'error': 'Projet introuvable'}, status=status.HTTP_404_NOT_FOUND)
        project_name = f'ondes_{app.id}_{app.name.lower().replace(" ", "_")}'
        return Response(services.get_stack_containers(project_name))


class ComposeAppUpdateCheckView(APIView):
    """
    GET /api/stacks/{id}/check-update/
    Compares the deployed commit SHA with the latest commit on the branch.
    Returns update_available=True when a new commit is available.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        app = ComposeApp.objects.filter(pk=pk, user=request.user).first()
        if not app:
            return Response({'error': 'Projet introuvable'}, status=status.HTTP_404_NOT_FOUND)

        try:
            token = app.user.github_profile.decrypted_token
        except Exception:
            return Response(
                {'error': 'Compte GitHub non connecté'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            owner, repo = app.github_repo.split('/', 1)
        except ValueError:
            return Response(
                {'error': 'Format de dépôt invalide'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        from apps.github_integration.services import get_latest_commit_sha
        try:
            latest_sha = get_latest_commit_sha(token, owner, repo, app.github_branch)
        except Exception as e:
            return Response({'error': str(e)}, status=status.HTTP_502_BAD_GATEWAY)

        current_sha = app.current_commit_sha or ''
        up_to_date = (current_sha == latest_sha) if current_sha else None

        return Response({
            'up_to_date': up_to_date,
            'current_sha': current_sha,
            'current_sha_short': current_sha[:8] if current_sha else '',
            'latest_sha': latest_sha,
            'latest_sha_short': latest_sha[:8] if latest_sha else '',
            'update_available': (not up_to_date) if current_sha else None,
        })


class ComposeAppWebhookDeployView(APIView):
    """
    POST /api/stacks/<pk>/webhook/
    Triggered by GitHub Actions (or any CI). No JWT required.
    Authenticates via the per-stack webhook_token in the Authorization header:
        Authorization: Bearer <webhook_token>
    Returns 200 immediately and deploys asynchronously in a background thread.
    """
    permission_classes = []   # No JWT — custom token auth below
    authentication_classes = []

    def post(self, request, pk):
        # Extract bearer token from Authorization header
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return Response({'error': 'Token manquant'}, status=status.HTTP_401_UNAUTHORIZED)

        provided_token = auth_header.split(' ', 1)[1].strip()

        try:
            app = ComposeApp.objects.get(pk=pk)
        except ComposeApp.DoesNotExist:
            return Response({'error': 'Projet introuvable'}, status=status.HTTP_404_NOT_FOUND)

        # Compare tokens using constant-time comparison to prevent timing attacks
        import hmac
        if not hmac.compare_digest(str(app.webhook_token), provided_token):
            return Response({'error': 'Token invalide'}, status=status.HTTP_403_FORBIDDEN)

        if app.status in ('cloning', 'building', 'starting'):
            return Response(
                {'status': 'already_deploying', 'app_id': app.id},
                status=status.HTTP_409_CONFLICT,
            )

        threading.Thread(target=services.deploy_app, args=(app.id,), daemon=True).start()
        return Response({'status': 'deploying', 'app_id': app.id, 'app_name': app.name})


class ComposeAppDetectNginxView(APIView):
    """
    GET /api/stacks/<pk>/detect-nginx/

    Scans the stack's cloned repo for nginx config files, matches discovered
    service names to running containers, and returns a list of VHost suggestions
    — without writing anything to the DB.  The Flutter UI presents the list and
    lets the user confirm which ones to import.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        app = ComposeApp.objects.filter(pk=pk, user=request.user).first()
        if not app:
            return Response({'error': 'Projet introuvable'}, status=status.HTTP_404_NOT_FOUND)

        project_dir = app.project_dir or ''
        if not project_dir or not __import__('os').path.isdir(project_dir):
            return Response({'error': 'Répertoire du projet introuvable. Déployez d\'abord.'}, status=status.HTTP_400_BAD_REQUEST)

        project_name = f'ondes_{app.id}_{app.name.lower().replace(" ", "_")}'

        from apps.nginx_manager.services import scan_project_nginx_configs, build_vhost_suggestions
        from apps.nginx_manager.models import NginxVhost

        parsed_files = scan_project_nginx_configs(project_dir)
        containers = services.get_stack_containers(project_name)

        # Detect a gateway nginx (non-platform port) — same logic as auto_detect_and_create_vhosts
        _PLATFORM_PORTS = frozenset({80, 443})
        gateway_port: int | None = None
        for _c in containers:
            if 'nginx' not in (_c.get('service') or '').lower():
                continue
            for _p in (_c.get('ports') or []):
                try:
                    _hp = int(_p.get('host_port', 0))
                    if _hp and _hp not in _PLATFORM_PORTS:
                        gateway_port = _hp
                        break
                except (TypeError, ValueError):
                    pass
            if gateway_port:
                break

        existing_info = dict(NginxVhost.objects.filter(stack=app).values_list('domain', 'id'))
        suggestions = build_vhost_suggestions(parsed_files, containers, existing_info, gateway_port=gateway_port)

        return Response({
            'project_name': project_name,
            'nginx_files_found': [f['file'] for f in parsed_files],
            'suggestions': suggestions,
        })

