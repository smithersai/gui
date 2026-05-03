"""
Pydantic AI Agent configuration using MCP servers for tools.

Uses external MCP servers for shell and filesystem operations,
minimizing custom tool code that needs to be maintained.
"""
from __future__ import annotations

import json
import os
import sys
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

import httpx

from .browser_client import get_browser_client, is_browser_available
from .task_executor import TaskExecutor
from .tools.grep import grep as grep_impl
from .tools.lsp import diagnostics as lsp_diagnostics_impl
from .tools.lsp import find_references as lsp_find_references_impl
from .tools.lsp import go_to_definition as lsp_go_to_definition_impl
from .tools.lsp import hover as lsp_hover_impl
from .tools.lsp import touch_file as lsp_touch_file_impl
from .tools.lsp import workspace_symbol as lsp_workspace_symbol_impl
from .tools.multiedit import multiedit as multiedit_impl
from .tools.patch import patch as patch_impl
from .tools.pty_exec import unified_exec as unified_exec_impl
from .tools.pty_exec import write_stdin as write_stdin_impl
from .tools.pty_exec import close_pty_session as close_pty_session_impl
from .tools.pty_exec import list_pty_sessions as list_pty_sessions_impl
from .tools.read_file_safe import (
    DEFAULT_READ_LIMIT,
    MAX_LINE_LENGTH,
    read_file_safe as read_file_safe_impl,
    truncate_long_lines as _truncate_long_lines,
)
from .tools.web_fetch import fetch_url
from core.pty_manager import PTYManager

# Lazy import - duckduckgo is optional
_duckduckgo_search_tool = None

def _get_duckduckgo_tool():
    global _duckduckgo_search_tool
    if _duckduckgo_search_tool is None:
        try:
            from pydantic_ai.common_tools.duckduckgo import duckduckgo_search_tool
            _duckduckgo_search_tool = duckduckgo_search_tool
        except ImportError:
            _duckduckgo_search_tool = False  # Mark as unavailable
    return _duckduckgo_search_tool if _duckduckgo_search_tool else None

from config.defaults import DEFAULT_MODEL
from config.markdown_loader import load_system_prompt_markdown
from .registry import get_agent_config

# Constants
SHELL_SERVER_TIMEOUT_SECONDS = 60
FILESYSTEM_SERVER_TIMEOUT_SECONDS = 30
THINKING_BUDGET_TOKENS = 50000  # Extended thinking budget (must be < MAX_OUTPUT_TOKENS)
MAX_OUTPUT_TOKENS = 64000  # Max output tokens for Claude models

# Tool output truncation constants
MAX_BASH_OUTPUT_LENGTH = 30000


def get_anthropic_model_settings(enable_thinking: bool = True) -> dict[str, Any]:
    """Get Anthropic model settings with optional extended thinking.

    Args:
        enable_thinking: Whether to enable extended thinking (default True)

    Returns:
        Anthropic model settings configured for the agent
    """
    settings: dict[str, Any] = {
        'max_tokens': MAX_OUTPUT_TOKENS,  # Required to be > thinking budget
    }

    if enable_thinking:
        settings['anthropic_thinking'] = {
            'type': 'enabled',
            'budget_tokens': THINKING_BUDGET_TOKENS,
        }

    return settings


def _is_anthropic_model(model_id: str) -> bool:
    """Check if the model is an Anthropic/Claude model."""
    model_lower = model_id.lower()
    return "claude" in model_lower or "anthropic" in model_lower


# Simple in-memory todo storage (session-specific, doesn't need MCP)
_todo_storage: dict[str, list[dict]] = {}


def _get_todos(session_id: str) -> list[dict]:
    return _todo_storage.get(session_id, [])


def _set_todos(session_id: str, todos: list[dict]) -> None:
    _todo_storage[session_id] = todos


def _validate_todos(todos: list[dict]) -> list[dict]:
    """Validate and normalize todo items."""
    validated = []
    for todo in todos:
        validated.append({
            "content": todo.get("content", ""),
            "status": todo.get("status", "pending"),
            "activeForm": todo.get("activeForm", todo.get("content", "")),
        })
    return validated


