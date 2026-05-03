"""
Configuration package exports.

Public symbols are loaded on first access so importing lightweight modules such
as config.defaults does not initialize pydantic-backed configuration models.
"""

from importlib import import_module
from typing import Any

_SYMBOL_MODULES = {
    "DEFAULT_MODEL": "config.defaults",
    "DEFAULT_MODEL_PROVIDERS": "config.defaults",
    "DEFAULT_REASONING_EFFORT": "config.defaults",
    "DEFAULT_REVIEW_MODEL": "config.defaults",
    "CLAUDE_MD_FILENAME": "config.markdown_loader",
    "AGENTS_MD_FILENAME": "config.markdown_loader",
    "Config": "config.main_config",
    "AgentConfig": "config.agent_config",
    "ToolsConfig": "config.tools_config",
    "PermissionsConfig": "config.permissions_config",
    "MCPServerConfig": "config.mcp_server_config",
    "ExperimentalConfig": "config.experimental_config",
    "ModelProvider": "config.providers",
    "ProviderRegistry": "config.providers",
    "provider_registry": "config.providers",
    "load_config": "config.loader",
    "get_config": "config.loader",
    "get_working_directory": "config.loader",
    "load_config_file": "config.loader",
    "merge_configs": "config.loader",
    "strip_jsonc_comments": "config.loader",
    "load_system_prompt_markdown": "config.markdown_loader",
    "find_markdown_file": "config.markdown_loader",
}


def __getattr__(name: str) -> Any:
    """Load public config exports on first access."""
    module_name = _SYMBOL_MODULES.get(name)
    if module_name is None:
        raise AttributeError(f"module 'config' has no attribute {name!r}")
    value = getattr(import_module(module_name), name)
    globals()[name] = value
    return value


__all__ = [
    # Constants
    "DEFAULT_MODEL",
    "DEFAULT_MODEL_PROVIDERS",
    "DEFAULT_REASONING_EFFORT",
    "DEFAULT_REVIEW_MODEL",
    "CLAUDE_MD_FILENAME",
    "AGENTS_MD_FILENAME",
    # Config models
    "Config",
    "AgentConfig",
    "ToolsConfig",
    "PermissionsConfig",
    "MCPServerConfig",
    "ExperimentalConfig",
    # Provider models
    "ModelProvider",
    "ProviderRegistry",
    "provider_registry",
    # Loader functions
    "load_config",
    "get_config",
    "get_working_directory",
    "load_config_file",
    "merge_configs",
    "strip_jsonc_comments",
    # Markdown loader functions
    "load_system_prompt_markdown",
    "find_markdown_file",
]
