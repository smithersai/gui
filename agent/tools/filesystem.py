"""
Safe filesystem tools with read-before-write enforcement.

These tools wrap the MCP filesystem operations and add safety checks
to prevent blind overwrites and race conditions.
"""

import os
from contextvars import ContextVar
from typing import Any

from core.state import get_file_tracker

# Context variable to track current session ID across async calls
_current_session_id: ContextVar[str | None] = ContextVar('current_session_id', default=None)


def set_current_session_id(session_id: str | None) -> None:
    """Set the current session ID for tool safety checks."""
    _current_session_id.set(session_id)


def get_current_session_id() -> str:
    """
    Get the current session ID.

    Returns:
        Current session ID

    Raises:
        RuntimeError: If no session ID is set
    """
    session_id = _current_session_id.get()
    if session_id is None:
        raise RuntimeError("No session ID set for file safety tracking")
    return session_id


def mark_file_read(path: str) -> None:
    """
    Mark a file as read in the current session's tracker.

    Args:
        path: Path to the file that was read
    """
    try:
        session_id = get_current_session_id()
        tracker = get_file_tracker(session_id)
        tracker.mark_read(path)
    except RuntimeError:
        # No session ID set - skip tracking (for backwards compatibility)
        return


def check_file_writable(path: str) -> None:
    """
    Check if a file can be safely written.

    For existing files, enforces read-before-write safety by checking:
    1. File has been read in this session
    2. File hasn't been modified since it was read

    New files can always be written.

    Args:
        path: Path to check

    Raises:
        ValueError: If read-before-write safety check fails
    """
    # Check if file exists
    if not os.path.exists(path):
        # New file - no read required
        return

    try:
        session_id = get_current_session_id()
        tracker = get_file_tracker(session_id)
        # Enforce read-before-write for existing files
        tracker.assert_not_modified(path)
    except RuntimeError:
        # No session ID set - skip enforcement (for backwards compatibility)
        return


def mark_file_written(path: str) -> None:
    """
    Mark a file as written in the current session's tracker.

    Updates tracking with the file's new modification time after a write.
    This should be called after successful write operations to prevent
    false positives when the agent checks if its own writes were external.

    Args:
        path: Path to the file that was written
    """
    try:
        session_id = get_current_session_id()
        tracker = get_file_tracker(session_id)
        tracker.mark_written(path)
    except RuntimeError:
        # No session ID set - skip tracking (for backwards compatibility)
        return


def clear_file_tracking(path: str) -> None:
    """
    Clear tracking for a specific file.

    Args:
        path: Path to the file to stop tracking
    """
    try:
        session_id = get_current_session_id()
        tracker = get_file_tracker(session_id)
        tracker.clear_file(path)
    except RuntimeError:
        # No session ID set - skip (for backwards compatibility)
        return
