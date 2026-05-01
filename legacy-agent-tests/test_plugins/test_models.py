"""Tests for plugin models."""

import pytest
from plugins.models import PluginContext, ToolCall, ToolResult


class TestPluginContext:
    """Tests for PluginContext."""

    def test_create_basic(self):
        """Test basic context creation."""
        ctx = PluginContext(
            session_id="ses_123",
            working_dir="/tmp",
            user_text="Hello",
        )
        assert ctx.session_id == "ses_123"
        assert ctx.working_dir == "/tmp"
        assert ctx.user_text == "Hello"

    def test_state_default(self):
        """Test state defaults to empty dict."""
        ctx = PluginContext(
            session_id="ses_123",
            working_dir="/tmp",
            user_text="Hello",
        )
        assert ctx.state == {}
        assert isinstance(ctx.state, dict)

    def test_state_mutable(self):
        """Test state is mutable."""
        ctx = PluginContext(
            session_id="ses_123",
            working_dir="/tmp",
            user_text="Hello",
        )
        ctx.state["key"] = "value"
        assert ctx.state["key"] == "value"

    def test_memory_default(self):
        """Test memory defaults to empty list."""
        ctx = PluginContext(
            session_id="ses_123",
            working_dir="/tmp",
            user_text="Hello",
        )
        assert ctx.memory == []
        assert isinstance(ctx.memory, list)

    def test_memory_mutable(self):
        """Test memory is mutable."""
        ctx = PluginContext(
            session_id="ses_123",
            working_dir="/tmp",
            user_text="Hello",
        )
        ctx.memory.append({"role": "user", "content": "test"})
        assert len(ctx.memory) == 1


class TestToolCall:
    """Tests for ToolCall."""

    def test_create(self):
        """Test ToolCall creation."""
        call = ToolCall(
            tool_name="shell",
            tool_call_id="call_123",
            input={"cmd": "echo hello"},
        )
        assert call.tool_name == "shell"
        assert call.tool_call_id == "call_123"
        assert call.input == {"cmd": "echo hello"}

    def test_input_dict(self):
        """Test input is a dict."""
        call = ToolCall(
            tool_name="read",
            tool_call_id="call_456",
            input={"path": "/tmp/file.txt", "encoding": "utf-8"},
        )
        assert "path" in call.input
        assert "encoding" in call.input


class TestToolResult:
    """Tests for ToolResult."""

    def test_create_success(self):
        """Test successful ToolResult creation."""
        result = ToolResult(
            tool_call_id="call_123",
            tool_name="shell",
            output="hello\n",
        )
        assert result.tool_call_id == "call_123"
        assert result.tool_name == "shell"
        assert result.output == "hello\n"
        assert result.success is True
        assert result.error is None

    def test_create_failure(self):
        """Test failed ToolResult creation."""
        result = ToolResult(
            tool_call_id="call_123",
            tool_name="shell",
            output="",
            success=False,
            error="Command not found",
        )
        assert result.success is False
        assert result.error == "Command not found"

    def test_default_success(self):
        """Test success defaults to True."""
        result = ToolResult(
            tool_call_id="call_123",
            tool_name="shell",
            output="output",
        )
        assert result.success is True
