"""
Interactive PTY execution tools for agent.

Provides unified_exec and write_stdin tools for running and interacting with
interactive programs in pseudo-terminal (PTY) sessions.
"""

import asyncio
import json
import os
import time
from typing import Any, Optional

from core.pty_manager import PTYManager


# Constants
DEFAULT_YIELD_TIME_MS = 100
DEFAULT_MAX_OUTPUT_TOKENS = 10000
DEFAULT_TIMEOUT_MS = None
MAX_OUTPUT_CHARS = 50000  # Approximate character limit for output


def _estimate_tokens(text: str) -> int:
    """Estimate token count from text.

    Uses a simple heuristic: ~4 characters per token.

    Args:
        text: Text to estimate

    Returns:
        Estimated token count
    """
    return len(text) // 4


def _truncate_output(text: str, max_tokens: int) -> tuple[str, bool]:
    """Truncate output to token limit.

    Args:
        text: Output text
        max_tokens: Maximum tokens

    Returns:
        Tuple of (truncated_text, was_truncated)
    """
    max_chars = max_tokens * 4  # Approximate
    if len(text) > max_chars:
        return text[:max_chars] + "\n[Output truncated]", True
    return text, False


async def _settled_process_status(
    pty_manager: PTYManager,
    session_id: str,
    attempts: int = 25,
    delay_seconds: float = 0.02,
) -> dict[str, Any]:
    """Give short-lived shell commands a brief chance to report their exit."""
    status = pty_manager.get_process_status(session_id)
    for _ in range(attempts):
        if not status["running"]:
            break
        await asyncio.sleep(delay_seconds)
        status = pty_manager.get_process_status(session_id)
    return status


async def unified_exec(
    cmd: str,
    pty_manager: PTYManager,
    workdir: Optional[str] = None,
    shell: Optional[str] = None,
    login: bool = False,
    yield_time_ms: int = DEFAULT_YIELD_TIME_MS,
    max_output_tokens: int = DEFAULT_MAX_OUTPUT_TOKENS,
    timeout_ms: Optional[int] = DEFAULT_TIMEOUT_MS,
) -> dict[str, Any]:
    """Run a command in an interactive PTY session.

    This tool starts a command in a pseudo-terminal (PTY) and returns initial
    output along with a session ID for follow-up interactions via write_stdin.

    Args:
        cmd: Command to execute
        pty_manager: PTYManager instance
        workdir: Working directory (defaults to current directory)
        shell: Shell to use (defaults to user's shell)
        login: Use login shell
        yield_time_ms: Time to wait for output before returning
        max_output_tokens: Maximum output tokens to capture
        timeout_ms: Optional command timeout in milliseconds. When provided,
            the call waits for the process to exit or terminates it on timeout.

    Returns:
        Dictionary with:
            - success: bool - Whether operation succeeded
            - session_id: str - Session identifier for follow-up
            - output: str - Initial output from command
            - running: bool - Whether process is still running
            - exit_code: int or None - Exit code if process terminated
            - error: str - Error message (if failed)

    Examples:
        >>> result = await unified_exec("python3", pty_manager=manager)
        >>> # result: {"success": True, "session_id": "abc123", "output": ">>>", "running": True}

        >>> result = await unified_exec("echo 'hello'", pty_manager=manager, yield_time_ms=500)
        >>> # result: {"success": True, "session_id": "def456", "output": "hello\\n", "running": False, "exit_code": 0}
    """
    try:
        # Create PTY session
        session = await pty_manager.create_session(
            cmd=cmd,
            workdir=workdir,
            shell=shell,
            login=login,
        )

        if timeout_ms is not None:
            deadline = time.monotonic() + (timeout_ms / 1000.0)
            output_parts: list[str] = []
            status = {"running": True, "exit_code": None}

            while status["running"]:
                remaining_ms = int((deadline - time.monotonic()) * 1000)
                if remaining_ms <= 0:
                    output = "".join(output_parts)
                    output, was_truncated = _truncate_output(output, max_output_tokens)
                    await pty_manager.close_session(session.id, force=True)
                    result = {
                        "success": False,
                        "session_id": session.id,
                        "output": output,
                        "running": False,
                        "exit_code": -9,
                        "timed_out": True,
                        "error": f"Command timed out after {timeout_ms}ms",
                    }
                    if was_truncated:
                        result["truncated"] = True
                    return result

                output_parts.append(
                    await pty_manager.read_output(
                        session.id,
                        timeout_ms=min(remaining_ms, max(yield_time_ms, 50)),
                        max_bytes=MAX_OUTPUT_CHARS,
                    )
                )
                status = pty_manager.get_process_status(session.id)

            output_parts.append(
                await pty_manager.read_output(
                    session.id,
                    timeout_ms=max(yield_time_ms, 50),
                    max_bytes=MAX_OUTPUT_CHARS,
                )
            )
            output = "".join(output_parts)
        else:
            # Wait for initial output
            output = await pty_manager.read_output(
                session.id,
                timeout_ms=yield_time_ms,
                max_bytes=MAX_OUTPUT_CHARS,
            )
            status = await _settled_process_status(pty_manager, session.id)

        # Truncate to token limit
        output, was_truncated = _truncate_output(output, max_output_tokens)

        result = {
            "success": True,
            "session_id": session.id,
            "output": output,
            "running": status["running"],
            "exit_code": status["exit_code"],
        }

        if was_truncated:
            result["truncated"] = True

        return result

    except RuntimeError as e:
        return {
            "success": False,
            "error": str(e),
        }
    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {str(e)}",
        }


