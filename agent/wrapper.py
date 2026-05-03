"""
Wrapper that adapts Pydantic AI streaming to the server.py expected interface.

Uses run_stream_events() to get proper tool call events during streaming.
Supports MCP-based agents with proper lifecycle management.
"""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager, nullcontext
from dataclasses import dataclass, field
from typing import Any, AsyncIterator

from config.defaults import DEFAULT_MODEL
from .agent import create_agent_with_mcp, create_agent, get_anthropic_model_settings
from .tools.filesystem import (
    check_file_writable,
    mark_file_read,
    mark_file_written,
    set_current_session_id,
)

logger = logging.getLogger(__name__)

READ_TOOL_NAMES = {"read_file", "read_text_file"}
WRITE_TOOL_NAMES = {"write_file", "write_text_file", "edit_file"}
MOVE_TOOL_NAMES = {"move_file"}
PATH_ARG_NAMES = ("path", "file_path")


@dataclass
class StreamEvent:
    """Event emitted during streaming, compatible with server.py expectations."""

    data: str | None = None
    event_type: str = "text"
    tool_name: str | None = None
    tool_input: dict[str, Any] | None = None
    tool_output: str | None = None
    tool_id: str | None = None
    reasoning: str | None = None


def _extract_mapping(value: Any) -> dict[str, Any]:
    """Convert Pydantic AI tool args into a plain mapping."""
    try:
        if hasattr(value, "model_dump"):
            return value.model_dump()
        if isinstance(value, dict):
            return value
        return dict(value) if value else {}
    except Exception:
        return {}


def _first_path_arg(args: dict[str, Any]) -> str | None:
    """Return the first path-like argument used by common file tools."""
    for key in PATH_ARG_NAMES:
        value = args.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _read_paths_for_tool(tool_name: str, args: dict[str, Any]) -> list[str]:
    """Return paths that should be marked read after a successful tool result."""
    if tool_name in READ_TOOL_NAMES:
        path = _first_path_arg(args)
        return [path] if path else []
    if tool_name == "read_multiple_files":
        paths = args.get("paths")
        if isinstance(paths, list):
            return [path for path in paths if isinstance(path, str) and path]
    return []


def _write_paths_for_tool(tool_name: str, args: dict[str, Any]) -> list[str]:
    """Return paths that need write-safety checks before a tool call."""
    if tool_name in WRITE_TOOL_NAMES:
        path = _first_path_arg(args)
        return [path] if path else []
    if tool_name in MOVE_TOOL_NAMES:
        paths = []
        for key in ("source", "src", "path", "destination", "dest"):
            value = args.get(key)
            if isinstance(value, str) and value:
                paths.append(value)
        return paths
    return []


def _tool_output_succeeded(output: str | None) -> bool:
    """Best-effort success check for MCP textual tool results."""
    if output is None:
        return False
    normalized = output.lstrip().lower()
    return not normalized.startswith(("error:", "failed", "permission denied"))


def _enforce_file_safety_before_tool_call(
    tool_name: str,
    args: dict[str, Any],
    session_id: str | None,
) -> None:
    """Reject unsafe write-like tool calls before execution."""
    if not session_id:
        return
    set_current_session_id(session_id)
    for path in _write_paths_for_tool(tool_name, args):
        check_file_writable(path)


def _record_file_safety_after_tool_result(
    tool_name: str | None,
    args: dict[str, Any],
    output: str | None,
    session_id: str | None,
) -> None:
    """Update read/write tracking after a successful file tool result."""
    if not session_id or not tool_name or not _tool_output_succeeded(output):
        return
    set_current_session_id(session_id)
    for path in _read_paths_for_tool(tool_name, args):
        mark_file_read(path)
    for path in _write_paths_for_tool(tool_name, args):
        mark_file_written(path)


def _remember_tool_call_context(
    tool_calls_by_id: dict[str, tuple[str, dict[str, Any]]],
    tool_call_id: str | None,
    tool_name: str,
    args: dict[str, Any],
) -> None:
    """Remember tool call metadata needed when the result event arrives."""
    if tool_call_id:
        tool_calls_by_id[tool_call_id] = (tool_name, args)


