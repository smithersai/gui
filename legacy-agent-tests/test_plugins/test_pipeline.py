"""Tests for plugin pipeline."""

import pytest
import asyncio
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

from plugins.pipeline import PluginPipeline, DEFAULT_HOOK_TIMEOUT_S
from plugins.loader import LoadedPlugin, load_plugin_from_file
from plugins.models import PluginContext, ToolCall, ToolResult


@pytest.fixture
def plugin_context():
    """Create a basic plugin context for testing."""
    return PluginContext(
        session_id="test_session",
        working_dir="/tmp",
        user_text="test message",
    )


@pytest.fixture
def sample_tool_call():
    """Create a sample tool call for testing."""
    return ToolCall(
        tool_name="shell",
        tool_call_id="call_123",
        input={"cmd": "echo hello"},
    )


@pytest.fixture
def sample_tool_result():
    """Create a sample tool result for testing."""
    return ToolResult(
        tool_call_id="call_123",
        tool_name="shell",
        output="hello\n",
    )


class TestPluginPipelineInit:
    """Tests for PluginPipeline initialization."""

    def test_init_empty_plugins(self):
        """Test pipeline with no plugins."""
        pipeline = PluginPipeline([])

        assert len(pipeline) == 0
        assert not pipeline  # bool(pipeline) is False

    def test_init_with_plugins(self):
        """Test pipeline with plugins."""
        plugin1 = LoadedPlugin(name="p1", path=Path("/tmp/p1.py"))
        plugin2 = LoadedPlugin(name="p2", path=Path("/tmp/p2.py"))
        pipeline = PluginPipeline([plugin1, plugin2])

        assert len(pipeline) == 2
        assert pipeline  # bool(pipeline) is True

    def test_init_custom_timeout(self):
        """Test pipeline with custom timeout."""
        pipeline = PluginPipeline([], timeout_s=10.0)

        assert pipeline.timeout_s == 10.0

    def test_default_timeout(self):
        """Test pipeline uses default timeout."""
        pipeline = PluginPipeline([])

        assert pipeline.timeout_s == DEFAULT_HOOK_TIMEOUT_S


class TestPluginPipelineOnBegin:
    """Tests for on_begin hook execution."""

    @pytest.mark.asyncio
    async def test_on_begin_no_plugins(self, plugin_context):
        """Test on_begin with no plugins."""
        pipeline = PluginPipeline([])

        # Should not raise
        await pipeline.on_begin(plugin_context)

    @pytest.mark.asyncio
    async def test_on_begin_calls_handler(self, plugin_context):
        """Test on_begin calls plugin handler."""
        handler = AsyncMock()
        plugin = LoadedPlugin(
            name="test",
            path=Path("/tmp/test.py"),
            hooks={"on_begin": handler},
        )
        pipeline = PluginPipeline([plugin])

        await pipeline.on_begin(plugin_context)

        handler.assert_called_once_with(plugin_context)

    @pytest.mark.asyncio
    async def test_on_begin_multiple_plugins(self, plugin_context):
        """Test on_begin calls all plugins in order."""
        call_order = []

        async def handler1(ctx):
            call_order.append("p1")

        async def handler2(ctx):
            call_order.append("p2")

        plugin1 = LoadedPlugin(
            name="p1", path=Path("/tmp/p1.py"), hooks={"on_begin": handler1}
        )
        plugin2 = LoadedPlugin(
            name="p2", path=Path("/tmp/p2.py"), hooks={"on_begin": handler2}
        )
        pipeline = PluginPipeline([plugin1, plugin2])

        await pipeline.on_begin(plugin_context)

        assert call_order == ["p1", "p2"]

    @pytest.mark.asyncio
    async def test_on_begin_handles_exception(self, plugin_context):
        """Test on_begin continues after plugin exception."""
        call_order = []

        async def failing_handler(ctx):
            call_order.append("failing")
            raise RuntimeError("Plugin error")

        async def good_handler(ctx):
            call_order.append("good")

        plugin1 = LoadedPlugin(
            name="failing",
            path=Path("/tmp/failing.py"),
            hooks={"on_begin": failing_handler},
        )
        plugin2 = LoadedPlugin(
            name="good", path=Path("/tmp/good.py"), hooks={"on_begin": good_handler}
        )
        pipeline = PluginPipeline([plugin1, plugin2])

        await pipeline.on_begin(plugin_context)

        # Both should be called despite the first failing
        assert call_order == ["failing", "good"]

    @pytest.mark.asyncio
    async def test_on_begin_sync_handler(self, plugin_context):
        """Test on_begin works with sync handler."""
        called = []

        def sync_handler(ctx):
            called.append(True)

        plugin = LoadedPlugin(
            name="sync", path=Path("/tmp/sync.py"), hooks={"on_begin": sync_handler}
        )
        pipeline = PluginPipeline([plugin])

        await pipeline.on_begin(plugin_context)

        assert called == [True]


