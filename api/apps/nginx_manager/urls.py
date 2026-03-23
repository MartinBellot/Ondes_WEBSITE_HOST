from django.urls import path
from .views import NginxPreviewView, NginxConfigView, CertbotView

urlpatterns = [
    path('preview/', NginxPreviewView.as_view(), name='nginx-preview'),
    path('configure/', NginxConfigView.as_view(), name='nginx-configure'),
    path('certbot/', CertbotView.as_view(), name='certbot'),
]