def _resolve_tool_result_context(
    tool_calls_by_id: dict[str, tuple[str, dict[str, Any]]],
    tool_call_id: str | None,
    fallback_tool_name: str | None = None,
) -> tuple[str | None, dict[str, Any]]:
    """Return the tool name and input associated with a result event."""
    if tool_call_id and tool_call_id in tool_calls_by_id:
        tool_name, args = tool_calls_by_id[tool_call_id]
        return fallback_tool_name or tool_name, args
    return fallback_tool_name, {}


def _tools_disabled(tool_config: dict[str, bool] | None) -> bool:
    """Return True when a request explicitly disables all tool execution."""
    if not tool_config:
        return False
    return tool_config.get("*") is False


@dataclass
class AgentWrapper:
    """
    Wraps a Pydantic AI Agent to provide a stream_async interface
    compatible with server.py.
    """

    agent: Any
    _message_history: list[Any] = field(default_factory=list)

    async def stream_async(
        self,
        user_text: str,
        session_id: str | None = None,
        enable_thinking: bool = True,
        model_id: str | None = None,
        reasoning_effort: str | None = None,
        tools: dict[str, bool] | None = None,
    ) -> AsyncIterator[StreamEvent]:
        """
        Stream agent response, yielding events compatible with server.py.

        Uses run_stream_events() to get proper tool call events including
        FunctionToolCallEvent and FunctionToolResultEvent.

        Args:
            user_text: The user's input message
            session_id: Optional session ID for context
            enable_thinking: Enable extended thinking for better reasoning (default True)
            model_id: Optional model ID to override the agent's default model
            reasoning_effort: Optional reasoning effort level (minimal, low, medium, high)
            tools: Optional request-level tool configuration. {"*": False}
                disables all tools for the run.

        Yields:
            StreamEvent objects with text deltas, tool calls, and tool results
        """
        from pydantic_ai import AgentRunResultEvent
        from pydantic_ai.messages import (
            FunctionToolCallEvent,
            FunctionToolResultEvent,
            PartDeltaEvent,
            PartStartEvent,
            TextPartDelta,
            ToolCallPartDelta,
        )

        final_result = None
        tool_call_count = 0
        tool_calls_by_id: dict[str, tuple[str, dict[str, Any]]] = {}

        logger.debug("Starting agent stream for session %s with model=%s, reasoning_effort=%s",
                    session_id, model_id, reasoning_effort)

        # Set session ID for file safety tracking
        if session_id:
            set_current_session_id(session_id)

        # Build model settings
        model_settings = get_anthropic_model_settings(enable_thinking=enable_thinking)

        # Add reasoning effort if specified
        if reasoning_effort:
            # Map reasoning_effort to thinking budget
            # Max output tokens for Claude models
            MAX_OUTPUT_TOKENS = 64000
            reasoning_budgets = {
                "minimal": 10000,
                "low": 30000,
                "medium": 50000,  # Leave room for output within 64k limit
                "high": 54000,    # Max thinking budget (64k - 10k buffer)
            }
            budget = reasoning_budgets.get(reasoning_effort, 50000)
            model_settings['anthropic_thinking'] = {
                'type': 'enabled',
                'budget_tokens': budget,
            }
            # Ensure max_tokens is always greater than thinking budget, but capped at model limit
            model_settings['max_tokens'] = min(max(budget + 10000, 64000), MAX_OUTPUT_TOKENS)

        # Prepare run_stream_events kwargs
        run_kwargs = {
            'message_history': self._message_history,
            'model_settings': model_settings,
        }

        # Override model if specified
        if model_id:
            run_kwargs['model'] = f'anthropic:{model_id}'

        disable_tools = _tools_disabled(tools)
        if disable_tools:
            if not hasattr(self.agent, "override"):
                raise RuntimeError("agent does not support per-run tool overrides")
            logger.info("Tool execution disabled for session %s", session_id)

        override_context = (
            self.agent.override(toolsets=[], tools=[], builtin_tools=[])
            if disable_tools
            else nullcontext()
        )

        with override_context:
            async for event in self.agent.run_stream_events(user_text, **run_kwargs):
                if isinstance(event, PartStartEvent):
                    # A new part is starting - could be text or tool call
                    continue

                elif isinstance(event, PartDeltaEvent):
                    # Streaming delta for a part
                    if isinstance(event.delta, TextPartDelta):
                        # Text content streaming
                        if event.delta.content_delta:
                            yield StreamEvent(
                                data=event.delta.content_delta,
                                event_type="text"
                            )
                    elif isinstance(event.delta, ToolCallPartDelta):
                        # Tool call arguments streaming (optional to handle)
                        continue

                elif isinstance(event, FunctionToolCallEvent):
                    # Tool is being called
                    tool_name = event.part.tool_name
                    args = _extract_mapping(event.part.args)

                    _enforce_file_safety_before_tool_call(tool_name, args, session_id)
                    _remember_tool_call_context(
                        tool_calls_by_id,
                        event.part.tool_call_id,
                        tool_name,
                        args,
                    )

                    tool_call_count += 1
                    logger.debug("Tool call: %s", tool_name)

                    yield StreamEvent(
                        event_type="tool_call",
                        tool_name=tool_name,
                        tool_input=args,
                        tool_id=event.part.tool_call_id,
                    )

                elif isinstance(event, FunctionToolResultEvent):
                    # Tool has returned a result
                    # result is ToolReturnPart with tool_call_id and content
                    try:
                        content = event.result.content
                        if isinstance(content, str):
                            output = content
                        elif hasattr(content, 'model_dump_json'):
                            output = content.model_dump_json()
                        else:
                            output = str(content)
                    except Exception as e:
                        output = f"Error formatting result: {e}"

                    tool_call_id = event.result.tool_call_id
                    tool_name, tool_input = _resolve_tool_result_context(
                        tool_calls_by_id,
                        tool_call_id,
                        getattr(event.result, "tool_name", None),
                    )
                    _record_file_safety_after_tool_result(
                        tool_name,
                        tool_input,
                        output,
                        session_id,
                    )

                    yield StreamEvent(
                        event_type="tool_result",
                        tool_id=tool_call_id,
                        tool_output=output,
                        tool_name=tool_name,
                    )

                elif isinstance(event, AgentRunResultEvent):
                    # Final result - save for history update
                    final_result = event

        # Update message history after completion
        if final_result:
            self._message_history = list(final_result.result.all_messages())

        logger.debug("Agent stream complete: %d tool calls", tool_call_count)

    def reset_history(self) -> None:
        """Clear conversation history for new session."""
        self._message_history = []

    def get_history(self) -> list[Any]:
        """Get the current message history."""
        return self._message_history.copy()


