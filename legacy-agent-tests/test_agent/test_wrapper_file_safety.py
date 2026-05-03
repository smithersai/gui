"""Tests for AgentWrapper file-safety helper behavior."""

import time

import pytest

from agent.tools.filesystem import set_current_session_id
from agent.wrapper import (
    _enforce_file_safety_before_tool_call,
    _record_file_safety_after_tool_result,
    _remember_tool_call_context,
    _resolve_tool_result_context,
    _tools_disabled,
)
from core.state import get_file_tracker


def test_write_tool_requires_existing_file_to_be_read(tmp_path):
    """Existing files cannot be written through wrapper tools before read."""
    set_current_session_id("wrapper-write-requires-read")
    target = tmp_path / "target.txt"
    target.write_text("original")

    with pytest.raises(ValueError, match="has not been read"):
        _enforce_file_safety_before_tool_call(
            "write_file",
            {"path": str(target)},
            "wrapper-write-requires-read",
        )


def test_successful_read_tool_marks_file_read(tmp_path):
    """A successful MCP read result updates read tracking."""
    session_id = "wrapper-read-marks-file"
    set_current_session_id(session_id)
    target = tmp_path / "target.txt"
    target.write_text("contents")

    _record_file_safety_after_tool_result(
        "read_text_file",
        {"path": str(target)},
        "contents",
        session_id,
    )

    assert get_file_tracker(session_id).is_read(str(target))


def test_failed_read_tool_does_not_mark_file_read(tmp_path):
    """Failed MCP read results must not unlock later writes."""
    session_id = "wrapper-failed-read"
    set_current_session_id(session_id)
    target = tmp_path / "target.txt"
    target.write_text("contents")

    _record_file_safety_after_tool_result(
        "read_text_file",
        {"path": str(target)},
        "Error: File not found",
        session_id,
    )

    assert not get_file_tracker(session_id).is_read(str(target))


def test_successful_write_tool_updates_tracking(tmp_path):
    """Successful writes are marked so follow-up writes are not self-blocked."""
    session_id = "wrapper-write-marks-file"
    set_current_session_id(session_id)
    target = tmp_path / "target.txt"
    target.write_text("original")
    tracker = get_file_tracker(session_id)
    tracker.mark_read(str(target))
    read_time = tracker.get_read_time(str(target))

    _enforce_file_safety_before_tool_call(
        "write_file",
        {"path": str(target)},
        session_id,
    )

    time.sleep(0.01)
    target.write_text("updated")
    _record_file_safety_after_tool_result(
        "write_file",
        {"path": str(target)},
        "Successfully wrote file",
        session_id,
    )

    assert tracker.get_read_time(str(target)) > read_time
    _enforce_file_safety_before_tool_call(
        "write_file",
        {"path": str(target)},
        session_id,
    )


def test_tool_result_context_recovers_original_call_input():
    """Tool result events can recover the matching call name and args."""
    calls = {}
    args = {"path": "/tmp/example.txt"}

    _remember_tool_call_context(calls, "call_1", "read_text_file", args)

    tool_name, tool_args = _resolve_tool_result_context(calls, "call_1")

    assert tool_name == "read_text_file"
    assert tool_args == args


def test_tool_result_context_uses_fallback_for_unknown_call():
    """Unknown result ids keep any tool name supplied by the event."""
    tool_name, tool_args = _resolve_tool_result_context(
        {},
        "missing",
        fallback_tool_name="web_fetch",
    )

    assert tool_name == "web_fetch"
    assert tool_args == {}


def test_tools_disabled_all_tools_marker():
    """The request-level all-tools marker disables tool execution."""
    assert _tools_disabled({"*": False})


def test_tools_disabled_requires_explicit_config():
    """Missing or partially enabled tool maps do not disable all tools."""
    assert not _tools_disabled(None)
    assert not _tools_disabled({})
    assert not _tools_disabled({"shell": False, "read": False})
    assert not _tools_disabled({"shell": False, "read": True})
