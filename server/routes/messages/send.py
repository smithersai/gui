"""
Send message endpoint with streaming.
"""

import json
import logging
from typing import AsyncGenerator

from fastapi import APIRouter, HTTPException, Query
from sse_starlette.sse import EventSourceResponse

from config import DEFAULT_MODEL, DEFAULT_REASONING_EFFORT
from config.features import feature_manager
from core import NotFoundError, send_message
from core.state import sessions

from ...event_bus import get_event_bus
from ...requests import PromptRequest
from ...state import get_agent

logger = logging.getLogger(__name__)


router = APIRouter()


@router.post("/session/{sessionID}/message")
async def send_message_route(
    sessionID: str, request: PromptRequest, directory: str | None = Query(None)
) -> EventSourceResponse:
    """Send a prompt and stream the response via SSE."""

    async def stream_response() -> AsyncGenerator[dict, None]:
        try:
            # Get session to access model settings
            session = sessions.get(sessionID)
            if not session:
                yield {
                    "event": "error",
                    "data": json.dumps({"error": "Session not found"}),
                }
                return

            # Determine model_id: request.model.modelID > session.model > DEFAULT_MODEL
            model_id = DEFAULT_MODEL
            provider_id = "default"
            if request.model:
                model_id = request.model.modelID
                provider_id = request.model.providerID
            elif session.model:
                model_id = session.model
                provider_id = "anthropic"

            # Get reasoning_effort from session settings (no request override currently)
            reasoning_effort = session.reasoning_effort or DEFAULT_REASONING_EFFORT

            # Load plugins if feature is enabled and session has plugins configured
            pipeline = None
            if feature_manager.is_enabled("plugins") and session.plugins:
                try:
                    from plugins import PluginPipeline, plugin_registry

                    loaded_plugins = plugin_registry.load_many(session.plugins)
                    if loaded_plugins:
                        pipeline = PluginPipeline(loaded_plugins)
                        logger.info(
                            "Loaded %d plugins for session %s: %s",
                            len(loaded_plugins),
                            sessionID,
                            [p.name for p in loaded_plugins],
                        )
                except Exception as e:
                    logger.warning("Failed to load plugins for session %s: %s", sessionID, e)

            logger.info(
                "Processing message for session %s with model=%s, reasoning_effort=%s",
                sessionID,
                model_id,
                reasoning_effort,
            )

            async for event in send_message(
                session_id=sessionID,
                parts=request.parts,
                agent=get_agent(),
                event_bus=get_event_bus(),
                message_id=request.messageID,
                agent_name=request.agent or "default",
                model_id=model_id,
                provider_id=provider_id,
                reasoning_effort=reasoning_effort,
                tools=request.tools,
                pipeline=pipeline,
            ):
                yield {
                    "event": event.type,
                    "data": json.dumps(
                        {"type": event.type, "properties": event.properties}
                    ),
                }
        except NotFoundError:
            # Can't raise HTTPException in generator, yield error event
            logger.warning("Session not found during streaming: %s", sessionID)
            yield {
                "event": "error",
                "data": json.dumps({"error": "Session not found"}),
            }
        except Exception as e:
            # Log unexpected errors during streaming
            logger.exception("Error during message streaming for session %s", sessionID)
            yield {
                "event": "error",
                "data": json.dumps({"error": str(e)}),
            }

    return EventSourceResponse(stream_response())
