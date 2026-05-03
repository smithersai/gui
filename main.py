"""
Agent server entry point with MCP support.
"""
import logging
import os
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI

from agent import create_mcp_wrapper, create_simple_wrapper
from config.defaults import DEFAULT_MODEL
from core.permissions import PermissionChecker, PermissionStore
from server import app, set_agent, set_permission_checker
from server.event_bus import get_event_bus
from server.logging_config import DISABLE_LOGGING_ENV, setup_logging
from server.security import validate_server_binding

# Initialize logging before anything else
setup_logging()
logger = logging.getLogger(__name__)

# Constants
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8000
DEFAULT_USE_MCP = True
DEFAULT_DISABLE_LOGGING = False

_wrapper_context = None
_wrapper = None
_permission_store = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage MCP wrapper lifecycle with FastAPI lifespan."""
    global _wrapper_context, _wrapper, _permission_store

    model_id = os.environ.get("ANTHROPIC_MODEL", DEFAULT_MODEL)
    working_dir = os.environ.get("WORKING_DIR", os.getcwd())
    use_mcp = os.environ.get("USE_MCP", str(DEFAULT_USE_MCP).lower()).lower() == "true"

    logger.info("Starting agent server")
    logger.info("Model: %s", model_id)
    logger.info("Working directory: %s", working_dir)
    logger.info("MCP enabled: %s", use_mcp)

    # Initialize permission system
    logger.info("Initializing permission system...")
    _permission_store = PermissionStore()
    permission_checker = PermissionChecker(_permission_store, get_event_bus())
    set_permission_checker(permission_checker)
    logger.info("Permission system ready")

    if use_mcp:
        logger.info("Initializing MCP servers...")
        _wrapper_context = create_mcp_wrapper(
            model_id=model_id,
            working_dir=working_dir,
        )
        _wrapper = await _wrapper_context.__aenter__()
        set_agent(_wrapper)
        logger.info("MCP servers ready")
    else:
        logger.info("Using simple wrapper (no MCP)")
        _wrapper = create_simple_wrapper(model_id=model_id)
        set_agent(_wrapper)

    yield

    # Cleanup
    if use_mcp and _wrapper_context:
        logger.info("Shutting down MCP servers...")
        await _wrapper_context.__aexit__(None, None, None)
        logger.info("MCP servers stopped")


app.router.lifespan_context = lifespan


def main() -> None:
    """Start server with MCP support."""
    host = os.environ.get("HOST", DEFAULT_HOST)
    port = int(os.environ.get("PORT", str(DEFAULT_PORT)))
    disable_logging = (
        os.environ.get(DISABLE_LOGGING_ENV, str(DEFAULT_DISABLE_LOGGING)).lower()
        == "true"
    )

    try:
        validate_server_binding(host)
    except ValueError as e:
        logger.error("%s", e)
        raise SystemExit(2) from e

    logger.info("Server listening on %s:%d", host, port)

    # When logging is disabled (embedded/TUI mode), disable uvicorn's logging
    if disable_logging:
        uvicorn.run(app, host=host, port=port, log_config=None, access_log=False)
    else:
        uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    main()