class TestPluginPipelineOnToolCall:
    """Tests for on_tool_call hook execution."""

    @pytest.mark.asyncio
    async def test_on_tool_call_no_plugins(self, plugin_context, sample_tool_call):
        """Test on_tool_call returns original call with no plugins."""
        pipeline = PluginPipeline([])

        result = await pipeline.on_tool_call(plugin_context, sample_tool_call)

        assert result is sample_tool_call

    @pytest.mark.asyncio
    async def test_on_tool_call_returns_modified(
        self, plugin_context, sample_tool_call
    ):
        """Test on_tool_call can modify the call."""

        async def modifier(ctx, call):
            return ToolCall(
                tool_name=call.tool_name,
                tool_call_id=call.tool_call_id,
                input={"cmd": "modified"},
            )

        plugin = LoadedPlugin(
            name="modifier",
            path=Path("/tmp/modifier.py"),
            hooks={"on_tool_call": modifier},
        )
        pipeline = PluginPipeline([plugin])

        result = await pipeline.on_tool_call(plugin_context, sample_tool_call)

        assert result.input["cmd"] == "modified"

    @pytest.mark.asyncio
    async def test_on_tool_call_none_preserves_call(
        self, plugin_context, sample_tool_call
    ):
        """Test on_tool_call returning None preserves current call."""

        async def pass_through(ctx, call):
            return None

        plugin = LoadedPlugin(
            name="passthrough",
            path=Path("/tmp/pass.py"),
            hooks={"on_tool_call": pass_through},
        )
        pipeline = PluginPipeline([plugin])

        result = await pipeline.on_tool_call(plugin_context, sample_tool_call)

        assert result is sample_tool_call

    @pytest.mark.asyncio
    async def test_on_tool_call_chains_modifications(
        self, plugin_context, sample_tool_call
    ):
        """Test modifications chain through plugins."""

        async def add_prefix(ctx, call):
            return ToolCall(
                tool_name=call.tool_name,
                tool_call_id=call.tool_call_id,
                input={"cmd": "prefix_" + call.input["cmd"]},
            )

        async def add_suffix(ctx, call):
            return ToolCall(
                tool_name=call.tool_name,
                tool_call_id=call.tool_call_id,
                input={"cmd": call.input["cmd"] + "_suffix"},
            )

        plugin1 = LoadedPlugin(
            name="prefix", path=Path("/tmp/prefix.py"), hooks={"on_tool_call": add_prefix}
        )
        plugin2 = LoadedPlugin(
            name="suffix", path=Path("/tmp/suffix.py"), hooks={"on_tool_call": add_suffix}
        )
        pipeline = PluginPipeline([plugin1, plugin2])

        result = await pipeline.on_tool_call(plugin_context, sample_tool_call)

        assert result.input["cmd"] == "prefix_echo hello_suffix"


