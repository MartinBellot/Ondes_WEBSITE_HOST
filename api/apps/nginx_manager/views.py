from rest_framework import status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated

from .services import generate_reverse_proxy_config, write_nginx_config, run_certbot
from .serializers import NginxConfigSerializer, CertbotSerializer


class NginxPreviewView(APIView):
    """Return a generated NGINX config without writing it to disk."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        serializer = NginxConfigSerializer(data=request.data)
        if not serializer.is_valid():
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
        data = serializer.validated_data
        config = generate_reverse_proxy_config(
            domain=data['domain'],
            upstream_port=data['upstream_port'],
            ssl=data.get('ssl', False),
        )
        return Response({'config': config})


class NginxConfigView(APIView):
    """Generate and write an NGINX config to disk, then reload nginx."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        serializer = NginxConfigSerializer(data=request.data)
        if not serializer.is_valid():
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
        data = serializer.validated_data
        config = generate_reverse_proxy_config(
            domain=data['domain'],
            upstream_port=data['upstream_port'],
            ssl=data.get('ssl', False),
        )
        result = write_nginx_config(data['domain'], config)
        if result['status'] == 'error':
            return Response(result, status=status.HTTP_500_INTERNAL_SERVER_ERROR)
        return Response({**result, 'config': config})


class CertbotView(APIView):
    """Run certbot --nginx to obtain/renew an SSL certificate."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        serializer = CertbotSerializer(data=request.data)
        if not serializer.is_valid():
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
        data = serializer.validated_data
        result = run_certbot(data['domain'], data['email'])
        if result['status'] == 'error':
            return Response(result, status=status.HTTP_500_INTERNAL_SERVER_ERROR)
        return Response(result)
