from django.urls import path
from .views import (
    SiteListCreateView, SiteDetailView,
    SiteDeployView,
    SiteNginxPreviewView, SiteNginxApplyView,
    SiteCertbotView,
)

urlpatterns = [
    path('',               SiteListCreateView.as_view(), name='site-list'),
    path('<int:pk>/',      SiteDetailView.as_view(),     name='site-detail'),
    path('<int:pk>/deploy/',        SiteDeployView.as_view(),       name='site-deploy'),
    path('<int:pk>/nginx/preview/', SiteNginxPreviewView.as_view(), name='site-nginx-preview'),
    path('<int:pk>/nginx/apply/',   SiteNginxApplyView.as_view(),   name='site-nginx-apply'),
    path('<int:pk>/certbot/',       SiteCertbotView.as_view(),      name='site-certbot'),
]
