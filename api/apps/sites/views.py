import threading

from rest_framework import generics, status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated

from .models import Site
from .serializers import SiteSerializer, SiteListSerializer, CertbotRequestSerializer
from .services import deploy_site
from apps.nginx_manager.services import (
    generate_vhost_config as generate_reverse_proxy_config,
    write_vhost as _write_vhost_new,
    run_certbot_for_domain as run_certbot,
)


def write_nginx_config(domain: str, config: str) -> dict:
    """Compatibility shim: the new API takes (domain, port, ssl), not raw config."""
    # Sites module calls this with a raw config string we can't re-parse;
    # just write it directly to the vhosts dir.
    from pathlib import Path
    import os
    from apps.nginx_manager.services import VHOSTS_DIR, reload_nginx
    try:
        VHOSTS_DIR.mkdir(parents=True, exist_ok=True)
        (VHOSTS_DIR / f'{domain}.conf').write_text(config)
        return reload_nginx()
    except Exception as exc:
        return {'status': 'error', 'message': str(exc)}


class SiteListCreateView(generics.ListCreateAPIView):
    permission_classes = [IsAuthenticated]

    def get_serializer_class(self):
        return SiteSerializer if self.request.method == 'POST' else SiteListSerializer

    def get_queryset(self):
        return Site.objects.filter(user=self.request.user)

    def perform_create(self, serializer):
        serializer.save(user=self.request.user)


class SiteDetailView(generics.RetrieveUpdateDestroyAPIView):
    permission_classes = [IsAuthenticated]
    serializer_class = SiteSerializer

    def get_queryset(self):
        return Site.objects.filter(user=self.request.user)


class SiteDeployView(APIView):
    """Kick off a deploy pipeline for a site (runs in background thread)."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        site = Site.objects.filter(pk=pk, user=request.user).first()
        if not site:
            return Response({'error': 'Site not found'}, status=status.HTTP_404_NOT_FOUND)
        if not site.github_repo:
            return Response(
                {'error': 'No GitHub repo configured for this site'},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if site.status == 'deploying':
            return Response({'error': 'Deploy already in progress'}, status=status.HTTP_409_CONFLICT)

        # Run deploy in background so the request returns immediately
        t = threading.Thread(target=deploy_site, args=(site,), daemon=True)
        t.start()
        return Response({'status': 'deploying', 'site_id': site.id})


class SiteNginxPreviewView(APIView):
    """Generate and preview an NGINX reverse-proxy config for a site."""
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        site = Site.objects.filter(pk=pk, user=request.user).first()
        if not site:
            return Response({'error': 'Site not found'}, status=status.HTTP_404_NOT_FOUND)
        if not site.domain:
            return Response({'error': 'No domain configured'}, status=status.HTTP_400_BAD_REQUEST)
        port = site.web_port or site.api_port
        if not port:
            return Response({'error': 'No port configured'}, status=status.HTTP_400_BAD_REQUEST)

        config = generate_reverse_proxy_config(
            domain=site.domain,
            upstream_port=port,
            ssl=site.ssl_enabled,
        )
        return Response({'config': config})


class SiteNginxApplyView(APIView):
    """Write the NGINX config to disk and reload nginx."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        site = Site.objects.filter(pk=pk, user=request.user).first()
        if not site:
            return Response({'error': 'Site not found'}, status=status.HTTP_404_NOT_FOUND)
        if not site.domain:
            return Response({'error': 'No domain configured'}, status=status.HTTP_400_BAD_REQUEST)
        port = site.web_port or site.api_port
        if not port:
            return Response({'error': 'No port configured'}, status=status.HTTP_400_BAD_REQUEST)

        config = generate_reverse_proxy_config(site.domain, port, site.ssl_enabled)
        result = write_nginx_config(site.domain, config)
        if result['status'] == 'error':
            return Response(result, status=status.HTTP_500_INTERNAL_SERVER_ERROR)
        return Response({**result, 'config': config})


class SiteCertbotView(APIView):
    """Request an SSL certificate via Certbot for a site."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        site = Site.objects.filter(pk=pk, user=request.user).first()
        if not site:
            return Response({'error': 'Site not found'}, status=status.HTTP_404_NOT_FOUND)

        serializer = CertbotRequestSerializer(data=request.data)
        if not serializer.is_valid():
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)

        domain = serializer.validated_data['domain'] or site.domain
        email = serializer.validated_data['email'] or site.ssl_email

        result = run_certbot(domain, email)
        if result['status'] == 'success':
            site.ssl_enabled = True
            site.ssl_email = email
            site.save(update_fields=['ssl_enabled', 'ssl_email'])
        return Response(result)
