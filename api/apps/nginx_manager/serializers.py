from rest_framework import serializers
from .models import NginxVhost


class NginxVhostSerializer(serializers.ModelSerializer):
    """Full read serializer — includes computed cert_days_remaining field."""
    cert_days_remaining = serializers.SerializerMethodField()

    class Meta:
        model  = NginxVhost
        fields = [
            'id', 'stack', 'service_label', 'domain', 'upstream_port',
            'ssl_enabled', 'ssl_email', 'ssl_status', 'ssl_expires_at',
            'certbot_output', 'cert_days_remaining',
            'created_at', 'updated_at',
        ]
        read_only_fields = [
            'id', 'ssl_status', 'ssl_expires_at', 'certbot_output',
            'created_at', 'updated_at',
        ]

    def get_cert_days_remaining(self, obj):
        if obj.ssl_expires_at is None:
            return None
        from datetime import datetime, timezone
        delta = obj.ssl_expires_at - datetime.now(tz=timezone.utc)
        return delta.days


class NginxVhostCreateSerializer(serializers.ModelSerializer):
    """Write serializer for creating/updating a vhost."""
    class Meta:
        model  = NginxVhost
        fields = ['stack', 'service_label', 'domain', 'upstream_port', 'ssl_email']

    def validate_domain(self, value):
        # Basic sanity — no spaces, no protocol prefix
        value = value.strip().lower().lstrip('http://').lstrip('https://')
        if ' ' in value:
            raise serializers.ValidationError('Le domaine ne doit pas contenir d\'espaces.')
        return value

    def validate_upstream_port(self, value):
        if not (1 <= value <= 65535):
            raise serializers.ValidationError('Port invalide (1-65535).')
        return value


class CertbotRunSerializer(serializers.Serializer):
    email = serializers.EmailField()


# ── Legacy serializers kept for backwards compat (preview / raw configure) ───

class NginxConfigSerializer(serializers.Serializer):
    domain        = serializers.CharField(max_length=253)
    upstream_port = serializers.IntegerField(min_value=1, max_value=65535)
    ssl           = serializers.BooleanField(default=False)


class CertbotSerializer(serializers.Serializer):
    domain = serializers.CharField(max_length=253)
    email  = serializers.EmailField()

