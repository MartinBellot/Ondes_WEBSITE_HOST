from rest_framework import serializers
from .models import ContainerConfig


class ContainerConfigSerializer(serializers.ModelSerializer):
    class Meta:
        model = ContainerConfig
        fields = '__all__'
        read_only_fields = ('user', 'created_at')


class CreateContainerSerializer(serializers.Serializer):
    name = serializers.CharField(max_length=100)
    image = serializers.CharField(max_length=200)
    host_port = serializers.IntegerField(min_value=1, max_value=65535)
    container_port = serializers.IntegerField(min_value=1, max_value=65535, default=80)
    volume_host = serializers.CharField(max_length=500, required=False, default='')
    volume_container = serializers.CharField(max_length=500, required=False, default='')
