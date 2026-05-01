"""
Tests for the configuration system.
"""

import json
import tempfile
from pathlib import Path

import pytest

from config import (
    Config,
    AgentConfig,
    ToolsConfig,
    PermissionsConfig,
    ExperimentalConfig,
    load_config,
    get_config,
    strip_jsonc_comments,
)


class TestStripJSONComments:
    """Test JSONC comment stripping."""

    def test_single_line_comments(self):
        """Test that single-line comments are stripped."""
        jsonc = """
        {
            // This is a comment
            "key": "value"
        }
        """
        result = strip_jsonc_comments(jsonc)
        assert "//" not in result
        assert json.loads(result) == {"key": "value"}

    def test_multi_line_comments(self):
        """Test that multi-line comments are stripped."""
        jsonc = """
        {
            /* This is a
               multi-line comment */
            "key": "value"
        }
        """
        result = strip_jsonc_comments(jsonc)
        assert "/*" not in result
        assert "*/" not in result
        assert json.loads(result) == {"key": "value"}

    def test_mixed_comments(self):
        """Test that mixed comments are stripped."""
        jsonc = """
        {
            // Single line
            "key1": "value1",
            /* Multi
               line */
            "key2": "value2"  // Trailing comment
        }
        """
        result = strip_jsonc_comments(jsonc)
        data = json.loads(result)
        assert data == {"key1": "value1", "key2": "value2"}


class TestConfigModels:
    """Test Pydantic config models."""

    def test_tools_config_defaults(self):
        """Test that ToolsConfig has correct defaults."""
        tools = ToolsConfig()
        assert tools.python is True
        assert tools.shell is True
        assert tools.read is True
        assert tools.write is True
        assert tools.search is True
        assert tools.ls is True
        assert tools.fetch is True
        assert tools.web is True

    def test_permissions_config_defaults(self):
        """Test that PermissionsConfig has correct defaults."""
        perms = PermissionsConfig()
        assert perms.edit_patterns == ["**/*"]
        assert perms.bash_patterns == ["*"]
        assert perms.webfetch_enabled is True

    def test_experimental_config_defaults(self):
        """Test that ExperimentalConfig has correct defaults."""
        exp = ExperimentalConfig()
        assert exp.streaming is False
        assert exp.parallel_tools is False
        assert exp.caching is False

    def test_agent_config(self):
        """Test AgentConfig model."""
        agent = AgentConfig(
            model_id="claude-sonnet-4-20250514",
            system_prompt="Test prompt",
            tools=["read", "write"],
            temperature=0.5,
        )
        assert agent.model_id == "claude-sonnet-4-20250514"
        assert agent.system_prompt == "Test prompt"
        assert agent.tools == ["read", "write"]
        assert agent.temperature == 0.5

    def test_config_defaults(self):
        """Test that Config has correct defaults."""
        config = Config()
        assert config.agents == {}
        assert config.theme == "default"
        assert config.keybindings == {}
        assert config.mcp == {}
        assert isinstance(config.tools, ToolsConfig)
        assert isinstance(config.permissions, PermissionsConfig)
        assert isinstance(config.experimental, ExperimentalConfig)


class TestConfigLoading:
    """Test configuration file loading."""

    def test_load_empty_config(self):
        """Test loading with no config file."""
        with tempfile.TemporaryDirectory() as tmpdir:
            config = load_config(Path(tmpdir))
            # Should return default config
            assert isinstance(config, Config)
            assert config.theme == "default"

    def test_load_json_config(self):
        """Test loading JSON config."""
        with tempfile.TemporaryDirectory() as tmpdir:
            config_file = Path(tmpdir) / "opencode.json"
            config_file.write_text(json.dumps({
                "theme": "dark",
                "tools": {
                    "python": False
                }
            }))

            config = load_config(Path(tmpdir))
            assert config.theme == "dark"
            assert config.tools.python is False

    def test_load_jsonc_config(self):
        """Test loading JSONC config with comments."""
        with tempfile.TemporaryDirectory() as tmpdir:
            config_file = Path(tmpdir) / "opencode.jsonc"
            config_file.write_text("""
            {
                // Theme configuration
                "theme": "light",
                /* Tools config */
                "tools": {
                    "shell": false  // Disable shell
                }
            }
            """)

            config = load_config(Path(tmpdir))
            assert config.theme == "light"
            assert config.tools.shell is False

    def test_load_custom_agents(self):
        """Test loading custom agent configurations."""
        with tempfile.TemporaryDirectory() as tmpdir:
            config_file = Path(tmpdir) / "opencode.jsonc"
            config_file.write_text(json.dumps({
                "agents": {
                    "custom": {
                        "model_id": "claude-opus-4-5-20251101",
                        "system_prompt": "Custom agent",
                        "tools": ["read", "write"],
                        "temperature": 0.3
                    }
                }
            }))

            config = load_config(Path(tmpdir))
            assert "custom" in config.agents
            agent = config.agents["custom"]
            assert agent.model_id == "claude-opus-4-5-20251101"
            assert agent.system_prompt == "Custom agent"
            assert agent.tools == ["read", "write"]
            assert agent.temperature == 0.3

    def test_config_file_precedence(self):
        """Test that opencode.jsonc takes precedence."""
        with tempfile.TemporaryDirectory() as tmpdir:
            # Create both files
            (Path(tmpdir) / "opencode.json").write_text(
                json.dumps({"theme": "json"})
            )
            (Path(tmpdir) / "opencode.jsonc").write_text(
                json.dumps({"theme": "jsonc"})
            )

            config = load_config(Path(tmpdir))
            # jsonc should win
            assert config.theme == "jsonc"


class TestConfigCache:
    """Test configuration caching."""

    def test_cache_returns_same_instance(self):
        """Test that get_config returns cached instance."""
        # Clear cache first
        get_config.cache_clear()

        config1 = get_config()
        config2 = get_config()

        # Should be the same instance
        assert config1 is config2

    def test_cache_clear(self):
        """Test that cache can be cleared."""
        get_config.cache_clear()

        config1 = get_config()

        get_config.cache_clear()

        config2 = get_config()

        # Should be equal but not the same instance
        assert config1 == config2
