from django.contrib import admin
from .models import NginxVhost


@admin.register(NginxVhost)
class NginxVhostAdmin(admin.ModelAdmin):
    list_display  = ('domain', 'service_label', 'upstream_port', 'ssl_enabled', 'ssl_status', 'ssl_expires_at', 'stack')
    list_filter   = ('ssl_enabled', 'ssl_status')
    search_fields = ('domain', 'service_label', 'stack__name')
    readonly_fields = ('ssl_expires_at', 'certbot_output', 'created_at', 'updated_at')
