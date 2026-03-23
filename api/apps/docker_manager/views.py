from rest_framework import status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from docker.errors import DockerException, NotFound, APIError

from . import services
from .serializers import CreateContainerSerializer
from .models import ContainerConfig


class ContainerListView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        try:
            containers = services.list_containers()
            return Response(containers)
        except (DockerException, APIError) as e:
            return Response({'error': str(e)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)


class ContainerActionView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, container_id, action):
        try:
            if action == 'start':
                result = services.start_container(container_id)
            elif action == 'stop':
                result = services.stop_container(container_id)
            elif action == 'remove':
                result = services.remove_container(container_id)
            else:
                return Response({'error': 'Invalid action'}, status=status.HTTP_400_BAD_REQUEST)
            return Response(result)
        except NotFound:
            return Response({'error': 'Container not found'}, status=status.HTTP_404_NOT_FOUND)
        except (DockerException, APIError) as e:
            return Response({'error': str(e)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)


class CreateContainerView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        serializer = CreateContainerSerializer(data=request.data)
        if not serializer.is_valid():
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

        data = serializer.validated_data
        try:
            result = services.create_container(
                name=data['name'],
                image=data['image'],
                host_port=data['host_port'],
                container_port=data['container_port'],
                volume_host=data.get('volume_host', ''),
                volume_container=data.get('volume_container', ''),
            )
            ContainerConfig.objects.create(
                user=request.user,
                name=data['name'],
                image=data['image'],
                host_port=data['host_port'],
                container_port=data['container_port'],
                volume_host=data.get('volume_host', ''),
                volume_container=data.get('volume_container', ''),
            )
            return Response(result, status=status.HTTP_201_CREATED)
        except (DockerException, APIError) as e:
            return Response({'error': str(e)}, status=status.HTTP_503_SERVICE_UNAVAILABLE)
