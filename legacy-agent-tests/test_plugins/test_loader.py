"""Tests for plugin loader."""

import pytest
from pathlib import Path
from plugins.loader import load_plugin_from_file, LoadedPlugin, PLUGIN_API_VERSION


class TestLoadPluginFromFile:
    """Tests for load_plugin_from_file function."""

    def test_load_simple_plugin(self, tmp_path: Path):
        """Test loading a simple plugin with one hook."""
        plugin_code = '''
__plugin__ = {"api": "1.0", "name": "simple_test"}

@on_begin
async def my_begin(ctx):
    ctx.state["initialized"] = True
'''
        plugin_file = tmp_path / "simple.py"
        plugin_file.write_text(plugin_code)

        plugin = load_plugin_from_file(plugin_file)

        assert isinstance(plugin, LoadedPlugin)
        assert plugin.name == "simple_test"
        assert plugin.path == plugin_file
        assert "on_begin" in plugin.hooks
        assert plugin.metadata["api"] == "1.0"

    def test_load_plugin_multiple_hooks(self, tmp_path: Path):
        """Test loading a plugin with multiple hooks."""
        plugin_code = '''
__plugin__ = {"api": "1.0", "name": "multi_hook"}

@on_begin
async def begin(ctx):
    pass

@on_tool_call
async def tool_call(ctx, call):
    return None

@on_tool_result
async def tool_result(ctx, call, result):
    return None

@on_final
async def final(ctx, text):
    return text

@on_done
async def done(ctx):
    pass
'''
        plugin_file = tmp_path / "multi.py"
        plugin_file.write_text(plugin_code)

        plugin = load_plugin_from_file(plugin_file)

        assert plugin.name == "multi_hook"
        assert "on_begin" in plugin.hooks
        assert "on_tool_call" in plugin.hooks
        assert "on_tool_result" in plugin.hooks
        assert "on_final" in plugin.hooks
        assert "on_done" in plugin.hooks

    def test_load_plugin_with_on_resolve_tool(self, tmp_path: Path):
        """Test loading a plugin with on_resolve_tool hook."""
        plugin_code = '''
__plugin__ = {"api": "1.0", "name": "resolver"}

@on_resolve_tool
async def resolve(ctx, call):
    if call.tool_name == "mock":
        return ToolResult(
            tool_call_id=call.tool_call_id,
            tool_name=call.tool_name,
            output="mocked",
        )
    return None
'''
        plugin_file = tmp_path / "resolver.py"
        plugin_file.write_text(plugin_code)

        plugin = load_plugin_from_file(plugin_file)

        assert "on_resolve_tool" in plugin.hooks

    def test_load_plugin_default_metadata(self, tmp_path: Path):
        """Test plugin with no __plugin__ uses defaults."""
        plugin_code = '''
@on_begin
async def begin(ctx):
    pass
'''
        plugin_file = tmp_path / "no_meta.py"
        plugin_file.write_text(plugin_code)

        plugin = load_plugin_from_file(plugin_file)

        assert plugin.name == "no_meta"  # Uses filename
        assert plugin.metadata["api"] == PLUGIN_API_VERSION

    def test_load_plugin_file_not_found(self, tmp_path: Path):
        """Test error when plugin file doesn't exist."""
        plugin_file = tmp_path / "nonexistent.py"

        with pytest.raises(FileNotFoundError):
            load_plugin_from_file(plugin_file)

    def test_load_plugin_syntax_error(self, tmp_path: Path):
        """Test error when plugin has syntax error."""
        plugin_code = '''
@on_begin
async def broken(ctx)
    pass  # Missing colon
'''
        plugin_file = tmp_path / "broken.py"
        plugin_file.write_text(plugin_code)

        with pytest.raises(ImportError):
            load_plugin_from_file(plugin_file)

    def test_load_plugin_incompatible_api_version(self, tmp_path: Path):
        """Test error when plugin API version is incompatible."""
        plugin_code = '''
__plugin__ = {"api": "99.0", "name": "future_plugin"}

@on_begin
async def begin(ctx):
    pass
'''
        plugin_file = tmp_path / "future.py"
        plugin_file.write_text(plugin_code)

        with pytest.raises(ValueError, match="Incompatible plugin API version"):
            load_plugin_from_file(plugin_file)

    def test_load_plugin_with_sync_functions(self, tmp_path: Path):
        """Test loading a plugin with synchronous hooks."""
        plugin_code = '''
__plugin__ = {"api": "1.0", "name": "sync_plugin"}

@on_begin
def sync_begin(ctx):
    ctx.state["sync"] = True

@on_tool_call
def sync_tool_call(ctx, call):
    return None
'''
        plugin_file = tmp_path / "sync.py"
        plugin_file.write_text(plugin_code)

        plugin = load_plugin_from_file(plugin_file)

        assert "on_begin" in plugin.hooks
        assert "on_tool_call" in plugin.hooks

    def test_load_plugin_with_imports(self, tmp_path: Path):
        """Test plugin can use standard library imports."""
        plugin_code = '''
__plugin__ = {"api": "1.0", "name": "importing"}

import json
from datetime import datetime

@on_begin
async def begin(ctx):
    ctx.state["time"] = datetime.now().isoformat()
    ctx.state["data"] = json.dumps({"key": "value"})
'''
        plugin_file = tmp_path / "importing.py"
        plugin_file.write_text(plugin_code)

        plugin = load_plugin_from_file(plugin_file)

        assert "on_begin" in plugin.hooks

    def test_loaded_plugin_dataclass(self):
        """Test LoadedPlugin dataclass."""
        plugin = LoadedPlugin(
            name="test",
            path=Path("/tmp/test.py"),
            hooks={"on_begin": lambda ctx: None},
            metadata={"api": "1.0"},
        )

        assert plugin.name == "test"
        assert plugin.path == Path("/tmp/test.py")
        assert "on_begin" in plugin.hooks
        assert plugin.metadata["api"] == "1.0"

    def test_loaded_plugin_defaults(self):
        """Test LoadedPlugin default values."""
        plugin = LoadedPlugin(
            name="minimal",
            path=Path("/tmp/minimal.py"),
        )

        assert plugin.hooks == {}
        assert plugin.metadata == {}
