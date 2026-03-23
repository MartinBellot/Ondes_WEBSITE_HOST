from django.contrib import admin
from django.urls import path, include

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/auth/', include('apps.authentication.urls')),
    path('api/docker/', include('apps.docker_manager.urls')),
    path('api/nginx/', include('apps.nginx_manager.urls')),
    path('api/sites/', include('apps.sites.urls')),
    path('api/github/', include('apps.github_integration.urls')),
]
