from django.urls import path
from .views import (
    NginxVhostListCreateView,
    NginxVhostDetailView,
    NginxVhostCertbotView,
    NginxVhostCertStatusView,
    NginxVhostCheckDnsView,
    # Legacy
    NginxPreviewView,
    NginxConfigView,
    CertbotView,
)

urlpatterns = [
    # ── Vhost CRUD ────────────────────────────────────────────────────────
    path('vhosts/',                         NginxVhostListCreateView.as_view(), name='nginx-vhost-list'),
    path('vhosts/<int:pk>/',                NginxVhostDetailView.as_view(),     name='nginx-vhost-detail'),
    path('vhosts/<int:pk>/certbot/',        NginxVhostCertbotView.as_view(),    name='nginx-vhost-certbot'),
    path('vhosts/<int:pk>/cert-status/',    NginxVhostCertStatusView.as_view(), name='nginx-vhost-cert-status'),
    path('vhosts/<int:pk>/check-dns/',      NginxVhostCheckDnsView.as_view(),   name='nginx-vhost-check-dns'),
    # ── Legacy ────────────────────────────────────────────────────────────
    path('preview/',   NginxPreviewView.as_view(), name='nginx-preview'),
    path('configure/', NginxConfigView.as_view(),  name='nginx-configure'),
    path('certbot/',   CertbotView.as_view(),      name='certbot'),
]

