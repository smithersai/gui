"""
Session route registration.
"""

from typing import Any


def register_routes(app: Any) -> None:
    """Register all session routes."""
    from . import (
        abort,
        compact,
        create,
        delete,
        diff,
        fork,
        get,
        list,
        revert,
        undo,
        unrevert,
        update,
    )

    app.include_router(list.router)
    app.include_router(create.router)
    app.include_router(get.router)
    app.include_router(delete.router)
    app.include_router(update.router)
    app.include_router(abort.router)
    app.include_router(compact.router)
    app.include_router(diff.router)
    app.include_router(fork.router)
    app.include_router(revert.router)
    app.include_router(undo.router)
    app.include_router(unrevert.router)
