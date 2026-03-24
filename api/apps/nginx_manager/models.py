from django.db import models


class NginxVhost(models.Model):
    """
    Represents an NGINX reverse-proxy vhost for a deployed ComposeApp stack.
    One stack can have multiple vhosts (e.g. frontend on port 3000 + API on port 8080).
    """
    SSL_STATUS_CHOICES = [
        ('none',    'Pas de SSL'),
        ('pending', 'Obtention en cours'),
        ('active',  'SSL actif'),
        ('error',   "Erreur d'obtention"),
        ('expired', 'Certificat expiré'),
    ]

    stack = models.ForeignKey(
        'stacks.ComposeApp',
        on_delete=models.CASCADE,
        related_name='vhosts',
    )
    # Human-readable label for the service this vhost fronts (e.g. "frontend", "api")
    service_label  = models.CharField(max_length=50, default='app')
    domain         = models.CharField(max_length=253, unique=True)
    upstream_port  = models.IntegerField(
        help_text='Port exposé sur l\'hôte par le container applicatif',
    )
    container_name = models.CharField(
        max_length=255, blank=True,
        help_text='Nom du container Docker sélectionné lors de la création (référence)',
    )

    # ── SSL ───────────────────────────────────────────────────────────────────
    ssl_enabled   = models.BooleanField(default=False)
    ssl_email     = models.EmailField(blank=True)
    ssl_status    = models.CharField(
        max_length=20, choices=SSL_STATUS_CHOICES, default='none',
    )
    ssl_expires_at  = models.DateTimeField(null=True, blank=True)
    certbot_output  = models.TextField(blank=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['domain']

    def __str__(self):
        ssl_flag = ' [SSL]' if self.ssl_enabled else ''
        return f'{self.domain} → :{self.upstream_port}{ssl_flag} (stack {self.stack_id})'
