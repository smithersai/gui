"""
Route registration for the OpenCode API.
"""

from typing import Any


def register_routes(app: Any) -> None:
    """Register all routes with the FastAPI application."""
    from . import (
        agents,
        app as app_routes,
        commands,
        config,
        events,
        features,
        health,
        mcp,
        messages,
        models,
        permissions,
        plugins,
        project,
        review,
        sessions,
        skills,
        tools,
    )

    app.include_router(agents.router)
    app.include_router(app_routes.router)
    app.include_router(commands.router)
    app.include_router(config.router)
    app.include_router(events.router)
    app.include_router(features.router)
    app.include_router(health.router)
    app.include_router(mcp.router)
    app.include_router(models.router)
    app.include_router(permissions.router)
    app.include_router(plugins.router)
    app.include_router(project.router)
    app.include_router(review.router)
    app.include_router(skills.router)
    sessions.register_routes(app)
    messages.register_routes(app)
    tools.register_routes(app)
