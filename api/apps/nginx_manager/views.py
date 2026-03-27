from rest_framework import generics, status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated

from .models import NginxVhost
from . import services
from .serializers import (
    NginxVhostSerializer,
    NginxVhostCreateSerializer,
    CertbotRunSerializer,
    NginxConfigSerializer,
    CertbotSerializer,
)


# ─────────────────────────────────────────────────────────────────────────────
# Vhost CRUD
# ─────────────────────────────────────────────────────────────────────────────

class NginxVhostListCreateView(generics.ListCreateAPIView):
    """List all vhosts (optionally filtered by ?stack=<id>) or create one."""
    permission_classes = [IsAuthenticated]

    def get_serializer_class(self):
        if self.request.method == 'POST':
            return NginxVhostCreateSerializer
        return NginxVhostSerializer

    def get_queryset(self):
        qs = NginxVhost.objects.select_related('stack').filter(
            stack__user=self.request.user,
        )
        stack_id = self.request.query_params.get('stack')
        if stack_id:
            qs = qs.filter(stack_id=stack_id)
        return qs

    def create(self, request, *args, **kwargs):
        write_ser = NginxVhostCreateSerializer(data=request.data)
        write_ser.is_valid(raise_exception=True)
        data = write_ser.validated_data

        # Verify the stack belongs to the current user
        stack = data['stack']
        if stack.user != request.user:
            return Response({'error': 'Stack introuvable.'}, status=status.HTTP_404_NOT_FOUND)

        vhost = write_ser.save(ssl_enabled=False, ssl_status='none')

        # Write the HTTP-only vhost config and reload nginx
        result = services.write_vhost(
            domain=vhost.domain,
            upstream_port=vhost.upstream_port,
            ssl=False,
            route_overrides=vhost.route_overrides or None,
            include_www=vhost.include_www,
        )
        if result['status'] == 'error':
            vhost.delete()
            return Response(result, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        read_data = NginxVhostSerializer(vhost).data
        if result.get('message'):
            read_data['warning'] = result['message']
        return Response(read_data, status=status.HTTP_201_CREATED)


class NginxVhostDetailView(generics.RetrieveUpdateDestroyAPIView):
    permission_classes = [IsAuthenticated]

    def get_serializer_class(self):
        if self.request.method in ('PUT', 'PATCH'):
            return NginxVhostCreateSerializer
        return NginxVhostSerializer

    def get_queryset(self):
        return NginxVhost.objects.filter(stack__user=self.request.user)

    def update(self, request, *args, **kwargs):
        partial  = kwargs.pop('partial', False)
        vhost    = self.get_object()
        write_ser = NginxVhostCreateSerializer(
            vhost, data=request.data, partial=partial,
        )
        write_ser.is_valid(raise_exception=True)
        data = write_ser.validated_data

        old_domain = vhost.domain
        vhost = write_ser.save()

        # If domain changed, remove old config file
        if old_domain != vhost.domain:
            services.delete_vhost(old_domain)

        # Re-write vhost config (port or domain may have changed)
        result = services.write_vhost(
            domain=vhost.domain,
            upstream_port=vhost.upstream_port,
            ssl=vhost.ssl_enabled,
            route_overrides=vhost.route_overrides or None,
            include_www=vhost.include_www,
        )
        if result['status'] == 'error':
            return Response(result, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        return Response(NginxVhostSerializer(vhost).data)

    def destroy(self, request, *args, **kwargs):
        vhost = self.get_object()
        services.delete_vhost(vhost.domain)
        vhost.delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


# ─────────────────────────────────────────────────────────────────────────────
# Certbot — obtain / renew certificate for a vhost
# ─────────────────────────────────────────────────────────────────────────────

class NginxVhostCertbotView(APIView):
    """
    POST /api/nginx/vhosts/{id}/certbot/
    Body: { "email": "admin@example.com" }

    Runs certbot webroot for the vhost's domain, then if successful:
      - updates the config to serve HTTPS
      - reloads nginx
      - refreshes ssl_status / ssl_expires_at in DB
    """
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        vhost = NginxVhost.objects.filter(
            pk=pk, stack__user=request.user,
        ).first()
        if not vhost:
            return Response({'error': 'Vhost introuvable.'}, status=status.HTTP_404_NOT_FOUND)

        ser = CertbotRunSerializer(data=request.data)
        if not ser.is_valid():
            return Response(ser.errors, status=status.HTTP_400_BAD_REQUEST)

        email = ser.validated_data['email']
        if not vhost.ssl_email:
            vhost.ssl_email = email

        vhost.ssl_status = 'pending'
        vhost.save(update_fields=['ssl_email', 'ssl_status'])

        result = services.run_certbot_for_domain(vhost.domain, email, include_www=vhost.include_www)

        if result['status'] == 'error':
            vhost.ssl_status = 'error'
            vhost.certbot_output = result.get('message', '')
            vhost.save(update_fields=['ssl_status', 'certbot_output'])
            return Response(
                {'error': result['message'], 'output': result.get('output', '')},
                status=status.HTTP_422_UNPROCESSABLE_ENTITY,
            )

        # Certbot succeeded — update config + DB
        vhost.ssl_enabled    = True
        vhost.certbot_output = result.get('output', '')
        vhost.save(update_fields=['ssl_enabled', 'certbot_output'])

        # Regenerate vhost config with HTTPS
        services.write_vhost(
            domain=vhost.domain,
            upstream_port=vhost.upstream_port,
            ssl=True,
            route_overrides=vhost.route_overrides or None,
            include_www=vhost.include_www,
        )

        # Refresh cert expiry from disk
        services.sync_cert_status(vhost)

        return Response(NginxVhostSerializer(vhost).data)


# ─────────────────────────────────────────────────────────────────────────────
# Certificate status refresh
# ─────────────────────────────────────────────────────────────────────────────

class NginxVhostCertStatusView(APIView):
    """
    GET /api/nginx/vhosts/{id}/cert-status/
    Reads the cert from disk and returns fresh expiry info. Also updates DB.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        vhost = NginxVhost.objects.filter(
            pk=pk, stack__user=request.user,
        ).first()
        if not vhost:
            return Response({'error': 'Vhost introuvable.'}, status=status.HTTP_404_NOT_FOUND)

        info = services.get_cert_info(vhost.domain)

        # Persist updated status
        if vhost.ssl_enabled:
            services.sync_cert_status(vhost)

        return Response({
            **info,
            'domain':      vhost.domain,
            'ssl_enabled': vhost.ssl_enabled,
            'ssl_status':  vhost.ssl_status,
        })


class NginxVhostCheckDnsView(APIView):
    """
    GET /api/nginx/vhosts/{id}/check-dns/

    Check whether the vhost's domain currently resolves to this server's IP.

    Response:
      {
        "domain":      str,
        "server_ip":   str | null,
        "resolved_ip": str | null,
        "propagated":  bool,
      }
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        vhost = NginxVhost.objects.filter(
            pk=pk, stack__user=request.user,
        ).first()
        if not vhost:
            return Response({'error': 'Vhost introuvable.'}, status=status.HTTP_404_NOT_FOUND)

        result = services.check_dns_propagation(vhost.domain)
        return Response(result)


# ─────────────────────────────────────────────────────────────────────────────
# Legacy endpoints (kept for backwards compat)
# ─────────────────────────────────────────────────────────────────────────────

class NginxPreviewView(APIView):
    """Return a generated NGINX config without writing it to disk."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        serializer = NginxConfigSerializer(data=request.data)
        if not serializer.is_valid():
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
        data   = serializer.validated_data
        config = services.generate_vhost_config(
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
        data   = serializer.validated_data
        result = services.write_vhost(
            domain=data['domain'],
            upstream_port=data['upstream_port'],
            ssl=data.get('ssl', False),
        )
        if result['status'] == 'error':
            return Response(result, status=status.HTTP_500_INTERNAL_SERVER_ERROR)
        return Response(result)


class CertbotView(APIView):
    """Run certbot for a domain (legacy, no DB record)."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        serializer = CertbotSerializer(data=request.data)
        if not serializer.is_valid():
            return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
        data   = serializer.validated_data
        result = services.run_certbot_for_domain(data['domain'], data['email'])
        if result['status'] == 'error':
            return Response(result, status=status.HTTP_500_INTERNAL_SERVER_ERROR)
        return Response(result)

