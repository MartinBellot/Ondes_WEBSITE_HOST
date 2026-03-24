from django.urls import path
from .views import (
    ComposeAppListCreateView,
    ComposeAppDetailView,
    ComposeAppDeployView,
    ComposeAppActionView,
    ComposeAppLogsView,
    ComposeAppEnvView,
    ComposeAppVhostsView,
)

urlpatterns = [
    path('',                         ComposeAppListCreateView.as_view(), name='stack-list'),
    path('<int:pk>/',                 ComposeAppDetailView.as_view(),     name='stack-detail'),
    path('<int:pk>/deploy/',          ComposeAppDeployView.as_view(),     name='stack-deploy'),
    path('<int:pk>/action/<str:action>/', ComposeAppActionView.as_view(), name='stack-action'),
    path('<int:pk>/logs/',            ComposeAppLogsView.as_view(),       name='stack-logs'),
    path('<int:pk>/env/',             ComposeAppEnvView.as_view(),        name='stack-env'),
    path('<int:pk>/vhosts/',          ComposeAppVhostsView.as_view(),     name='stack-vhosts'),
]
