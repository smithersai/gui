"""Main Config model."""

from typing import Any, Optional
from pydantic import BaseModel, Field

from .agent_config import AgentConfig
from .experimental_config import ExperimentalConfig
from .mcp_server_config import MCPServerConfig
from .permissions_config import PermissionsConfig
from .tools_config import ToolsConfig


class Config(BaseModel):
    """Main configuration model."""

    agents: dict[str, AgentConfig] = Field(
        default_factory=dict,
        description="Custom agent configurations by name",
    )
    tools: ToolsConfig = Field(
        default_factory=ToolsConfig,
        description="Tool enable/disable flags",
    )
    permissions: PermissionsConfig = Field(
        default_factory=PermissionsConfig,
        description="Default permissions",
    )
    theme: str = Field(
        default="default",
        description="Default theme name",
    )
    keybindings: dict[str, str] = Field(
        default_factory=dict,
        description="Custom keybindings",
    )
    mcp: dict[str, MCPServerConfig] = Field(
        default_factory=dict,
        description="MCP server configurations by name",
    )
    experimental: ExperimentalConfig = Field(
        default_factory=ExperimentalConfig,
        description="Experimental features flags",
    )
    model: Optional[str] = Field(
        default=None,
        description="Override default model for the active provider",
    )
    model_provider: str = Field(
        default="anthropic",
        description="Active model provider ID (anthropic, openai, ollama, etc.)",
    )
    model_providers: dict[str, dict[str, Any]] = Field(
        default_factory=dict,
        description="Custom model provider configurations",
    )