async def write_stdin(
    session_id: str,
    chars: str,
    pty_manager: PTYManager,
    yield_time_ms: int = DEFAULT_YIELD_TIME_MS,
    max_output_tokens: int = DEFAULT_MAX_OUTPUT_TOKENS,
) -> dict[str, Any]:
    """Write input to a running PTY session.

    This tool writes input to a session started with unified_exec and returns
    any new output generated by the command.

    Args:
        session_id: PTY session ID from unified_exec
        chars: Characters to write (can include special chars like \\n, \\t)
        pty_manager: PTYManager instance
        yield_time_ms: Time to wait for output after writing
        max_output_tokens: Maximum output tokens to return

    Returns:
        Dictionary with:
            - success: bool - Whether operation succeeded
            - output: str - New output since last read
            - running: bool - Whether process is still running
            - exit_code: int or None - Exit code if process terminated
            - error: str - Error message (if failed)

    Examples:
        >>> result = await write_stdin("abc123", "print('hello')\\n", pty_manager=manager)
        >>> # result: {"success": True, "output": "hello\\n>>> ", "running": True}

        >>> result = await write_stdin("abc123", "exit()\\n", pty_manager=manager)
        >>> # result: {"success": True, "output": "", "running": False, "exit_code": 0}
    """
    try:
        # Write input to session
        if chars:  # Only write if there's input
            await pty_manager.write_input(session_id, chars)

        # Wait for output
        output = await pty_manager.read_output(
            session_id,
            timeout_ms=yield_time_ms,
            max_bytes=MAX_OUTPUT_CHARS,
        )

        # Truncate to token limit
        output, was_truncated = _truncate_output(output, max_output_tokens)

        status = await _settled_process_status(pty_manager, session_id)

        result = {
            "success": True,
            "output": output,
            "running": status["running"],
            "exit_code": status["exit_code"],
        }

        if was_truncated:
            result["truncated"] = True

        return result

    except KeyError:
        return {
            "success": False,
            "error": f"Session {session_id} not found",
        }
    except OSError as e:
        return {
            "success": False,
            "error": str(e),
        }
    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {str(e)}",
        }


async def close_pty_session(
    session_id: str,
    pty_manager: PTYManager,
    force: bool = False,
) -> dict[str, Any]:
    """Close a PTY session.

    Args:
        session_id: PTY session ID
        pty_manager: PTYManager instance
        force: If True, use SIGKILL instead of SIGTERM

    Returns:
        Dictionary with:
            - success: bool - Whether operation succeeded
            - error: str - Error message (if failed)
    """
    try:
        await pty_manager.close_session(session_id, force=force)
        return {"success": True}
    except KeyError:
        return {
            "success": False,
            "error": f"Session {session_id} not found",
        }
    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {str(e)}",
        }


def list_pty_sessions(pty_manager: PTYManager) -> dict[str, Any]:
    """List all active PTY sessions.

    Args:
        pty_manager: PTYManager instance

    Returns:
        Dictionary with:
            - success: bool - Whether operation succeeded
            - sessions: list - List of session information
    """
    try:
        sessions = pty_manager.list_sessions()
        return {
            "success": True,
            "sessions": sessions,
        }
    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {str(e)}",
        }
