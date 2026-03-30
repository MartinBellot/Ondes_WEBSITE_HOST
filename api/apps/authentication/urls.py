from django.urls import path
from rest_framework_simplejwt.views import TokenRefreshView
from .views import RegisterView, MeView, LogoutView, ThrottledLoginView

urlpatterns = [
    path('register/', RegisterView.as_view(), name='register'),
    path('login/',    ThrottledLoginView.as_view(), name='token_obtain_pair'),
    path('refresh/',  TokenRefreshView.as_view(), name='token_refresh'),
    path('logout/',   LogoutView.as_view(), name='logout'),
    path('me/',       MeView.as_view(), name='me'),
]
