"""
Message operations.

Provides functions for managing messages including listing, retrieving,
and streaming responses from the agent.
"""

from __future__ import annotations

import logging
import os
import time
from typing import Any, AsyncGenerator, Protocol, TYPE_CHECKING

from config.defaults import DEFAULT_AUTO_COMPACT_TOKEN_LIMIT
from config.features import feature_manager
from config.skills import expand_skill_references, get_skill_registry
from .compaction import should_auto_compact, compact_conversation
from .events import Event, EventBus
from .exceptions import NotFoundError
from .models import FileDiff, SessionSummary, gen_id
from .snapshots import (
    append_snapshot_history,
    compute_diff,
    get_changed_files,
    track_snapshot,
)
from .state import session_messages, sessions, session_ghost_commits

if TYPE_CHECKING:
    from plugins.pipeline import PluginPipeline

logger = logging.getLogger(__name__)


class Agent(Protocol):
    """Protocol for agent implementations."""

    def stream_async(self, prompt: str) -> AsyncGenerator[Any, None]:
        """Stream responses for a prompt."""
        ...


def list_messages(session_id: str, limit: int | None = None) -> list[dict[str, Any]]:
    """
    List messages in a session.

    Args:
        session_id: The session ID
        limit: Maximum number of messages to return

    Returns:
        List of messages

    Raises:
        NotFoundError: If the session is not found
    """
    if session_id not in sessions:
        raise NotFoundError("Session", session_id)

    messages = session_messages.get(session_id, [])
    if limit:
        messages = messages[-limit:]
    return messages


def get_message(session_id: str, message_id: str) -> dict[str, Any]:
    """
    Get a specific message.

    Args:
        session_id: The session ID
        message_id: The message ID

    Returns:
        The message

    Raises:
        NotFoundError: If the session or message is not found
    """
    if session_id not in sessions:
        raise NotFoundError("Session", session_id)

    for msg in session_messages.get(session_id, []):
        if msg["info"]["id"] == message_id:
            return msg

    raise NotFoundError("Message", message_id)


