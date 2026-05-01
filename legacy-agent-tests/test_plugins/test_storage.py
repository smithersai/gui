"""Tests for plugin storage."""

import pytest
from pathlib import Path
from plugins.storage import (
    ensure_plugins_dir,
    save_plugin,
    list_plugins,
    get_plugin_path,
    get_plugin_content,
    delete_plugin,
    plugin_exists,
)


class TestEnsurePluginsDir:
    """Tests for ensure_plugins_dir."""

    def test_creates_directory(self, tmp_path: Path):
        """Test directory is created if it doesn't exist."""
        plugins_dir = tmp_path / "plugins"
        assert not plugins_dir.exists()

        result = ensure_plugins_dir(plugins_dir)

        assert plugins_dir.exists()
        assert result == plugins_dir

    def test_existing_directory(self, tmp_path: Path):
        """Test returns existing directory."""
        plugins_dir = tmp_path / "plugins"
        plugins_dir.mkdir()

        result = ensure_plugins_dir(plugins_dir)

        assert result == plugins_dir


class TestSavePlugin:
    """Tests for save_plugin."""

    def test_save_creates_file(self, tmp_path: Path):
        """Test save_plugin creates a new file."""
        content = "print('hello')"

        path = save_plugin("test_plugin", content, tmp_path)

        assert path.exists()
        assert path.name == "test_plugin.py"
        assert path.read_text() == content

    def test_save_overwrites_existing(self, tmp_path: Path):
        """Test save_plugin overwrites existing file."""
        save_plugin("test_plugin", "original", tmp_path)
        path = save_plugin("test_plugin", "updated", tmp_path)

        assert path.read_text() == "updated"


class TestListPlugins:
    """Tests for list_plugins."""

    def test_empty_directory(self, tmp_path: Path):
        """Test list_plugins with empty directory."""
        plugins = list_plugins(tmp_path)

        assert plugins == []

    def test_lists_python_files(self, tmp_path: Path):
        """Test list_plugins returns .py files."""
        (tmp_path / "plugin1.py").write_text("pass")
        (tmp_path / "plugin2.py").write_text("pass")
        (tmp_path / "not_a_plugin.txt").write_text("text")

        plugins = list_plugins(tmp_path)

        assert len(plugins) == 2
        assert all(p.suffix == ".py" for p in plugins)

    def test_returns_sorted_list(self, tmp_path: Path):
        """Test list_plugins returns sorted list."""
        (tmp_path / "zebra.py").write_text("pass")
        (tmp_path / "alpha.py").write_text("pass")
        (tmp_path / "beta.py").write_text("pass")

        plugins = list_plugins(tmp_path)

        names = [p.stem for p in plugins]
        assert names == ["alpha", "beta", "zebra"]


class TestGetPluginPath:
    """Tests for get_plugin_path."""

    def test_existing_plugin(self, tmp_path: Path):
        """Test get_plugin_path returns path for existing plugin."""
        (tmp_path / "my_plugin.py").write_text("pass")

        path = get_plugin_path("my_plugin", tmp_path)

        assert path is not None
        assert path.name == "my_plugin.py"

    def test_nonexistent_plugin(self, tmp_path: Path):
        """Test get_plugin_path returns None for missing plugin."""
        path = get_plugin_path("missing", tmp_path)

        assert path is None


class TestGetPluginContent:
    """Tests for get_plugin_content."""

    def test_existing_plugin(self, tmp_path: Path):
        """Test get_plugin_content returns content."""
        expected = "# My plugin\nprint('hello')"
        (tmp_path / "my_plugin.py").write_text(expected)

        content = get_plugin_content("my_plugin", tmp_path)

        assert content == expected

    def test_nonexistent_plugin(self, tmp_path: Path):
        """Test get_plugin_content returns None for missing plugin."""
        content = get_plugin_content("missing", tmp_path)

        assert content is None


class TestDeletePlugin:
    """Tests for delete_plugin."""

    def test_delete_existing(self, tmp_path: Path):
        """Test delete_plugin removes existing file."""
        plugin_path = tmp_path / "to_delete.py"
        plugin_path.write_text("pass")

        result = delete_plugin("to_delete", tmp_path)

        assert result is True
        assert not plugin_path.exists()

    def test_delete_nonexistent(self, tmp_path: Path):
        """Test delete_plugin returns False for missing plugin."""
        result = delete_plugin("missing", tmp_path)

        assert result is False


class TestPluginExists:
    """Tests for plugin_exists."""

    def test_exists(self, tmp_path: Path):
        """Test plugin_exists returns True for existing plugin."""
        (tmp_path / "existing.py").write_text("pass")

        assert plugin_exists("existing", tmp_path) is True

    def test_not_exists(self, tmp_path: Path):
        """Test plugin_exists returns False for missing plugin."""
        assert plugin_exists("missing", tmp_path) is False