class TestPluginPipelineOnResolveTool:
    """Tests for on_resolve_tool hook execution."""

    @pytest.mark.asyncio
    async def test_on_resolve_tool_no_plugins(self, plugin_context, sample_tool_call):
        """Test on_resolve_tool returns None with no plugins."""
        pipeline = PluginPipeline([])

        result = await pipeline.on_resolve_tool(plugin_context, sample_tool_call)

        assert result is None

    @pytest.mark.asyncio
    async def test_on_resolve_tool_short_circuits(
        self, plugin_context, sample_tool_call
    ):
        """Test on_resolve_tool short-circuits on first result."""
        call_order = []

        async def resolver1(ctx, call):
            call_order.append("r1")
            return ToolResult(
                tool_call_id=call.tool_call_id,
                tool_name=call.tool_name,
                output="resolved by r1",
            )

        async def resolver2(ctx, call):
            call_order.append("r2")
            return ToolResult(
                tool_call_id=call.tool_call_id,
                tool_name=call.tool_name,
                output="resolved by r2",
            )

        plugin1 = LoadedPlugin(
            name="r1",
            path=Path("/tmp/r1.py"),
            hooks={"on_resolve_tool": resolver1},
        )
        plugin2 = LoadedPlugin(
            name="r2",
            path=Path("/tmp/r2.py"),
            hooks={"on_resolve_tool": resolver2},
        )
        pipeline = PluginPipeline([plugin1, plugin2])

        result = await pipeline.on_resolve_tool(plugin_context, sample_tool_call)

        assert result.output == "resolved by r1"
        assert call_order == ["r1"]  # r2 was never called

    @pytest.mark.asyncio
    async def test_on_resolve_tool_skips_none(self, plugin_context, sample_tool_call):
        """Test on_resolve_tool continues when plugin returns None."""
        call_order = []

        async def pass_handler(ctx, call):
            call_order.append("pass")
            return None

        async def resolver(ctx, call):
            call_order.append("resolver")
            return ToolResult(
                tool_call_id=call.tool_call_id,
                tool_name=call.tool_name,
                output="resolved",
            )

        plugin1 = LoadedPlugin(
            name="pass",
            path=Path("/tmp/pass.py"),
            hooks={"on_resolve_tool": pass_handler},
        )
        plugin2 = LoadedPlugin(
            name="resolver",
            path=Path("/tmp/resolver.py"),
            hooks={"on_resolve_tool": resolver},
        )
        pipeline = PluginPipeline([plugin1, plugin2])

        result = await pipeline.on_resolve_tool(plugin_context, sample_tool_call)

        assert result.output == "resolved"
        assert call_order == ["pass", "resolver"]

    @pytest.mark.asyncio
    async def test_on_resolve_tool_all_none(self, plugin_context, sample_tool_call):
        """Test on_resolve_tool returns None when all plugins return None."""

        async def pass_handler(ctx, call):
            return None

        plugin = LoadedPlugin(
            name="pass",
            path=Path("/tmp/pass.py"),
            hooks={"on_resolve_tool": pass_handler},
        )
        pipeline = PluginPipeline([plugin])

        result = await pipeline.on_resolve_tool(plugin_context, sample_tool_call)

        assert result is None


class TestPluginPipelineOnToolResult:
    """Tests for on_tool_result hook execution."""

    @pytest.mark.asyncio
    async def test_on_tool_result_no_plugins(
        self, plugin_context, sample_tool_call, sample_tool_result
    ):
        """Test on_tool_result returns original result with no plugins."""
        pipeline = PluginPipeline([])

        result = await pipeline.on_tool_result(
            plugin_context, sample_tool_call, sample_tool_result
        )

        assert result is sample_tool_result

    @pytest.mark.asyncio
    async def test_on_tool_result_transforms(
        self, plugin_context, sample_tool_call, sample_tool_result
    ):
        """Test on_tool_result can transform the result."""

        async def transformer(ctx, call, result):
            return ToolResult(
                tool_call_id=result.tool_call_id,
                tool_name=result.tool_name,
                output="transformed: " + result.output,
            )

        plugin = LoadedPlugin(
            name="transformer",
            path=Path("/tmp/transformer.py"),
            hooks={"on_tool_result": transformer},
        )
        pipeline = PluginPipeline([plugin])

        result = await pipeline.on_tool_result(
            plugin_context, sample_tool_call, sample_tool_result
        )

        assert result.output == "transformed: hello\n"

    @pytest.mark.asyncio
    async def test_on_tool_result_chains(
        self, plugin_context, sample_tool_call, sample_tool_result
    ):
        """Test transformations chain through plugins."""

        async def upper(ctx, call, result):
            return ToolResult(
                tool_call_id=result.tool_call_id,
                tool_name=result.tool_name,
                output=result.output.upper(),
            )

        async def strip(ctx, call, result):
            return ToolResult(
                tool_call_id=result.tool_call_id,
                tool_name=result.tool_name,
                output=result.output.strip(),
            )

        plugin1 = LoadedPlugin(
            name="upper",
            path=Path("/tmp/upper.py"),
            hooks={"on_tool_result": upper},
        )
        plugin2 = LoadedPlugin(
            name="strip",
            path=Path("/tmp/strip.py"),
            hooks={"on_tool_result": strip},
        )
        pipeline = PluginPipeline([plugin1, plugin2])

        result = await pipeline.on_tool_result(
            plugin_context, sample_tool_call, sample_tool_result
        )

        assert result.output == "HELLO"


