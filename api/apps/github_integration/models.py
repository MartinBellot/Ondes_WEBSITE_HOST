from django.db import models
from django.contrib.auth.models import User


# ─── Encryption helpers ───────────────────────────────────────────────────────

def _fernet():
    from django.conf import settings
    from cryptography.fernet import Fernet
    return Fernet(settings.TOKEN_ENCRYPTION_KEY)


def _encrypt_token(value: str) -> str:
    """Encrypt a plaintext token using Fernet (AES-128-CBC + HMAC-SHA256)."""
    return _fernet().encrypt(value.encode()).decode()


def _decrypt_token(value: str) -> str:
    """Decrypt a Fernet token.

    Raises InvalidToken when the stored ciphertext cannot be decrypted with the
    current TOKEN_ENCRYPTION_KEY (e.g. after a SECRET_KEY rotation).  Callers
    must treat this as a "GitHub reconnect required" condition — do NOT silently
    return garbage ciphertext, which would result in confusing 401s from the
    GitHub API that look like JWT auth failures to the Flutter client.
    """
    from cryptography.fernet import InvalidToken
    if not value:
        return value
    try:
        return _fernet().decrypt(value.encode()).decode()
    except InvalidToken:
        raise
    except Exception as exc:
        raise InvalidToken(str(exc)) from exc


# ─── Models ───────────────────────────────────────────────────────────────────

class GitHubProfile(models.Model):
    """
    Stores the OAuth access token for a user's connected GitHub account.
    One profile per user — connecting again replaces the existing entry.
    The access_token column always stores a Fernet-encrypted value.
    Use the ``decrypted_token`` property to obtain the plaintext token.
    """
    user = models.OneToOneField(
        User, on_delete=models.CASCADE, related_name='github_profile'
    )
    login = models.CharField(max_length=100)
    name = models.CharField(max_length=200, blank=True)
    avatar_url = models.URLField(blank=True)
    # Column stores Fernet ciphertext (longer than the raw token — max 1000).
    access_token = models.CharField(max_length=1000)
    token_scope = models.CharField(max_length=500, blank=True)
    connected_at = models.DateTimeField(auto_now=True)

    @property
    def decrypted_token(self) -> str:
        """Return the plaintext GitHub OAuth access token."""
        return _decrypt_token(self.access_token)

    def save(self, *args, **kwargs):
        # Ensure the token is always stored encrypted regardless of how the
        # instance was constructed (create, update_or_create, direct assign).
        # Idempotent: if already encrypted, decrypt first; if plaintext, use as-is.
        if self.access_token:
            from cryptography.fernet import InvalidToken
            try:
                plain = _decrypt_token(self.access_token)
            except InvalidToken:
                plain = self.access_token  # incoming plaintext
            self.access_token = _encrypt_token(plain)
        super().save(*args, **kwargs)

    def __str__(self):
        return f'{self.user.username} → @{self.login}'


class GitHubOAuthConfig(models.Model):
    """
    Singleton row: stores the GitHub OAuth App credentials entered via the UI.
    Instead of relying on .env variables, admins configure these directly
    in the application interface.
    The client_secret column always stores a Fernet-encrypted value.
    Use the ``decrypted_secret`` property to obtain the plaintext secret.
    """
    client_id = models.CharField(max_length=200)
    # Column stores Fernet ciphertext (max 500).
    client_secret = models.CharField(max_length=500)
    configured_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = 'GitHub OAuth Config'

    def __str__(self):
        return f'GitHub OAuth Config (client_id={self.client_id[:8]}…)'

    @property
    def decrypted_secret(self) -> str:
        """Return the plaintext GitHub OAuth client secret."""
        return _decrypt_token(self.client_secret)

    def save(self, *args, **kwargs):
        # Idempotent: if already encrypted, decrypt first; if plaintext, use as-is.
        if self.client_secret:
            from cryptography.fernet import InvalidToken
            try:
                plain = _decrypt_token(self.client_secret)
            except InvalidToken:
                plain = self.client_secret  # incoming plaintext
            self.client_secret = _encrypt_token(plain)
        super().save(*args, **kwargs)

    @classmethod
    def get(cls):
        """Return the singleton instance, or None if not yet configured."""
        return cls.objects.first()