SYSTEM_INSTRUCTIONS = """You are a helpful coding assistant with access to tools for:
- Executing shell commands (via shell tool) - output truncated at 30,000 characters
- Reading and writing files (via filesystem tools) - lines truncated at 2,000 characters
- Managing todo lists for task tracking
- Searching the web for up-to-date information

When helping users, prefer to:
1. Read relevant files first to understand context
2. Make targeted changes rather than rewriting entire files
3. Explain what you're doing and why
4. Verify changes work correctly

Important output limits:
- Shell command output is automatically truncated at 30,000 characters to prevent context overflow
- File read operations truncate individual lines at 2,000 characters
- If output is truncated, metadata will indicate the original length

Be concise but thorough. If you need to execute code to verify something works, do so.
"""


def _build_system_prompt(
    agent_config_prompt: str | None,
    working_dir: str | None,
) -> str:
    """
    Build the complete system prompt with optional markdown prepending.

    Searches for CLAUDE.md or Agents.md in the working directory and parent
    directories. If found, prepends the content to the base system prompt.

    Args:
        agent_config_prompt: Agent-specific system prompt (or None for default)
        working_dir: Working directory for markdown file search

    Returns:
        Complete system prompt string
    """
    cwd = working_dir or os.getcwd()
    markdown_content = load_system_prompt_markdown(cwd)
    base_prompt = agent_config_prompt or SYSTEM_INSTRUCTIONS

    if markdown_content:
        return f"{markdown_content}\n\n{base_prompt}"
    return base_prompt


def create_mcp_servers(working_dir: str | None = None) -> list[Any]:
    """
    Create MCP server instances for tools.

    Args:
        working_dir: Working directory for filesystem operations

    Returns:
        List of MCP server configurations
    """
    from pydantic_ai.mcp import MCPServerStdio

    cwd = working_dir or os.getcwd()

    servers = []

    # Shell server (Python-based)
    # Provides: shell command execution
    # Check for bundled MCP shell server (from PyInstaller embedded build)
    mcp_shell_path = os.environ.get('MCP_SHELL_SERVER_PATH')
    if mcp_shell_path and os.path.exists(mcp_shell_path):
        # Use bundled executable
        shell_server = MCPServerStdio(
            mcp_shell_path,
            args=[],
            timeout=SHELL_SERVER_TIMEOUT_SECONDS,
        )
    else:
        # Use current Python interpreter
        shell_server = MCPServerStdio(
            sys.executable,
            args=['-m', 'mcp_server_shell'],
            timeout=SHELL_SERVER_TIMEOUT_SECONDS,
        )
    servers.append(shell_server)

    # Filesystem server (Node.js-based, more mature)
    # Provides: read_file, write_file, list_directory, search_files, etc.
    filesystem_server = MCPServerStdio(
        'npx',
        args=['-y', '@modelcontextprotocol/server-filesystem', cwd],
        timeout=FILESYSTEM_SERVER_TIMEOUT_SECONDS,
    )
    servers.append(filesystem_server)

    return servers


