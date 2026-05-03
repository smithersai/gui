"""Shared ID generation helpers."""

import secrets


def gen_id(prefix: str) -> str:
    """Generate URL-safe IDs matching the app's prefix convention."""
    return f"{prefix}{secrets.token_urlsafe(12)}"
