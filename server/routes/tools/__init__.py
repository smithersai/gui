"""
Tools route registration.
"""

from typing import Any


def register_routes(app: Any) -> None:
    """Register all tools routes."""
    from . import get, list

    app.include_router(list.router)
    app.include_router(get.router)
