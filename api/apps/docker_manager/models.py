from django.db import models
from django.contrib.auth.models import User


class ContainerConfig(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='containers')
    name = models.CharField(max_length=100, unique=True)
    image = models.CharField(max_length=200)
    host_port = models.IntegerField()
    container_port = models.IntegerField(default=80)
    volume_host = models.CharField(max_length=500, blank=True)
    volume_container = models.CharField(max_length=500, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.name} ({self.image})"
