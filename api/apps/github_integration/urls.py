from django.urls import path
from .views import GitHubUserView, GitHubReposView, GitHubBranchesView

urlpatterns = [
    path('user/',     GitHubUserView.as_view(),    name='github-user'),
    path('repos/',    GitHubReposView.as_view(),   name='github-repos'),
    path('branches/', GitHubBranchesView.as_view(), name='github-branches'),
]