@asynccontextmanager
async def create_agent_with_mcp(
    model_id: str = DEFAULT_MODEL,
    agent_name: str = "build",
    working_dir: str | None = None,
) -> AsyncIterator[Any]:
    """
    Create and configure a Pydantic AI agent with MCP tools.

    This is an async context manager that properly manages MCP server lifecycles.

    Args:
        model_id: Anthropic model identifier
        agent_name: Name of the agent configuration to use
        working_dir: Working directory for filesystem operations

    Yields:
        Configured Pydantic AI Agent with MCP tools

    Example:
        async with create_agent_with_mcp() as agent:
            result = await agent.run("List files in current directory")
    """
    agent_config = get_agent_config(agent_name)
    if agent_config is None:
        raise ValueError(f"Unknown agent: {agent_name}")

    from pydantic_ai import Agent, WebSearchTool

    # Create MCP servers
    mcp_servers = create_mcp_servers(working_dir)

    # Determine search tool based on model
    use_anthropic = _is_anthropic_model(model_id)
    builtin_tools = [WebSearchTool()] if use_anthropic else []
    ddg_tool = _get_duckduckgo_tool()
    tools = [] if use_anthropic else ([ddg_tool()] if ddg_tool else [])

    # Build system prompt with optional markdown content
    system_prompt = _build_system_prompt(agent_config.system_prompt, working_dir)

    # Check if browser tools should be enabled (Plue app running)
    browser_available = await is_browser_available()

    # Create agent with MCP toolsets
    model_name = f"anthropic:{model_id}"
    agent_kwargs = {
        "system_prompt": system_prompt,
        "toolsets": mcp_servers,
    }
    if builtin_tools:
        agent_kwargs["builtin_tools"] = builtin_tools
    if tools:
        agent_kwargs["tools"] = tools

    agent = Agent(model_name, **agent_kwargs)

    # Register simple custom tools that don't need MCP
    @agent.tool_plain
    async def todowrite(todos: list[dict], session_id: str = "default") -> str:
        """Write/replace the todo list for task tracking.

        Args:
            todos: List of todo items with 'content', 'status', and 'activeForm' fields
            session_id: Session identifier for todo storage
        """
        validated = _validate_todos(todos)
        _set_todos(session_id, validated)
        return f"Todo list updated with {len(validated)} items"

    @agent.tool_plain
    async def todoread(session_id: str = "default") -> str:
        """Read the current todo list.

        Args:
            session_id: Session identifier for todo storage
        """
        todos = _get_todos(session_id)
        if not todos:
            return "No todos found"

        lines = []
        for i, todo in enumerate(todos, 1):
            status_icon = {
                "pending": "⏳",
                "in_progress": "🔄",
                "completed": "✅",
            }.get(todo.get("status", "pending"), "⏳")
            lines.append(f"{i}. {status_icon} {todo.get('content', '')}")

        return "\n".join(lines)

    # Browser automation tools (only registered if Plue app is running)
    if browser_available:
        @agent.tool_plain
        async def browser_snapshot(
            include_hidden: bool = False,
            max_depth: int = 50,
        ) -> str:
            """Take accessibility snapshot of browser page. Returns text tree with element refs.

            The snapshot shows the page structure with clickable/interactive elements
            labeled with refs like 'e1', 'e2', etc. Use these refs with other browser tools.

            Args:
                include_hidden: Include hidden elements in snapshot
                max_depth: Maximum depth of element tree to traverse
            """
            try:
                client = get_browser_client()
                result = await client.snapshot(include_hidden, max_depth)
                if result.get("success"):
                    return result.get("text_tree", "Empty snapshot")
                return f"Error: {result.get('error', 'Unknown error')}"
            except httpx.ConnectError:
                return "Browser not connected. Ensure the Plue app is running with a browser tab open."
            except httpx.TimeoutException:
                return "Browser operation timed out."

        @agent.tool_plain
        async def browser_click(ref: str) -> str:
            """Click an element by its ref (e.g., 'e1', 'e23').

            Use browser_snapshot first to see available elements and their refs.

            Args:
                ref: Element reference from snapshot (e.g., 'e1')
            """
            try:
                client = get_browser_client()
                result = await client.click(ref)
                if result.get("success"):
                    return f"Clicked element {ref}"
                return f"Error: {result.get('error', 'Unknown error')}"
            except httpx.ConnectError:
                return "Browser not connected. Ensure the Plue app is running with a browser tab open."
            except httpx.TimeoutException:
                return "Browser operation timed out."

        @agent.tool_plain
        async def browser_type(ref: str, text: str, clear: bool = False) -> str:
            """Type text into an input element.

            Args:
                ref: Element reference from snapshot (e.g., 'e5')
                text: Text to type into the element
                clear: Whether to clear existing content first
            """
            try:
                client = get_browser_client()
                result = await client.type_text(ref, text, clear)
                if result.get("success"):
                    return f"Typed into element {ref}"
                return f"Error: {result.get('error', 'Unknown error')}"
            except httpx.ConnectError:
                return "Browser not connected. Ensure the Plue app is running with a browser tab open."
            except httpx.TimeoutException:
                return "Browser operation timed out."

        @agent.tool_plain
        async def browser_scroll(direction: str = "down", amount: int = 300) -> str:
            """Scroll the browser page.

            Args:
                direction: Scroll direction - 'up', 'down', 'left', or 'right'
                amount: Scroll amount in pixels
            """
            try:
                client = get_browser_client()
                result = await client.scroll(direction, amount)
                if result.get("success"):
                    return f"Scrolled {direction} by {amount}px"
                return f"Error: {result.get('error', 'Unknown error')}"
            except httpx.ConnectError:
                return "Browser not connected. Ensure the Plue app is running with a browser tab open."
            except httpx.TimeoutException:
                return "Browser operation timed out."

        @agent.tool_plain
        async def browser_extract(ref: str) -> str:
            """Extract text content from an element.

            Args:
                ref: Element reference from snapshot (e.g., 'e10')
            """
            try:
                client = get_browser_client()
                result = await client.extract_text(ref)
                if result.get("success"):
                    return result.get("text", "")
                return f"Error: {result.get('error', 'Unknown error')}"
            except httpx.ConnectError:
                return "Browser not connected. Ensure the Plue app is running with a browser tab open."
            except httpx.TimeoutException:
                return "Browser operation timed out."

        @agent.tool_plain
        async def browser_screenshot() -> str:
            """Take a screenshot of the browser page.

            Returns base64-encoded PNG image data.
            """
            try:
                client = get_browser_client()
                result = await client.screenshot()
                if result.get("success"):
                    return result.get("image_base64", "")
                return f"Error: {result.get('error', 'Unknown error')}"
            except httpx.ConnectError:
                return "Browser not connected. Ensure the Plue app is running with a browser tab open."
            except httpx.TimeoutException:
                return "Browser operation timed out."

        @agent.tool_plain
        async def browser_navigate(url: str) -> str:
            """Navigate the browser to a URL.

            Args:
                url: URL to navigate to (e.g., 'https://example.com')
            """
            try:
                client = get_browser_client()
                result = await client.navigate(url)
                if result.get("success"):
                    return f"Navigated to {url}"
                return f"Error: {result.get('error', 'Unknown error')}"
            except httpx.ConnectError:
                return "Browser not connected. Ensure the Plue app is running with a browser tab open."
            except httpx.TimeoutException:
                return "Browser operation timed out."

    # LSP hover tool for type information
    @agent.tool_plain
    async def hover(file_path: str, line: int, character: int) -> str:
        """Get type information and documentation for a symbol at a position.

        Use this to understand function signatures, type annotations, and
        documentation for code symbols. Useful for debugging type errors
        and understanding code semantics.

        Args:
            file_path: Absolute path to the source file
            line: 0-based line number
            character: 0-based character offset within the line
        """
        result = await lsp_hover_impl(file_path, line, character)
        if result.get("success"):
            return result.get("contents", "No hover information available")
        return f"Error: {result.get('error', 'Unknown error')}"

    # LSP diagnostics tool for errors and warnings
    @agent.tool_plain
    async def get_diagnostics(file_path: str, timeout: float = 5.0) -> str:
        """Get diagnostics (errors, warnings, hints) for a file.

        Use this to check for type errors, syntax errors, and other issues
        in code before attempting fixes. Returns formatted diagnostic info
        with severity, line/column, and message.

        Args:
            file_path: Absolute path to the source file
            timeout: Maximum time to wait for diagnostics (default 5s)
        """
        result = await lsp_diagnostics_impl(file_path, timeout=timeout)
        if result.get("success"):
            return result.get("formatted_output", "No diagnostics found")
        return f"Error: {result.get('error', 'Unknown error')}"

    # LSP touch file tool to pre-check files before editing
    @agent.tool_plain
    async def check_file_errors(file_path: str, timeout: float = 3.0) -> str:
        """Check a file for errors before editing.

        Opens the file in the language server and waits for diagnostics.
        Use this to understand the current error state before making changes.

        Args:
            file_path: Absolute path to the source file
            timeout: Maximum time to wait for diagnostics (default 3s)
        """
        result = await lsp_touch_file_impl(file_path, wait_for_diagnostics=True, timeout=timeout)
        if result.get("success"):
            summary = result.get("summary", "")
            diagnostics = result.get("diagnostics", [])
            if not diagnostics:
                return f"No errors found in {file_path}"
            return f"{summary}\n" + "\n".join(f"  {d}" for d in diagnostics)
        return f"Error: {result.get('error', 'Unknown error')}"

    # Custom file read tool with line truncation
    @agent.tool_plain
    async def read_file_safe(file_path: str, offset: int = 0, limit: int = DEFAULT_READ_LIMIT) -> str:
        """Read a file with automatic line truncation to prevent context overflow.

        This tool reads files and truncates lines longer than 2000 characters
        to prevent overwhelming the context window. Use the MCP read_text_file
        tool if you need the full untruncated content.

        Args:
            file_path: Absolute path to the file to read
            offset: Line number to start reading from (0-based, default 0)
            limit: Maximum number of lines to read (default 2000)

        Returns:
            File content with long lines truncated, or error message
        """
        cwd = working_dir or os.getcwd()
        return await read_file_safe_impl(
            file_path=file_path,
            offset=offset,
            limit=limit,
            working_dir=cwd,
        )

    # Custom web fetch tool with size limits
    @agent.tool_plain
    async def web_fetch(url: str, timeout: float = 30.0) -> str:
        """Fetch content from a URL with a 5MB size limit.

        This tool enforces a 5MB size limit to prevent memory exhaustion
        and protect against malicious servers streaming infinite data.

        Args:
            url: URL to fetch (must start with http:// or https://)
            timeout: Request timeout in seconds (default: 30)

        Returns:
            Response content as string
        """
        try:
            return await fetch_url(url, timeout=timeout)
        except ValueError as e:
            return f"Error: {str(e)}"
        except httpx.TimeoutException as e:
            return f"Error: {str(e)}"
        except Exception as e:
            return f"Error: Unexpected error fetching URL: {str(e)}"

    # Grep tool with multiline pattern matching and pagination
    @agent.tool_plain
    async def grep(
        pattern: str,
        path: str | None = None,
        glob: str | None = None,
        multiline: bool = False,
        case_insensitive: bool = False,
        max_count: int | None = None,
        context_before: int | None = None,
        context_after: int | None = None,
        context_lines: int | None = None,
        head_limit: int = 0,
        offset: int = 0,
    ) -> str:
        """Search for patterns in files using ripgrep.

        Supports multiline pattern matching, context lines, and pagination for large result sets.

        Args:
            pattern: Regular expression pattern to search for
            path: Directory or file to search in (defaults to working directory)
            glob: File pattern to filter (e.g., "*.py", "*.{ts,tsx}")
            multiline: Enable multiline mode where . matches newlines and patterns can span lines
            case_insensitive: Case-insensitive search
            max_count: Maximum number of matches per file
            context_before: Number of lines to show before each match
            context_after: Number of lines to show after each match
            context_lines: Number of lines to show before AND after each match (overrides context_before/after)
            head_limit: Limit output to first N matches (0 = unlimited)
            offset: Skip first N matches before applying head_limit (0 = start from beginning)

        Examples:
            # Single-line search (default)
            grep(pattern="def authenticate", glob="*.py")

            # Get first 10 results
            grep(pattern="error", head_limit=10)

            # Get second page (items 11-20)
            grep(pattern="error", offset=10, head_limit=10)

            # Search with context lines
            grep(pattern="error", context_lines=3, glob="*.py")

            # Multi-line search for function with body
            grep(pattern=r"def authenticate\\(.*?\\):[\\s\\S]*?return", multiline=True, glob="*.py")

            # Find multi-line docstrings with pagination
            grep(pattern=r'\"\"\"[\\s\\S]*?\"\"\"', multiline=True, glob="*.py", head_limit=5)

        Returns:
            Formatted search results or error message
        """
        cwd = working_dir or os.getcwd()
        result = await grep_impl(
            pattern=pattern,
            path=path,
            glob=glob,
            multiline=multiline,
            case_insensitive=case_insensitive,
            max_count=max_count,
            working_dir=cwd,
            context_before=context_before,
            context_after=context_after,
            context_lines=context_lines,
            head_limit=head_limit,
            offset=offset,
        )
        if result.get("success"):
            return result.get("formatted_output", "No matches found")
        return f"Error: {result.get('error', 'Unknown error')}"

    # MultiEdit tool for atomic multi-file edits
    @agent.tool_plain
    async def multiedit(file_path: str, edits: list[dict]) -> str:
        """Perform multiple find-and-replace operations on a single file atomically.

        All edits are validated before any are applied. Each edit operates on
        the result of the previous edit, allowing dependent changes.

        For single edits, use a 1-element edits array.

        Args:
            file_path: Absolute path to file to modify
            edits: Array of edit operations, each with:
                - old_string: Text to replace (empty creates file on first edit)
                - new_string: Replacement text
                - replace_all: (optional) Replace all occurrences (default: false)

        Returns:
            Success message with edit count, or error with details
        """
        cwd = working_dir or os.getcwd()
        result = await multiedit_impl(file_path, edits, working_dir=cwd)
        if result.get("success"):
            edit_count = result.get("edit_count", 0)
            rel_path = result.get("file_path", file_path)
            return f"Applied {edit_count} edit(s) to {rel_path}"
        return f"Error: {result.get('error', 'Unknown error')}"

    @agent.tool_plain
    async def patch(patch_text: str) -> str:
        """Apply a patch to modify multiple files with context-aware changes.

        Supports adding, updating, deleting, and moving files in a single atomic operation.
        Uses a custom patch format with Begin/End markers and supports context-aware matching.

        Args:
            patch_text: The full patch text in custom format with *** Begin Patch and *** End Patch markers

        Returns:
            Summary of changes made including list of affected files

        Patch Format:
            *** Begin Patch
            *** Add File: path/to/new/file.py
            +line 1 content
            +line 2 content

            *** Update File: path/to/existing/file.py
            @@ context line for finding location
            -old line to remove
            +new line to add
             unchanged line

            *** Delete File: path/to/old/file.py
            *** End Patch
        """
        cwd = working_dir or os.getcwd()
        return await patch_impl(patch_text, working_dir=cwd)

    # PTY execution tools for interactive commands
    pty_manager = PTYManager()

    @agent.tool_plain
    async def unified_exec(
        cmd: str,
        workdir: str | None = None,
        shell: str | None = None,
        login: bool = False,
        yield_time_ms: int = 100,
        max_output_tokens: int = 10000,
        timeout_ms: int | None = None,
    ) -> str:
        """Run a command in an interactive PTY session.

        This tool starts a command in a pseudo-terminal (PTY) and returns initial
        output along with a session ID for follow-up interactions via write_stdin.

        Use this for interactive programs that require TTY (like npm, pip, vim, less)
        or when you need to send input to a running process.

        Args:
            cmd: Command to execute
            workdir: Working directory (defaults to current directory)
            shell: Shell to use (defaults to user's shell)
            login: Use login shell
            yield_time_ms: Time to wait for output before returning (default 100ms)
            max_output_tokens: Maximum output tokens to capture (default 10000)
            timeout_ms: Command timeout in milliseconds. When set, the command
                must finish before the deadline or it is terminated.

        Returns:
            JSON string with:
            - success: Whether operation succeeded
            - session_id: Session identifier for follow-up
            - output: Initial output from command
            - running: Whether process is still running
            - exit_code: Exit code if process terminated
            - error: Error message (if failed)

        Example:
            # Start Python REPL
            result = unified_exec(cmd="python3", yield_time_ms=500)
            # Returns: {"success": true, "session_id": "abc123", "output": ">>>", "running": true}

            # Run npm install (may prompt for input)
            result = unified_exec(cmd="npm install", workdir="/path/to/project", yield_time_ms=5000)
        """
        cwd = workdir or working_dir or os.getcwd()
        result = await unified_exec_impl(
            cmd=cmd,
            pty_manager=pty_manager,
            workdir=cwd,
            shell=shell,
            login=login,
            yield_time_ms=yield_time_ms,
            max_output_tokens=max_output_tokens,
            timeout_ms=timeout_ms,
        )
        return json.dumps(result, indent=2)

    @agent.tool_plain
    async def write_stdin(
        session_id: str,
        chars: str,
        yield_time_ms: int = 100,
        max_output_tokens: int = 10000,
    ) -> str:
        """Write input to a running PTY session.

        This tool writes input to a session started with unified_exec and returns
        any new output generated by the command.

        Args:
            session_id: PTY session ID from unified_exec
            chars: Characters to write (can include special chars like \\n, \\t)
            yield_time_ms: Time to wait for output after writing (default 100ms)
            max_output_tokens: Maximum output tokens to return (default 10000)

        Returns:
            JSON string with:
            - success: Whether operation succeeded
            - output: New output since last read
            - running: Whether process is still running
            - exit_code: Exit code if process terminated
            - error: Error message (if failed)

        Example:
            # Send command to Python REPL
            result = write_stdin(session_id="abc123", chars="print('hello')\\n")
            # Returns: {"success": true, "output": "hello\\n>>> ", "running": true}

            # Exit REPL
            result = write_stdin(session_id="abc123", chars="exit()\\n")
        """
        result = await write_stdin_impl(
            session_id=session_id,
            chars=chars,
            pty_manager=pty_manager,
            yield_time_ms=yield_time_ms,
            max_output_tokens=max_output_tokens,
        )
        return json.dumps(result, indent=2)

    @agent.tool_plain
    async def close_pty_session(
        session_id: str,
        force: bool = False,
    ) -> str:
        """Close a PTY session.

        Args:
            session_id: PTY session ID from unified_exec
            force: If True, use SIGKILL instead of SIGTERM

        Returns:
            JSON string with success status
        """
        result = await close_pty_session_impl(
            session_id=session_id,
            pty_manager=pty_manager,
            force=force,
        )
        return json.dumps(result, indent=2)

    @agent.tool_plain
    async def list_pty_sessions() -> str:
        """List all active PTY sessions.

        Returns:
            JSON string with list of session information
        """
        result = list_pty_sessions_impl(pty_manager=pty_manager)
        return json.dumps(result, indent=2)

    # Task delegation tools for spawning sub-agents
    task_executor = TaskExecutor(model_id=model_id, working_dir=working_dir)

    @agent.tool_plain
    async def task(
        objective: str,
        subagent_type: str = "general",
        context: dict[str, Any] | None = None,
        timeout_seconds: int = 120,
        session_id: str = "default",
    ) -> str:
        """Delegate a task to a specialized sub-agent for parallel execution.

        Use this tool to break down complex work into parallel subtasks that can
        be executed by specialized agents. Results are returned as structured data.

        Args:
            objective: Clear description of what the sub-agent should accomplish
            subagent_type: Type of agent to spawn:
                - "explore": Fast codebase exploration and search
                - "plan": Analysis and planning (read-only)
                - "general": Implementation and execution (full tools)
            context: Optional context dictionary to pass to sub-agent
            timeout_seconds: Maximum execution time (default 120s)
            session_id: Session identifier for task tracking

        Returns:
            JSON string with task results including:
            - task_id: Unique identifier for the task
            - status: "completed", "failed", "timeout"
            - result: Sub-agent's response or output
            - duration: Execution time in seconds
            - agent_type: Which sub-agent type was used

        Example:
            # Explore codebase for authentication-related code
            result = await task(
                objective="Find all files related to user authentication and authorization",
                subagent_type="explore"
            )

            # Analyze test coverage in parallel
            test_result = await task(
                objective="Analyze test coverage for the auth module",
                subagent_type="plan"
            )
        """
        result = await task_executor.execute_task(
            objective=objective,
            subagent_type=subagent_type,
            context=context,
            timeout_seconds=timeout_seconds,
        )
        return json.dumps(result.to_dict(), indent=2)

    @agent.tool_plain
    async def task_parallel(
        tasks: list[dict[str, Any]],
        timeout_seconds: int = 120,
        session_id: str = "default",
    ) -> str:
        """Execute multiple tasks in parallel with specialized sub-agents.

        Use this to run multiple independent subtasks concurrently for faster
        execution. Each task can use a different specialized agent type.

        Args:
            tasks: List of task specifications, each containing:
                - objective: What the sub-agent should accomplish
                - subagent_type: (optional) Agent type (default "general")
                - context: (optional) Context dictionary
            timeout_seconds: Timeout for each individual task (default 120s)
            session_id: Session identifier for task tracking

        Returns:
            JSON array of task results, each with the same structure as the
            task tool output.

        Example:
            # Parallel codebase exploration
            results = await task_parallel([
                {
                    "objective": "Find all authentication-related files",
                    "subagent_type": "explore"
                },
                {
                    "objective": "Find all database migration files",
                    "subagent_type": "explore"
                },
                {
                    "objective": "Run pytest on the auth module",
                    "subagent_type": "general"
                }
            ])
        """
        results = await task_executor.execute_parallel(
            tasks=tasks,
            timeout_seconds=timeout_seconds,
        )
        return json.dumps([r.to_dict() for r in results], indent=2)

    # Use async context manager to properly manage MCP server lifecycles
    async with agent:
        yield agent


