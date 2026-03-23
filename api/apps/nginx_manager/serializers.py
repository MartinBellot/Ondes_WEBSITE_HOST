from rest_framework import serializers


class NginxConfigSerializer(serializers.Serializer):
    domain = serializers.CharField(max_length=253)
    upstream_port = serializers.IntegerField(min_value=1, max_value=65535)
    ssl = serializers.BooleanField(default=False)


class CertbotSerializer(serializers.Serializer):
    domain = serializers.CharField(max_length=253)
    email = serializers.EmailField()
