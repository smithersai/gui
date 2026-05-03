"""Security helpers for the HTTP API server."""

from __future__ import annotations

import hmac
import os
from collections.abc import Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

API_KEY_ENV = "AGENT_API_KEY"
ALLOW_INSECURE_REMOTE_ENV = "ALLOW_INSECURE_REMOTE"
API_KEY_HEADER = "x-agent-api-key"
UNPROTECTED_PATHS = frozenset({"/health"})


def is_loopback_host(host: str) -> bool:
    """Return whether a host value only exposes the server locally."""
    normalized = host.strip().lower()
    return normalized in {"", "localhost", "127.0.0.1", "::1"} or normalized.startswith(
        "127."
    )


def validate_server_binding(host: str) -> None:
    """Fail closed when binding remotely without an authentication secret."""
    if is_loopback_host(host):
        return
    if os.environ.get(API_KEY_ENV):
        return
    if os.environ.get(ALLOW_INSECURE_REMOTE_ENV, "").lower() == "true":
        return
    raise ValueError(
        f"Refusing to bind to {host!r} without {API_KEY_ENV}. "
        f"Set {API_KEY_ENV} or explicitly set {ALLOW_INSECURE_REMOTE_ENV}=true."
    )


class APIKeyMiddleware(BaseHTTPMiddleware):
    """Require an API key when AGENT_API_KEY is configured."""

    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Response],
    ) -> Response:
        expected_key = os.environ.get(API_KEY_ENV)
        if not expected_key:
            return await call_next(request)

        if request.method == "OPTIONS" or request.url.path in UNPROTECTED_PATHS:
            return await call_next(request)

        supplied_key = request.headers.get(API_KEY_HEADER)
        authorization = request.headers.get("authorization", "")
        if authorization.lower().startswith("bearer "):
            supplied_key = authorization[7:].strip()

        if supplied_key and hmac.compare_digest(supplied_key, expected_key):
            return await call_next(request)

        return JSONResponse(
            {"detail": "Missing or invalid API key"},
            status_code=401,
            headers={"WWW-Authenticate": "Bearer"},
        )
