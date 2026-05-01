"""Tests for plugin registry."""

import pytest
from pathlib import Path
from plugins.registry import PluginRegistry, plugin_registry
from plugins.loader import LoadedPlugin


@pytest.fixture
def registry(tmp_path: Path) -> PluginRegistry:
    """Create a registry with a temporary plugins directory."""
    return PluginRegistry(tmp_path)


@pytest.fixture
def sample_plugin_code() -> str:
    """Sample plugin code for testing."""
    return '''
__plugin__ = {"api": "1.0", "name": "sample"}

@on_begin
async def begin(ctx):
    ctx.state["initialized"] = True
'''


class TestPluginRegistryInit:
    """Tests for PluginRegistry initialization."""

    def test_default_plugins_dir(self):
        """Test default plugins directory is set."""
        registry = PluginRegistry()

        assert registry.plugins_dir is not None

    def test_custom_plugins_dir(self, tmp_path: Path):
        """Test custom plugins directory."""
        registry = PluginRegistry(tmp_path)

        assert registry.plugins_dir == tmp_path


class TestPluginRegistryDiscover:
    """Tests for discover method."""

    def test_discover_empty(self, registry: PluginRegistry, tmp_path: Path):
        """Test discover with no plugins."""
        plugins = registry.discover()

        assert plugins == []

    def test_discover_finds_plugins(
        self, registry: PluginRegistry, tmp_path: Path, sample_plugin_code: str
    ):
        """Test discover finds available plugins."""
        (tmp_path / "plugin1.py").write_text(sample_plugin_code)
        (tmp_path / "plugin2.py").write_text(sample_plugin_code)

        plugins = registry.discover()

        assert set(plugins) == {"plugin1", "plugin2"}


class TestPluginRegistryLoad:
    """Tests for load method."""

    def test_load_plugin(
        self, registry: PluginRegistry, tmp_path: Path, sample_plugin_code: str
    ):
        """Test loading a plugin."""
        (tmp_path / "sample.py").write_text(sample_plugin_code)

        plugin = registry.load("sample")

        assert isinstance(plugin, LoadedPlugin)
        assert plugin.name == "sample"
        assert "on_begin" in plugin.hooks

    def test_load_caches_plugin(
        self, registry: PluginRegistry, tmp_path: Path, sample_plugin_code: str
    ):
        """Test loaded plugin is cached."""
        (tmp_path / "sample.py").write_text(sample_plugin_code)

        plugin1 = registry.load("sample")
        plugin2 = registry.load("sample")

        assert plugin1 is plugin2

    def test_load_not_found(self, registry: PluginRegistry):
        """Test load raises for missing plugin."""
        with pytest.raises(ValueError, match="Plugin not found"):
            registry.load("nonexistent")


class TestPluginRegistryLoadMany:
    """Tests for load_many method."""

    def test_load_many(
        self, registry: PluginRegistry, tmp_path: Path, sample_plugin_code: str
    ):
        """Test loading multiple plugins."""
        (tmp_path / "p1.py").write_text(sample_plugin_code.replace("sample", "p1"))
        (tmp_path / "p2.py").write_text(sample_plugin_code.replace("sample", "p2"))

        plugins = registry.load_many(["p1", "p2"])

        assert len(plugins) == 2
        assert all(isinstance(p, LoadedPlugin) for p in plugins)

    def test_load_many_preserves_order(
        self, registry: PluginRegistry, tmp_path: Path, sample_plugin_code: str
    ):
        """Test load_many preserves order."""
        (tmp_path / "alpha.py").write_text(sample_plugin_code.replace("sample", "alpha"))
        (tmp_path / "beta.py").write_text(sample_plugin_code.replace("sample", "beta"))

        plugins = registry.load_many(["beta", "alpha"])

        assert plugins[0].name == "beta"
        assert plugins[1].name == "alpha"

    def test_load_many_raises_on_missing(
        self, registry: PluginRegistry, tmp_path: Path, sample_plugin_code: str
    ):
        """Test load_many raises if any plugin is missing."""
        (tmp_path / "exists.py").write_text(sample_plugin_code)

        with pytest.raises(ValueError, match="Plugin not found"):
            registry.load_many(["exists", "missing"])


class TestPluginRegistryReload:
    """Tests for reload method."""

    def test_reload_updates_plugin(
        self, registry: PluginRegistry, tmp_path: Path
    ):
        """Test reload loads fresh version."""
        plugin_path = tmp_path / "evolving.py"
        plugin_path.write_text('''
__plugin__ = {"api": "1.0", "name": "version1"}

@on_begin
async def begin(ctx):
    pass
''')

        plugin1 = registry.load("evolving")
        assert plugin1.name == "version1"

        # Update the plugin
        plugin_path.write_text('''
__plugin__ = {"api": "1.0", "name": "version2"}

@on_begin
async def begin(ctx):
    pass
''')

        plugin2 = registry.reload("evolving")
        assert plugin2.name == "version2"
        assert plugin1 is not plugin2


class TestPluginRegistryUnload:
    """Tests for unload method."""

    def test_unload_removes_from_cache(
        self, registry: PluginRegistry, tmp_path: Path, sample_plugin_code: str
    ):
        """Test unload removes plugin from cache."""
        (tmp_path / "sample.py").write_text(sample_plugin_code)
        registry.load("sample")

        result = registry.unload("sample")

        assert result is True
        assert not registry.is_loaded("sample")

    def test_unload_not_loaded(self, registry: PluginRegistry):
        """Test unload returns False for not loaded plugin."""
        result = registry.unload("not_loaded")

        assert result is False


class TestPluginRegistryIsLoaded:
    """Tests for is_loaded method."""

    def test_is_loaded_true(
        self, registry: PluginRegistry, tmp_path: Path, sample_plugin_code: str
    ):
        """Test is_loaded returns True for loaded plugin."""
        (tmp_path / "sample.py").write_text(sample_plugin_code)
        registry.load("sample")

        assert registry.is_loaded("sample") is True

    def test_is_loaded_false(self, registry: PluginRegistry):
        """Test is_loaded returns False for not loaded plugin."""
        assert registry.is_loaded("not_loaded") is False


class TestPluginRegistryGetLoaded:
    """Tests for get_loaded method."""

    def test_get_loaded_returns_plugin(
        self, registry: PluginRegistry, tmp_path: Path, sample_plugin_code: str
    ):
        """Test get_loaded returns cached plugin."""
        (tmp_path / "sample.py").write_text(sample_plugin_code)
        loaded = registry.load("sample")

        result = registry.get_loaded("sample")

        assert result is loaded

    def test_get_loaded_returns_none(self, registry: PluginRegistry):
        """Test get_loaded returns None for not loaded plugin."""
        result = registry.get_loaded("not_loaded")

        assert result is None


class TestPluginRegistryClearCache:
    """Tests for clear_cache method."""

    def test_clear_cache(
        self, registry: PluginRegistry, tmp_path: Path, sample_plugin_code: str
    ):
        """Test clear_cache removes all cached plugins."""
        (tmp_path / "p1.py").write_text(sample_plugin_code)
        (tmp_path / "p2.py").write_text(sample_plugin_code)
        registry.load("p1")
        registry.load("p2")

        count = registry.clear_cache()

        assert count == 2
        assert not registry.is_loaded("p1")
        assert not registry.is_loaded("p2")


class TestGlobalRegistry:
    """Tests for global plugin_registry."""

    def test_global_registry_exists(self):
        """Test global plugin_registry is available."""
        assert plugin_registry is not None
        assert isinstance(plugin_registry, PluginRegistry)
