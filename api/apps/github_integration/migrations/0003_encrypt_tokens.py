"""
Migration 0003 — Encrypt stored OAuth tokens at rest.

Steps:
  1. Increase max_length on GitHubProfile.access_token (500 → 1000) and
     GitHubOAuthConfig.client_secret (200 → 500) to accommodate Fernet
     ciphertext, which is larger than the plaintext.
  2. Re-encrypt any existing plaintext values so that all rows are protected
     after the migration runs.
"""

import hashlib, base64

from django.db import migrations, models


def encrypt_existing_tokens(apps, schema_editor):
    """Encrypt any plaintext tokens already in the database."""
    from django.conf import settings
    from cryptography.fernet import Fernet, InvalidToken

    key = getattr(settings, 'TOKEN_ENCRYPTION_KEY', None)
    if key is None:
        # Derive on-the-fly for environments where settings aren't fully loaded
        key = base64.urlsafe_b64encode(
            hashlib.sha256(settings.SECRET_KEY.encode()).digest()
        )

    f = Fernet(key)

    def _is_encrypted(value):
        try:
            f.decrypt(value.encode())
            return True
        except (InvalidToken, Exception):
            return False

    GitHubProfile = apps.get_model('github_integration', 'GitHubProfile')
    for profile in GitHubProfile.objects.all():
        if profile.access_token and not _is_encrypted(profile.access_token):
            profile.access_token = f.encrypt(profile.access_token.encode()).decode()
            profile.save(update_fields=['access_token'])

    GitHubOAuthConfig = apps.get_model('github_integration', 'GitHubOAuthConfig')
    for cfg in GitHubOAuthConfig.objects.all():
        if cfg.client_secret and not _is_encrypted(cfg.client_secret):
            cfg.client_secret = f.encrypt(cfg.client_secret.encode()).decode()
            cfg.save(update_fields=['client_secret'])


def noop(apps, schema_editor):
    pass  # no reverse encryption (plaintext can't be recovered without key)


class Migration(migrations.Migration):

    dependencies = [
        ('github_integration', '0002_githuboauthconfig'),
    ]

    operations = [
        # 1. Widen fields to fit Fernet ciphertext.
        migrations.AlterField(
            model_name='githubprofile',
            name='access_token',
            field=models.CharField(max_length=1000),
        ),
        migrations.AlterField(
            model_name='githuboauthconfig',
            name='client_secret',
            field=models.CharField(max_length=500),
        ),
        # 2. Encrypt any existing plaintext values.
        migrations.RunPython(encrypt_existing_tokens, reverse_code=noop),
    ]
