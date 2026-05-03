"""
FastAPI application setup and configuration.
"""

import logging
import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from server.middleware import RequestLoggingMiddleware
from server.routes import register_routes
from server.security import APIKeyMiddleware


# =============================================================================
# Constants
# =============================================================================

DEFAULT_CORS_ORIGINS = (
    "http://localhost:3000,http://127.0.0.1:3000,"
    "http://localhost:5173,http://127.0.0.1:5173"
)
API_TITLE = "OpenCode API"
API_VERSION = "1.0.0"

logger = logging.getLogger(__name__)


# =============================================================================
# FastAPI App
# =============================================================================

app = FastAPI(title=API_TITLE, version=API_VERSION)


# =============================================================================
# CORS Configuration
# =============================================================================

cors_origins_env = os.environ.get("CORS_ORIGINS", DEFAULT_CORS_ORIGINS)
cors_origins = (
    [origin.strip() for origin in cors_origins_env.split(",")]
    if cors_origins_env
    else []
)
allow_credentials = "*" not in cors_origins
if "*" in cors_origins:
    logger.warning("Wildcard CORS origin configured; credentials are disabled")

app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_credentials=allow_credentials,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Auth runs before CORS, while request logging wraps both.
app.add_middleware(APIKeyMiddleware)
app.add_middleware(RequestLoggingMiddleware)


# =============================================================================
# Routes
# =============================================================================

register_routes(app)
