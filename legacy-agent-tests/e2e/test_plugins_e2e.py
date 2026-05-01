"""End-to-end tests for the plugin system."""

import pytest
from pathlib import Path

from plugins.loader import load_plugin_from_file
from plugins.pipeline import PluginPipeline
from plugins.models import PluginContext, ToolCall, ToolResult


class TestPluginE2EHookExecution:
    """E2E tests for hook execution through the pipeline."""

    @pytest.mark.asyncio
    async def test_full_lifecycle(self, tmp_path: Path):
        """Test a complete plugin lifecycle through all hooks."""
        plugin_code = '''
__plugin__ = {"api": "1.0", "name": "lifecycle_test"}

events = []

@on_begin
async def begin(ctx):
    events.append("begin")
    ctx.state["initialized"] = True

@on_tool_call
async def tool_call(ctx, call):
    events.append(f"tool_call:{call.tool_name}")
    return None

@on_tool_result
async def tool_result(ctx, call, result):
    events.append(f"tool_result:{call.tool_name}")
    return None

@on_final
async def final(ctx, text):
    events.append("final")
    return text + " [processed]"

@on_done
async def done(ctx):
    events.append("done")
'''
        plugin_file = tmp_path / "lifecycle.py"
        plugin_file.write_text(plugin_code)

        plugin = load_plugin_from_file(plugin_file)
        pipeline = PluginPipeline([plugin])
        ctx = PluginContext(
            session_id="test_session",
            working_dir=str(tmp_path),
            user_text="test message",
        )

        # Run through lifecycle
        await pipeline.on_begin(ctx)
        assert ctx.state["initialized"] is True

        call = ToolCall(tool_name="shell", tool_call_id="1", input={"cmd": "echo"})
        await pipeline.on_tool_call(ctx, call)

        result = ToolResult(tool_call_id="1", tool_name="shell", output="output")
        await pipeline.on_tool_result(ctx, call, result)

        final_text = await pipeline.on_final(ctx, "Hello")
        assert final_text == "Hello [processed]"

        await pipeline.on_done(ctx)

        # Check events were recorded
        events = plugin.hooks["on_begin"].__globals__["events"]
        assert events == [
            "begin",
            "tool_call:shell",
            "tool_result:shell",
            "final",
            "done",
        ]

    @pytest.mark.asyncio
    async def test_multiple_plugins_in_order(self, tmp_path: Path):
        """Test multiple plugins execute in order."""
        p1_code = '''
__plugin__ = {"api": "1.0", "name": "p1"}

@on_begin
async def begin(ctx):
    ctx.state.setdefault("order", []).append("p1_begin")

@on_final
async def final(ctx, text):
    ctx.state.setdefault("order", []).append("p1_final")
    return "[P1]" + text
'''
        p2_code = '''
__plugin__ = {"api": "1.0", "name": "p2"}

@on_begin
async def begin(ctx):
    ctx.state.setdefault("order", []).append("p2_begin")

@on_final
async def final(ctx, text):
    ctx.state.setdefault("order", []).append("p2_final")
    return text + "[P2]"
'''
        (tmp_path / "p1.py").write_text(p1_code)
        (tmp_path / "p2.py").write_text(p2_code)

        p1 = load_plugin_from_file(tmp_path / "p1.py")
        p2 = load_plugin_from_file(tmp_path / "p2.py")

        pipeline = PluginPipeline([p1, p2])
        ctx = PluginContext(
            session_id="test",
            working_dir=str(tmp_path),
            user_text="",
        )

        await pipeline.on_begin(ctx)
        result = await pipeline.on_final(ctx, "content")

        # Plugins execute in order
        assert ctx.state["order"] == ["p1_begin", "p2_begin", "p1_final", "p2_final"]
        # Transformations chain: p1 wraps first, then p2 wraps the result
        assert result == "[P1]content[P2]"

    @pytest.mark.asyncio
    async def test_on_resolve_tool_short_circuit(self, tmp_path: Path):
        """Test on_resolve_tool can short-circuit tool execution."""
        plugin_code = '''
__plugin__ = {"api": "1.0", "name": "mocker"}

@on_resolve_tool
async def mock_shell(ctx, call):
    if call.tool_name == "shell":
        return ToolResult(
            tool_call_id=call.tool_call_id,
            tool_name=call.tool_name,
            output="mocked output",
            success=True,
        )
    return None
'''
        plugin_file = tmp_path / "mocker.py"
        plugin_file.write_text(plugin_code)

        plugin = load_plugin_from_file(plugin_file)
        pipeline = PluginPipeline([plugin])
        ctx = PluginContext(
            session_id="test",
            working_dir=str(tmp_path),
            user_text="",
        )

        # Shell should be resolved by plugin
        shell_call = ToolCall(tool_name="shell", tool_call_id="1", input={})
        result = await pipeline.on_resolve_tool(ctx, shell_call)
        assert result is not None
        assert result.output == "mocked output"

        # Other tools should not be resolved
        read_call = ToolCall(tool_name="read", tool_call_id="2", input={})
        result = await pipeline.on_resolve_tool(ctx, read_call)
        assert result is None

    @pytest.mark.asyncio
    async def test_plugin_state_isolation(self, tmp_path: Path):
        """Test plugin state is isolated per request."""
        plugin_code = '''
__plugin__ = {"api": "1.0", "name": "state_test"}

@on_begin
async def begin(ctx):
    ctx.state["counter"] = ctx.state.get("counter", 0) + 1

@on_final
async def final(ctx, text):
    return f"count={ctx.state['counter']}"
'''
        plugin_file = tmp_path / "state.py"
        plugin_file.write_text(plugin_code)

        plugin = load_plugin_from_file(plugin_file)
        pipeline = PluginPipeline([plugin])

        # First request
        ctx1 = PluginContext(session_id="s1", working_dir=str(tmp_path), user_text="")
        await pipeline.on_begin(ctx1)
        result1 = await pipeline.on_final(ctx1, "")
        assert result1 == "count=1"

        # Second request with new context
        ctx2 = PluginContext(session_id="s2", working_dir=str(tmp_path), user_text="")
        await pipeline.on_begin(ctx2)
        result2 = await pipeline.on_final(ctx2, "")
        assert result2 == "count=1"  # Fresh state, not accumulated


