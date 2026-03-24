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
            result = services.start_app(app.id)
        elif action == 'stop':
            result = services.stop_app(app.id)
        elif action == 'restart':
            result = services.restart_app(app.id)
        else:
            return Response({'error': 'Action invalide'}, status=status.HTTP_400_BAD_REQUEST)

        if 'error' in result:
            return Response(result, status=status.HTTP_500_INTERNAL_SERVER_ERROR)
        return Response(result)


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
            token = app.user.github_profile.access_token
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
