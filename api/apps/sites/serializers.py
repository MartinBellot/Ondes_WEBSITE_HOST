from rest_framework import serializers
from .models import Site


class SiteSerializer(serializers.ModelSerializer):
    class Meta:
        model = Site
        fields = '__all__'
        read_only_fields = ('user', 'status', 'created_at', 'updated_at',
                            'web_container_name', 'api_container_name')
        extra_kwargs = {
            'github_token': {'write_only': True},
        }


class SiteListSerializer(serializers.ModelSerializer):
    """Lightweight serializer for the Mes Sites list view."""
    class Meta:
        model = Site
        fields = (
            'id', 'name', 'domain', 'site_type', 'status',
            'github_repo', 'github_branch',
            'web_port', 'api_port',
            'ssl_enabled', 'created_at', 'updated_at',
        )


class CertbotRequestSerializer(serializers.Serializer):
    domain = serializers.CharField(max_length=253)
    email = serializers.EmailField()