async def send_message(
    session_id: str,
    parts: list[dict[str, Any]],
    agent: Agent | None,
    event_bus: EventBus,
    message_id: str | None = None,
    agent_name: str = "default",
    model_id: str = "default",
    provider_id: str = "default",
    reasoning_effort: str | None = None,
    tools: dict[str, bool] | None = None,
    pipeline: PluginPipeline | None = None,
) -> AsyncGenerator[Event, None]:
    """
    Send a message and stream the response.

    This is an async generator that yields events as the agent processes the message.

    Args:
        session_id: The session ID
        parts: List of message parts (text, file, etc.)
        agent: The agent to use for generating responses
        event_bus: EventBus for publishing events
        message_id: Optional message ID (generated if not provided)
        agent_name: Agent name for metadata
        model_id: Model ID for metadata
        provider_id: Provider ID for metadata
        reasoning_effort: Optional reasoning effort level (minimal, low, medium, high)
        tools: Optional request-level tool configuration
        pipeline: Optional plugin pipeline for hook execution

    Yields:
        Events as the message is processed

    Raises:
        NotFoundError: If the session is not found
    """
    if session_id not in sessions:
        raise NotFoundError("Session", session_id)

    logger.info("Processing message for session %s", session_id)
    message_start_time = time.perf_counter()
    now = time.time()

    # Create user message
    user_msg_id = message_id or gen_id("msg_")
    user_msg: dict[str, Any] = {
        "info": {
            "id": user_msg_id,
            "sessionID": session_id,
            "role": "user",
            "time": {"created": now},
            "agent": agent_name,
            "model": {"providerID": provider_id, "modelID": model_id},
        },
        "parts": [],
    }
    if tools is not None:
        user_msg["info"]["tools"] = tools

    # Add text parts from request
    for part in parts:
        if part.get("type") == "text":
            part_id = gen_id("prt_")
            user_msg["parts"].append(
                {
                    "id": part_id,
                    "sessionID": session_id,
                    "messageID": user_msg_id,
                    "type": "text",
                    "text": part.get("text", ""),
                }
            )

    session_messages[session_id].append(user_msg)
    await event_bus.publish(
        Event(type="message.updated", properties={"info": user_msg["info"]})
    )

    # Extract user text for plugin context
    user_text = ""
    for part in parts:
        if part.get("type") == "text":
            user_text += part.get("text", "")

    # === PLUGIN HOOK: on_begin ===
    plugin_ctx = None
    if pipeline:
        from plugins.models import PluginContext

        plugin_ctx = PluginContext(
            session_id=session_id,
            working_dir=os.getcwd(),
            user_text=user_text,
        )
        await pipeline.on_begin(plugin_ctx)

    # Create assistant message
    asst_msg_id = gen_id("msg_")
    asst_msg: dict[str, Any] = {
        "info": {
            "id": asst_msg_id,
            "sessionID": session_id,
            "role": "assistant",
            "time": {"created": time.time()},
            "parentID": user_msg_id,
            "modelID": model_id,
            "providerID": provider_id,
            "mode": "normal",
            "path": {"cwd": os.getcwd(), "root": os.getcwd()},
            "cost": 0.0,
            "tokens": {
                "input": 0,
                "output": 0,
                "reasoning": 0,
                "cache": {"read": 0, "write": 0},
            },
        },
        "parts": [],
    }

    # Yield assistant message creation event
    yield Event(type="message.updated", properties={"info": asst_msg["info"]})

    # Capture step start snapshot
    step_start_hash = track_snapshot(session_id)

    if agent is None:
        # No agent configured - return error part
        error_part_id = gen_id("prt_")
        error_part = {
            "id": error_part_id,
            "sessionID": session_id,
            "messageID": asst_msg_id,
            "type": "text",
            "text": "Agent not configured. Please set up an agent using set_agent().",
        }
        asst_msg["parts"].append(error_part)
        yield Event(type="part.updated", properties=error_part)
    else:
        # Stream from agent
        text_part_id = gen_id("prt_")
        text_content = ""
        reasoning_part_id: str | None = None
        reasoning_content = ""
        tool_parts: dict[str, dict[str, Any]] = {}  # tool_id -> tool_part

        try:
            # Expand skill references in user message
            expanded_text, skills_used = expand_skill_references(
                user_text, get_skill_registry()
            )
            if skills_used:
                logger.info("Expanded skills in message: %s", skills_used)

            # Pass model_id and reasoning_effort to agent
            async for event in agent.stream_async(
                expanded_text,
                session_id=session_id,
                model_id=model_id,
                reasoning_effort=reasoning_effort,
                tools=tools,
            ):
                event_type = getattr(event, "event_type", "text")

                if event_type == "text" and hasattr(event, "data") and event.data:
                    # Text content
                    text_content += event.data
                    text_part = {
                        "id": text_part_id,
                        "sessionID": session_id,
                        "messageID": asst_msg_id,
                        "type": "text",
                        "text": text_content,
                    }
                    yield Event(type="part.updated", properties=text_part)

                elif (
                    event_type == "reasoning"
                    and hasattr(event, "reasoning")
                    and event.reasoning
                ):
                    # Reasoning/thinking content
                    if reasoning_part_id is None:
                        reasoning_part_id = gen_id("prt_")
                    reasoning_content += event.reasoning
                    reasoning_part = {
                        "id": reasoning_part_id,
                        "sessionID": session_id,
                        "messageID": asst_msg_id,
                        "type": "reasoning",
                        "text": reasoning_content,
                        "time": {"start": time.time()},
                    }
                    yield Event(type="part.updated", properties=reasoning_part)

                elif event_type == "tool_call":
                    # Tool invocation started
                    logger.info("Tool call: %s", event.tool_name)

                    # === PLUGIN HOOK: on_tool_call ===
                    tool_name = event.tool_name
                    tool_input = event.tool_input or {}
                    if pipeline and plugin_ctx:
                        from plugins.models import ToolCall as PluginToolCall

                        plugin_call = PluginToolCall(
                            tool_name=tool_name,
                            tool_call_id=event.tool_id or "",
                            input=tool_input,
                        )
                        modified_call = await pipeline.on_tool_call(
                            plugin_ctx, plugin_call
                        )
                        # Use potentially modified values
                        tool_name = modified_call.tool_name
                        tool_input = modified_call.input

                    tool_part_id = gen_id("prt_")
                    tool_part = {
                        "id": tool_part_id,
                        "sessionID": session_id,
                        "messageID": asst_msg_id,
                        "type": "tool",
                        "tool": tool_name,
                        "state": {
                            "status": "running",
                            "input": tool_input,
                            "title": tool_name,
                            "time": {"start": time.time()},
                        },
                    }
                    if event.tool_id:
                        tool_parts[event.tool_id] = tool_part
                    yield Event(type="part.updated", properties=tool_part)

                elif event_type == "tool_result":
                    # Tool execution completed
                    if event.tool_id and event.tool_id in tool_parts:
                        tool_part = tool_parts[event.tool_id]
                        tool_output = event.tool_output

                        # === PLUGIN HOOK: on_tool_result ===
                        if pipeline and plugin_ctx:
                            from plugins.models import (
                                ToolCall as PluginToolCall,
                                ToolResult as PluginToolResult,
                            )

                            plugin_call = PluginToolCall(
                                tool_name=tool_part["tool"],
                                tool_call_id=event.tool_id,
                                input=tool_part["state"]["input"],
                            )
                            plugin_result = PluginToolResult(
                                tool_call_id=event.tool_id,
                                tool_name=tool_part["tool"],
                                output=tool_output or "",
                            )
                            modified_result = await pipeline.on_tool_result(
                                plugin_ctx, plugin_call, plugin_result
                            )
                            # Use potentially modified output
                            tool_output = modified_result.output

                        tool_part["state"]["status"] = "completed"
                        tool_part["state"]["output"] = tool_output
                        tool_part["state"]["time"]["end"] = time.time()
                        yield Event(type="part.updated", properties=tool_part)

            # === PLUGIN HOOK: on_final ===
            if pipeline and plugin_ctx and text_content:
                text_content = await pipeline.on_final(plugin_ctx, text_content)

            # Final text part
            if text_content:
                asst_msg["parts"].append(
                    {
                        "id": text_part_id,
                        "sessionID": session_id,
                        "messageID": asst_msg_id,
                        "type": "text",
                        "text": text_content,
                    }
                )

            # Final reasoning part
            if reasoning_content and reasoning_part_id:
                asst_msg["parts"].append(
                    {
                        "id": reasoning_part_id,
                        "sessionID": session_id,
                        "messageID": asst_msg_id,
                        "type": "reasoning",
                        "text": reasoning_content,
                    }
                )

            # Final tool parts
            for tool_part in tool_parts.values():
                asst_msg["parts"].append(tool_part)

        except Exception as e:
            logger.exception("Error during agent streaming for session %s", session_id)
            error_part_id = gen_id("prt_")
            error_part = {
                "id": error_part_id,
                "sessionID": session_id,
                "messageID": asst_msg_id,
                "type": "text",
                "text": f"Error: {str(e)}",
            }
            asst_msg["parts"].append(error_part)
            yield Event(type="part.updated", properties=error_part)

    # Complete assistant message
    asst_msg["info"]["time"]["completed"] = time.time()
    session_messages[session_id].append(asst_msg)

    # Capture step finish snapshot and compute diff
    if step_start_hash:
        logger.debug("Tracking finish snapshot for session %s", session_id)
        step_finish_hash = track_snapshot(session_id)
        if step_finish_hash:
            append_snapshot_history(session_id, step_finish_hash)

            # Compute diff and update session summary
            changed_files = get_changed_files(
                session_id, step_start_hash, step_finish_hash
            )
            if changed_files:
                logger.debug("Computing diff: %d files changed", len(changed_files))
                diffs = compute_diff(session_id, step_start_hash, step_finish_hash)
                sessions[session_id].summary = SessionSummary(
                    additions=sum(d.additions for d in diffs),
                    deletions=sum(d.deletions for d in diffs),
                    files=len(diffs),
                    diffs=diffs,
                )
                logger.info(
                    "Session %s: %d files changed (+%d/-%d)",
                    session_id,
                    len(diffs),
                    sum(d.additions for d in diffs),
                    sum(d.deletions for d in diffs),
                )

    # Check for auto-compaction
    try:
        if should_auto_compact(session_id, DEFAULT_AUTO_COMPACT_TOKEN_LIMIT):
            logger.info("Auto-compacting session %s", session_id)
            compaction_result = await compact_conversation(
                session_id=session_id,
                event_bus=event_bus,
            )
            if compaction_result.compacted:
                logger.info(
                    "Session %s compacted: %d messages -> summary (saved %d tokens)",
                    session_id,
                    compaction_result.messages_removed,
                    compaction_result.tokens_before - compaction_result.tokens_after,
                )
    except Exception as e:
        # Don't fail the message if compaction fails
        logger.warning("Auto-compaction failed for session %s: %s", session_id, str(e))

    # Update session timestamp
    sessions[session_id].time.updated = time.time()

    # Create ghost commit if enabled
    if feature_manager.is_enabled("ghost_commit"):
        ghost_manager = session_ghost_commits.get(session_id)
        if ghost_manager:
            session = sessions[session_id]
            # Increment turn number
            if session.ghost_commit:
                session.ghost_commit.turn_number += 1
                turn_number = session.ghost_commit.turn_number
            else:
                turn_number = 1

            # Extract summary from first text part if available
            summary = ""
            if text_content:
                # Use first line or first 50 chars as summary
                first_line = text_content.split("\n")[0]
                summary = first_line[:50] if len(first_line) > 50 else first_line

            # Create ghost commit
            commit_hash = ghost_manager.create_ghost_commit(turn_number, summary)
            if commit_hash:
                # Update session ghost_commit info
                if not session.ghost_commit:
                    from .models import GhostCommitInfo
                    session.ghost_commit = GhostCommitInfo(enabled=True)
                session.ghost_commit.commit_refs.append(commit_hash)
                session.ghost_commit.turn_number = turn_number

                # Yield ghost commit event
                yield Event(
                    type="ghost_commit.created",
                    properties={
                        "turn": turn_number,
                        "commit": commit_hash,
                        "summary": summary
                    }
                )

    # === PLUGIN HOOK: on_done ===
    if pipeline and plugin_ctx:
        await pipeline.on_done(plugin_ctx)

    message_duration_ms = (time.perf_counter() - message_start_time) * 1000
    logger.info(
        "Message complete for session %s (%.1fms)", session_id, message_duration_ms
    )

    yield Event(type="message.updated", properties={"info": asst_msg["info"]})
