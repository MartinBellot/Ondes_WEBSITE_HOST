from django.db import models
from django.contrib.auth.models import User


class Site(models.Model):
    SITE_TYPE_CHOICES = [
        ('web',       'Web / Frontend'),
        ('api',       'API / Backend'),
        ('fullstack', 'Fullstack (Web + API)'),
    ]
    STATUS_CHOICES = [
        ('idle',      'Idle'),
        ('deploying', 'Deploying'),
        ('running',   'Running'),
        ('stopped',   'Stopped'),
        ('error',     'Error'),
    ]

    user           = models.ForeignKey(User, on_delete=models.CASCADE, related_name='sites')
    name           = models.CharField(max_length=100)
    domain         = models.CharField(max_length=253, blank=True)
    site_type      = models.CharField(max_length=20, choices=SITE_TYPE_CHOICES, default='web')
    status         = models.CharField(max_length=20, choices=STATUS_CHOICES, default='idle')

    # ── GitHub ────────────────────────────────────────────────────────────────
    # NOTE: In production store github_token encrypted (e.g. django-encrypted-fields)
    github_repo    = models.CharField(max_length=500, blank=True, help_text='owner/repo')
    github_branch  = models.CharField(max_length=100, default='main')
    github_token   = models.CharField(max_length=500, blank=True, help_text='Personal Access Token')

    # ── Hosting ───────────────────────────────────────────────────────────────
    web_container_name = models.CharField(max_length=100, blank=True)
    api_container_name = models.CharField(max_length=100, blank=True)
    web_port           = models.IntegerField(null=True, blank=True)
    api_port           = models.IntegerField(null=True, blank=True)

    # ── SSL ───────────────────────────────────────────────────────────────────
    ssl_enabled = models.BooleanField(default=False)
    ssl_email   = models.EmailField(blank=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f'{self.name} ({self.domain or "no domain"})'