@asynccontextmanager
async def create_mcp_wrapper(
    model_id: str = DEFAULT_MODEL,
    agent_name: str = "build",
    working_dir: str | None = None,
) -> AsyncIterator[AgentWrapper]:
    """
    Create an AgentWrapper with MCP tools enabled.

    This is an async context manager that properly manages MCP server lifecycles.

    Args:
        model_id: Anthropic model identifier
        agent_name: Name of the agent configuration to use
        working_dir: Working directory for filesystem operations

    Yields:
        AgentWrapper with MCP-enabled agent

    Example:
        async with create_mcp_wrapper() as wrapper:
            async for event in wrapper.stream_async("Hello"):
                print(event)
    """
    async with create_agent_with_mcp(
        model_id=model_id,
        agent_name=agent_name,
        working_dir=working_dir,
    ) as agent:
        yield AgentWrapper(agent=agent)


def create_simple_wrapper(
    model_id: str = DEFAULT_MODEL,
    agent_name: str = "build",
) -> AgentWrapper:
    """
    Create an AgentWrapper WITHOUT MCP tools (for backwards compatibility).

    Note: This creates a wrapper without MCP tools. For full functionality,
    use create_mcp_wrapper() as an async context manager instead.

    Args:
        model_id: Anthropic model identifier
        agent_name: Name of the agent configuration to use

    Returns:
        AgentWrapper with basic agent (no MCP tools)
    """
    agent = create_agent(model_id=model_id, agent_name=agent_name)
    return AgentWrapper(agent=agent)