def create_agent(
    model_id: str = DEFAULT_MODEL,
    api_key: str | None = None,
    agent_name: str = "build",
    working_dir: str | None = None,
) -> Any:
    """
    Create a simple agent WITHOUT MCP tools (for backwards compatibility).

    Note: This creates an agent without MCP tools. For full functionality,
    use create_agent_with_mcp() as an async context manager instead.

    Args:
        model_id: Anthropic model identifier
        api_key: Optional API key (defaults to ANTHROPIC_API_KEY env var)
        agent_name: Name of the agent configuration to use
        working_dir: Working directory for markdown file search

    Returns:
        Configured Pydantic AI Agent (without MCP tools)
    """
    agent_config = get_agent_config(agent_name)
    if agent_config is None:
        raise ValueError(f"Unknown agent: {agent_name}")

    from pydantic_ai import Agent, WebSearchTool

    # Determine search tool based on model
    use_anthropic = _is_anthropic_model(model_id)
    builtin_tools = [WebSearchTool()] if use_anthropic else []
    ddg_tool = _get_duckduckgo_tool()
    tools = [] if use_anthropic else ([ddg_tool()] if ddg_tool else [])

    # Build system prompt with optional markdown content
    system_prompt = _build_system_prompt(agent_config.system_prompt, working_dir)

    model_name = f"anthropic:{model_id}"
    agent_kwargs = {
        "system_prompt": system_prompt,
    }
    if builtin_tools:
        agent_kwargs["builtin_tools"] = builtin_tools
    if tools:
        agent_kwargs["tools"] = tools

    agent = Agent(model_name, **agent_kwargs)

    # Register simple todo tools
    @agent.tool_plain
    async def todowrite(todos: list[dict], session_id: str = "default") -> str:
        """Write/replace the todo list for task tracking.

        Args:
            todos: List of todo items with 'content', 'status', and 'activeForm' fields
            session_id: Session identifier for todo storage
        """
        validated = _validate_todos(todos)
        _set_todos(session_id, validated)
        return f"Todo list updated with {len(validated)} items"

    @agent.tool_plain
    async def todoread(session_id: str = "default") -> str:
        """Read the current todo list.

        Args:
            session_id: Session identifier for todo storage
        """
        todos = _get_todos(session_id)
        if not todos:
            return "No todos found"

        lines = []
        for i, todo in enumerate(todos, 1):
            status_icon = {
                "pending": "⏳",
                "in_progress": "🔄",
                "completed": "✅",
            }.get(todo.get("status", "pending"), "⏳")
            lines.append(f"{i}. {status_icon} {todo.get('content', '')}")

        return "\n".join(lines)

    return agent
