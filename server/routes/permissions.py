"""Permission response endpoints."""

import logging
from typing import Any

from fastapi import APIRouter, Body, HTTPException

from core.permissions import Response
from ..state import get_permission_checker

logger = logging.getLogger(__name__)

router = APIRouter()


@router.post("/session/{sessionID}/permission/respond")
async def respond_to_permission(
    sessionID: str,
    response_payload: dict[str, Any] = Body(...),
) -> dict:
    """
    Respond to a permission request.

    Args:
        sessionID: The session ID
        response: The user's permission response

    Returns:
        Success confirmation
    """
    checker = get_permission_checker()
    if checker is None:
        raise HTTPException(status_code=500, detail="Permission checker not initialized")

    try:
        response = Response.from_mapping(response_payload)
        checker.respond_to_request(response)
        logger.info(
            "Permission response for session %s: %s -> %s",
            sessionID,
            response.request_id,
            response.action,
        )
        return {"success": True}
    except (KeyError, ValueError, TypeError) as e:
        logger.warning("Invalid permission response payload for session %s: %s", sessionID, e)
        raise HTTPException(status_code=400, detail="Invalid permission response payload")
    except Exception as e:
        logger.error("Failed to process permission response: %s", e)
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/session/{sessionID}/permissions")
async def get_session_permissions(sessionID: str) -> dict:
    """
    Get current permission configuration for a session.

    Args:
        sessionID: The session ID

    Returns:
        Permission configuration
    """
    checker = get_permission_checker()
    if checker is None:
        raise HTTPException(status_code=500, detail="Permission checker not initialized")

    try:
        config = checker.store.get_config(sessionID)
        return {
            "session_id": sessionID,
            "config": config.model_dump(),
        }
    except Exception as e:
        logger.error("Failed to get session permissions: %s", e)
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/session/{sessionID}/permissions")
async def clear_session_permissions(sessionID: str) -> dict:
    """
    Clear all saved permissions for a session.

    Args:
        sessionID: The session ID

    Returns:
        Success confirmation
    """
    checker = get_permission_checker()
    if checker is None:
        raise HTTPException(status_code=500, detail="Permission checker not initialized")

    try:
        checker.store.clear_session(sessionID)
        logger.info("Cleared permissions for session %s", sessionID)
        return {"success": True}
    except Exception as e:
        logger.error("Failed to clear session permissions: %s", e)
        raise HTTPException(status_code=500, detail=str(e))
