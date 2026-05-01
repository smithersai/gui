"""
Tests for PTY execution tools.

Tests the unified_exec and write_stdin tools for interactive command execution.
"""

import asyncio
import pytest

from agent.tools.pty_exec import (
    unified_exec,
    write_stdin,
    close_pty_session,
    list_pty_sessions,
)
from core.pty_manager import PTYManager


@pytest.fixture
async def pty_manager():
    """Create a PTYManager instance for testing."""
    manager = PTYManager()
    yield manager
    # Cleanup all sessions after test
    await manager.cleanup_all()


@pytest.mark.asyncio
async def test_unified_exec_simple_command(pty_manager):
    """Test executing a simple command that exits quickly."""
    result = await unified_exec(
        cmd="echo 'hello world'",
        pty_manager=pty_manager,
        yield_time_ms=500,
    )

    assert result["success"] is True
    assert "hello world" in result["output"]
    assert result["running"] is False  # Should have exited
    assert result["exit_code"] == 0


@pytest.mark.asyncio
async def test_unified_exec_long_running(pty_manager):
    """Test executing a command that keeps running."""
    result = await unified_exec(
        cmd="cat",  # cat waits for input
        pty_manager=pty_manager,
        yield_time_ms=200,
    )

    assert result["success"] is True
    assert result["running"] is True
    assert result["exit_code"] is None
    assert "session_id" in result

    # Cleanup
    await close_pty_session(result["session_id"], pty_manager=pty_manager, force=True)


@pytest.mark.asyncio
async def test_write_stdin_interaction(pty_manager):
    """Test writing stdin to an interactive session."""
    # Start Python REPL
    start_result = await unified_exec(
        cmd="python3 -i",
        pty_manager=pty_manager,
        yield_time_ms=500,
    )

    assert start_result["success"] is True
    assert start_result["running"] is True
    session_id = start_result["session_id"]

    # Send a command
    write_result = await write_stdin(
        session_id=session_id,
        chars="print('hello from stdin')\n",
        pty_manager=pty_manager,
        yield_time_ms=300,
    )

    assert write_result["success"] is True
    assert "hello from stdin" in write_result["output"]
    assert write_result["running"] is True

    # Exit Python
    exit_result = await write_stdin(
        session_id=session_id,
        chars="exit()\n",
        pty_manager=pty_manager,
        yield_time_ms=300,
    )

    assert exit_result["success"] is True
    # Process should have exited
    assert exit_result["running"] is False or exit_result["exit_code"] is not None


@pytest.mark.asyncio
async def test_write_stdin_nonexistent_session(pty_manager):
    """Test writing to a non-existent session."""
    result = await write_stdin(
        session_id="nonexistent",
        chars="test\n",
        pty_manager=pty_manager,
    )

    assert result["success"] is False
    assert "not found" in result["error"].lower()


@pytest.mark.asyncio
async def test_close_session(pty_manager):
    """Test closing a PTY session."""
    # Start a long-running process
    start_result = await unified_exec(
        cmd="sleep 100",
        pty_manager=pty_manager,
        yield_time_ms=100,
    )

    assert start_result["success"] is True
    session_id = start_result["session_id"]

    # Close the session
    close_result = await close_pty_session(
        session_id=session_id,
        pty_manager=pty_manager,
    )

    assert close_result["success"] is True

    # Verify session is closed (writing should fail)
    write_result = await write_stdin(
        session_id=session_id,
        chars="test\n",
        pty_manager=pty_manager,
    )

    assert write_result["success"] is False


@pytest.mark.asyncio
async def test_list_sessions(pty_manager):
    """Test listing active PTY sessions."""
    # Start a few sessions
    session1 = await unified_exec(
        cmd="cat",
        pty_manager=pty_manager,
        yield_time_ms=100,
    )
    session2 = await unified_exec(
        cmd="cat",
        pty_manager=pty_manager,
        yield_time_ms=100,
    )

    # List sessions
    list_result = list_pty_sessions(pty_manager=pty_manager)

    assert list_result["success"] is True
    assert len(list_result["sessions"]) == 2

    # Cleanup
    await close_pty_session(session1["session_id"], pty_manager=pty_manager, force=True)
    await close_pty_session(session2["session_id"], pty_manager=pty_manager, force=True)


@pytest.mark.asyncio
async def test_output_truncation(pty_manager):
    """Test that output is truncated to token limit."""
    # Generate a lot of output
    result = await unified_exec(
        cmd="python3 -c \"print('x' * 50000)\"",
        pty_manager=pty_manager,
        yield_time_ms=500,
        max_output_tokens=100,  # Very small limit
    )

    assert result["success"] is True
    # Output should be truncated
    assert result.get("truncated") is True or "[Output truncated]" in result["output"]


@pytest.mark.asyncio
async def test_working_directory(pty_manager, tmp_path):
    """Test that working directory is respected."""
    # Create a temporary file
    test_file = tmp_path / "test.txt"
    test_file.write_text("test content")

    # Execute command in that directory
    result = await unified_exec(
        cmd="ls -la test.txt",
        pty_manager=pty_manager,
        workdir=str(tmp_path),
        yield_time_ms=500,
    )

    assert result["success"] is True
    assert "test.txt" in result["output"]


@pytest.mark.asyncio
async def test_multiple_concurrent_sessions(pty_manager):
    """Test multiple concurrent PTY sessions."""
    # Start multiple sessions
    sessions = []
    for i in range(5):
        result = await unified_exec(
            cmd=f"echo 'Session {i}' && cat",
            pty_manager=pty_manager,
            yield_time_ms=200,
        )
        assert result["success"] is True
        sessions.append(result["session_id"])

    # Verify all sessions are running
    list_result = list_pty_sessions(pty_manager=pty_manager)
    assert len(list_result["sessions"]) == 5

    # Write to each session independently
    for i, session_id in enumerate(sessions):
        write_result = await write_stdin(
            session_id=session_id,
            chars=f"Input {i}\n",
            pty_manager=pty_manager,
            yield_time_ms=200,
        )
        assert write_result["success"] is True
        assert f"Input {i}" in write_result["output"]

    # Cleanup
    for session_id in sessions:
        await close_pty_session(session_id, pty_manager=pty_manager, force=True)


@pytest.mark.asyncio
async def test_max_sessions_limit(pty_manager):
    """Test that max sessions limit is enforced."""
    # Create sessions up to the limit (default is 10)
    sessions = []
    for i in range(10):
        result = await unified_exec(
            cmd="cat",
            pty_manager=pty_manager,
            yield_time_ms=100,
        )
        assert result["success"] is True
        sessions.append(result["session_id"])

    # Try to create one more (should fail)
    result = await unified_exec(
        cmd="cat",
        pty_manager=pty_manager,
        yield_time_ms=100,
    )
    assert result["success"] is False
    assert "maximum" in result["error"].lower() or "limit" in result["error"].lower()

    # Cleanup
    for session_id in sessions:
        await close_pty_session(session_id, pty_manager=pty_manager, force=True)


@pytest.mark.asyncio
async def test_ansi_escape_codes(pty_manager):
    """Test that ANSI escape codes are preserved."""
    result = await unified_exec(
        cmd="echo -e '\\033[1;31mRed Text\\033[0m'",
        pty_manager=pty_manager,
        yield_time_ms=500,
    )

    assert result["success"] is True
    # ANSI codes should be in the output
    assert "\\033[" in result["output"] or "\x1b[" in result["output"]