class TestPluginPipelineOnFinal:
    """Tests for on_final hook execution."""

    @pytest.mark.asyncio
    async def test_on_final_no_plugins(self, plugin_context):
        """Test on_final returns original text with no plugins."""
        pipeline = PluginPipeline([])

        result = await pipeline.on_final(plugin_context, "Hello world")

        assert result == "Hello world"

    @pytest.mark.asyncio
    async def test_on_final_transforms(self, plugin_context):
        """Test on_final can transform text."""

        async def transformer(ctx, text):
            return text + "\n\n---\nFooter"

        plugin = LoadedPlugin(
            name="footer",
            path=Path("/tmp/footer.py"),
            hooks={"on_final": transformer},
        )
        pipeline = PluginPipeline([plugin])

        result = await pipeline.on_final(plugin_context, "Hello world")

        assert result == "Hello world\n\n---\nFooter"

    @pytest.mark.asyncio
    async def test_on_final_chains(self, plugin_context):
        """Test transformations chain through plugins."""

        async def add_header(ctx, text):
            return "Header\n---\n" + text

        async def add_footer(ctx, text):
            return text + "\n---\nFooter"

        plugin1 = LoadedPlugin(
            name="header",
            path=Path("/tmp/header.py"),
            hooks={"on_final": add_header},
        )
        plugin2 = LoadedPlugin(
            name="footer",
            path=Path("/tmp/footer.py"),
            hooks={"on_final": add_footer},
        )
        pipeline = PluginPipeline([plugin1, plugin2])

        result = await pipeline.on_final(plugin_context, "Content")

        assert result == "Header\n---\nContent\n---\nFooter"


class TestPluginPipelineOnDone:
    """Tests for on_done hook execution."""

    @pytest.mark.asyncio
    async def test_on_done_no_plugins(self, plugin_context):
        """Test on_done with no plugins."""
        pipeline = PluginPipeline([])

        # Should not raise
        await pipeline.on_done(plugin_context)

    @pytest.mark.asyncio
    async def test_on_done_calls_all(self, plugin_context):
        """Test on_done calls all plugins."""
        call_order = []

        async def handler1(ctx):
            call_order.append("p1")

        async def handler2(ctx):
            call_order.append("p2")

        plugin1 = LoadedPlugin(
            name="p1", path=Path("/tmp/p1.py"), hooks={"on_done": handler1}
        )
        plugin2 = LoadedPlugin(
            name="p2", path=Path("/tmp/p2.py"), hooks={"on_done": handler2}
        )
        pipeline = PluginPipeline([plugin1, plugin2])

        await pipeline.on_done(plugin_context)

        assert call_order == ["p1", "p2"]


class TestPluginPipelineIntegration:
    """Integration tests using actual plugin files."""

    @pytest.mark.asyncio
    async def test_load_and_execute_plugin(self, tmp_path: Path):
        """Test loading a plugin from file and executing it."""
        plugin_code = '''
__plugin__ = {"api": "1.0", "name": "integration_test"}

@on_begin
async def begin(ctx):
    ctx.state["initialized"] = True

@on_tool_call
async def tool_call(ctx, call):
    ctx.state["tool_calls"] = ctx.state.get("tool_calls", 0) + 1
    return None

@on_final
async def final(ctx, text):
    count = ctx.state.get("tool_calls", 0)
    return f"{text} (Tool calls: {count})"
'''
        plugin_file = tmp_path / "integration.py"
        plugin_file.write_text(plugin_code)

        plugin = load_plugin_from_file(plugin_file)
        pipeline = PluginPipeline([plugin])
        ctx = PluginContext(
            session_id="test", working_dir=str(tmp_path), user_text="test"
        )

        await pipeline.on_begin(ctx)
        assert ctx.state["initialized"] is True

        call = ToolCall(tool_name="shell", tool_call_id="1", input={})
        await pipeline.on_tool_call(ctx, call)
        await pipeline.on_tool_call(ctx, call)
        assert ctx.state["tool_calls"] == 2

        result = await pipeline.on_final(ctx, "Done")
        assert result == "Done (Tool calls: 2)"

    @pytest.mark.asyncio
    async def test_plugin_order_matters(self, tmp_path: Path):
        """Test that plugin order determines execution order."""
        p1_code = '''
__plugin__ = {"api": "1.0", "name": "p1"}

@on_final
async def final(ctx, text):
    return f"[P1]{text}[/P1]"
'''
        p2_code = '''
__plugin__ = {"api": "1.0", "name": "p2"}

@on_final
async def final(ctx, text):
    return f"[P2]{text}[/P2]"
'''
        (tmp_path / "p1.py").write_text(p1_code)
        (tmp_path / "p2.py").write_text(p2_code)

        p1 = load_plugin_from_file(tmp_path / "p1.py")
        p2 = load_plugin_from_file(tmp_path / "p2.py")

        # Order: p1 then p2
        pipeline = PluginPipeline([p1, p2])
        ctx = PluginContext(session_id="test", working_dir=str(tmp_path), user_text="")

        result = await pipeline.on_final(ctx, "Content")
        assert result == "[P2][P1]Content[/P1][/P2]"

        # Order: p2 then p1
        pipeline2 = PluginPipeline([p2, p1])
        result2 = await pipeline2.on_final(ctx, "Content")
        assert result2 == "[P1][P2]Content[/P2][/P1]"
