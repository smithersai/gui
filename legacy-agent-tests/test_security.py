"""Tests for server security defaults."""

import asyncio
import importlib.util
from pathlib import Path
from types import SimpleNamespace

import pytest


def load_security_module():
    """Load server/security.py without importing the full FastAPI app."""
    security_path = Path(__file__).resolve().parents[1] / "server" / "security.py"
    spec = importlib.util.spec_from_file_location("server_security_under_test", security_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_remote_bind_requires_api_key(monkeypatch):
    """Remote listeners fail closed unless authentication is configured."""
    monkeypatch.delenv("AGENT_API_KEY", raising=False)
    monkeypatch.delenv("ALLOW_INSECURE_REMOTE", raising=False)
    security = load_security_module()

    with pytest.raises(ValueError):
        security.validate_server_binding("0.0.0.0")


def test_remote_bind_allows_api_key(monkeypatch):
    """Remote listeners are allowed when an API key is configured."""
    monkeypatch.setenv("AGENT_API_KEY", "secret")
    monkeypatch.delenv("ALLOW_INSECURE_REMOTE", raising=False)
    security = load_security_module()

    security.validate_server_binding("0.0.0.0")


def test_api_key_middleware_rejects_missing_key(monkeypatch):
    """Configured API keys are required for protected routes."""
    monkeypatch.setenv("AGENT_API_KEY", "secret")
    security = load_security_module()
    middleware = security.APIKeyMiddleware(app=lambda scope, receive, send: None)
    request = SimpleNamespace(
        method="GET",
        url=SimpleNamespace(path="/session"),
        headers={},
    )

    async def call_next(_request):
        return security.Response(status_code=200)

    response = asyncio.run(middleware.dispatch(request, call_next))

    assert response.status_code == 401


def test_api_key_middleware_accepts_bearer_key(monkeypatch):
    """Bearer authentication unlocks protected routes."""
    monkeypatch.setenv("AGENT_API_KEY", "secret")
    security = load_security_module()
    middleware = security.APIKeyMiddleware(app=lambda scope, receive, send: None)
    request = SimpleNamespace(
        method="GET",
        url=SimpleNamespace(path="/session"),
        headers={"authorization": "Bearer secret"},
    )

    async def call_next(_request):
        return security.Response(status_code=200)

    response = asyncio.run(middleware.dispatch(request, call_next))

    assert response.status_code == 200


def test_health_endpoint_does_not_require_key(monkeypatch):
    """Health checks remain usable for local supervisors."""
    monkeypatch.setenv("AGENT_API_KEY", "secret")
    security = load_security_module()
    middleware = security.APIKeyMiddleware(app=lambda scope, receive, send: None)
    request = SimpleNamespace(
        method="GET",
        url=SimpleNamespace(path="/health"),
        headers={},
    )

    async def call_next(_request):
        return security.Response(status_code=200)

    response = asyncio.run(middleware.dispatch(request, call_next))

    assert response.status_code == 200
