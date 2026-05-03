"""
Message route registration.
"""

from typing import Any


def register_routes(app: Any) -> None:
    """Register all message routes."""
    from . import get, list, send

    app.include_router(list.router)
    app.include_router(get.router)
    app.include_router(send.router)