class TestPluginE2EErrorHandling:
    """E2E tests for error handling in plugins."""

    @pytest.mark.asyncio
    async def test_plugin_error_continues_pipeline(self, tmp_path: Path):
        """Test that a plugin error doesn't stop other plugins."""
        failing_code = '''
__plugin__ = {"api": "1.0", "name": "failing"}

@on_begin
async def begin(ctx):
    raise RuntimeError("Intentional failure")
'''
        success_code = '''
__plugin__ = {"api": "1.0", "name": "success"}

@on_begin
async def begin(ctx):
    ctx.state["success_ran"] = True
'''
        (tmp_path / "failing.py").write_text(failing_code)
        (tmp_path / "success.py").write_text(success_code)

        failing = load_plugin_from_file(tmp_path / "failing.py")
        success = load_plugin_from_file(tmp_path / "success.py")

        pipeline = PluginPipeline([failing, success])
        ctx = PluginContext(session_id="test", working_dir=str(tmp_path), user_text="")

        # Should not raise, just log warning
        await pipeline.on_begin(ctx)

        # Success plugin should still run
        assert ctx.state.get("success_ran") is True


class TestExamplePlugins:
    """Tests for the example plugins."""

    @pytest.mark.asyncio
    async def test_logger_plugin(self, tmp_path: Path):
        """Test the logger example plugin loads and works."""
        from pathlib import Path as P
        import plugins

        plugin_path = P(plugins.__file__).parent / "examples" / "logger.py"
        plugin = load_plugin_from_file(plugin_path)

        # Verify it has the expected hooks
        assert plugin.name == "logger"
        assert "on_begin" in plugin.hooks
        assert "on_tool_call" in plugin.hooks
        assert "on_tool_result" in plugin.hooks
        assert "on_done" in plugin.hooks

        # Test basic execution
        pipeline = PluginPipeline([plugin])
        ctx = PluginContext(
            session_id="test",
            working_dir=str(tmp_path),
            user_text="",
        )
        await pipeline.on_begin(ctx)
        assert ctx.state.get("tool_count") == 0

    @pytest.mark.asyncio
    async def test_footer_plugin(self, tmp_path: Path):
        """Test the footer example plugin."""
        from pathlib import Path as P
        import plugins

        plugin_path = P(plugins.__file__).parent / "examples" / "footer.py"
        plugin = load_plugin_from_file(plugin_path)

        pipeline = PluginPipeline([plugin])
        ctx = PluginContext(
            session_id="test_123",
            working_dir=str(tmp_path),
            user_text="",
        )

        await pipeline.on_begin(ctx)

        # Simulate a tool call
        call = ToolCall(tool_name="shell", tool_call_id="1", input={})
        await pipeline.on_tool_call(ctx, call)

        result = await pipeline.on_final(ctx, "Hello world")

        assert "Session: test_123" in result
        assert "Tools used: shell" in result
