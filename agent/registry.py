"""
Agent registry system for managing multiple agent configurations.
Similar to OpenCode's agent system with different tool permissions and behaviors.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any


class AgentMode(str, Enum):
    """Agent operation mode."""
    PRIMARY = "primary"  # Full-featured agent
    SUBAGENT = "subagent"  # Used for parallel execution


@dataclass
class AgentConfig:
    """Configuration for an agent with specific tools and permissions."""

    name: str
    description: str
    mode: AgentMode
    system_prompt: str
    temperature: float = 0.7
    top_p: float = 0.9

    # Tool configuration
    tools_enabled: dict[str, bool] = field(default_factory=dict)

    # Shell command restrictions (patterns allowed for plan agent)
    allowed_shell_patterns: list[str] | None = None  # None means all allowed

    def is_tool_enabled(self, tool_name: str) -> bool:
        """Check if a tool is enabled for this agent."""
        return self.tools_enabled.get(tool_name, False)

    def is_shell_command_allowed(self, command: str) -> bool:
        """Check if a shell command is allowed for this agent."""
        if self.allowed_shell_patterns is None:
            return True

        # Check if command matches any allowed pattern
        import re
        for pattern in self.allowed_shell_patterns:
            if re.match(pattern, command.strip()):
                return True
        return False


# Built-in agent configurations
BUILTIN_AGENTS: dict[str, AgentConfig] = {
    "build": AgentConfig(
        name="build",
        description="Default agent with all tools enabled for general development tasks",
        mode=AgentMode.PRIMARY,
        system_prompt="""You are a helpful coding assistant with full access to all development tools.

You have access to tools for:
- Executing Python and shell code
- Reading and writing files
- Searching through codebases
- Searching the web and fetching pages

When helping users, prefer to:
1. Read relevant files first to understand context
2. Make targeted changes rather than rewriting entire files
3. Explain what you're doing and why
4. Verify changes work correctly

Be concise but thorough. If you need to execute code to verify something works, do so.""",
        temperature=0.7,
        top_p=0.9,
        tools_enabled={
            "python": True,
            "shell": True,
            "read": True,
            "write": True,
            "search": True,
            "ls": True,
            "fetch": True,
            "web": True,
            "lsp": True,
        },
        allowed_shell_patterns=None,  # All commands allowed
    ),

    "general": AgentConfig(
        name="general",
        description="Multi-step parallel task execution specialist, optimized for subagent mode",
        mode=AgentMode.SUBAGENT,
        system_prompt="""You are a general-purpose coding assistant optimized for parallel task execution.

You excel at:
- Breaking down complex tasks into parallel steps
- Coordinating multiple operations efficiently
- Managing concurrent file operations and searches
- Aggregating results from parallel work

You have access to all development tools. Focus on:
1. Identifying opportunities for parallelization
2. Executing independent tasks concurrently
3. Providing clear progress updates
4. Synthesizing results effectively

Be efficient and thorough in your parallel execution strategy.""",
        temperature=0.7,
        top_p=0.9,
        tools_enabled={
            "python": True,
            "shell": True,
            "read": True,
            "write": True,
            "search": True,
            "ls": True,
            "fetch": True,
            "web": True,
            "lsp": True,
        },
        allowed_shell_patterns=None,  # All commands allowed
    ),

    "plan": AgentConfig(
        name="plan",
        description="Read-only planning agent with restricted shell commands for analysis",
        mode=AgentMode.PRIMARY,
        system_prompt="""You are a planning and analysis specialist with read-only access.

Your role is to:
- Analyze codebases and understand architecture
- Plan implementation strategies
- Review code and provide recommendations
- Gather information without making changes

You have access to:
- Read-only file operations
- Safe shell commands (ls, grep, git status, find, etc.)
- Web search and fetch
- Code search capabilities

Focus on:
1. Thorough analysis before recommending changes
2. Understanding project structure and patterns
3. Identifying potential issues and improvements
4. Creating detailed, actionable plans

You CANNOT write files or execute arbitrary code. Provide clear plans for others to implement.""",
        temperature=0.6,
        top_p=0.85,
        tools_enabled={
            "python": False,  # No code execution
            "shell": True,    # Limited to safe commands
            "read": True,
            "write": False,   # Read-only
            "search": True,
            "ls": True,
            "fetch": True,
            "web": True,
            "lsp": True,      # Read-only, useful for planning
        },
        # Only allow safe, read-only shell commands
        allowed_shell_patterns=[
            r"^ls\s+.*",
            r"^ls$",
            r"^grep\s+.*",
            r"^find\s+.*",
            r"^git\s+status.*",
            r"^git\s+log.*",
            r"^git\s+diff.*",
            r"^git\s+show.*",
            r"^git\s+branch.*",
            r"^cat\s+.*",
            r"^head\s+.*",
            r"^tail\s+.*",
            r"^wc\s+.*",
            r"^file\s+.*",
            r"^stat\s+.*",
            r"^du\s+.*",
            r"^df\s+.*",
            r"^pwd$",
            r"^echo\s+.*",
            r"^which\s+.*",
            r"^tree\s+.*",
        ],
    ),

    "explore": AgentConfig(
        name="explore",
        description="Fast codebase exploration specialist optimized for quick searches",
        mode=AgentMode.PRIMARY,
        system_prompt="""You are a codebase exploration specialist focused on fast, efficient discovery.

Your expertise:
- Rapidly searching through large codebases
- Finding patterns and connections across files
- Understanding project structure quickly
- Identifying relevant code sections

You have access to:
- Advanced search capabilities
- Directory exploration
- File reading
- Git tools for history

Focus on:
1. Speed and efficiency in exploration
2. Pattern recognition across multiple files
3. Quick identification of relevant code
4. Providing concise, targeted results

Prioritize breadth-first exploration to give users a quick understanding before diving deep.""",
        temperature=0.5,
        top_p=0.8,
        tools_enabled={
            "python": False,  # No execution, focus on speed
            "shell": True,    # For git and search commands
            "read": True,
            "write": False,   # Read-only for exploration
            "search": True,
            "ls": True,
            "fetch": False,   # No web access, focus on local code
            "web": False,
            "lsp": True,      # Useful for type exploration
        },
        allowed_shell_patterns=[
            r"^ls\s+.*",
            r"^ls$",
            r"^grep\s+.*",
            r"^find\s+.*",
            r"^git\s+.*",
            r"^tree\s+.*",
            r"^rg\s+.*",      # ripgrep
            r"^ag\s+.*",      # silver searcher
            r"^ack\s+.*",
            r"^fd\s+.*",      # fd find
        ],
    ),
}


class AgentRegistry:
    """Registry for managing agent configurations."""

    def __init__(self, project_root: Path | None = None, load_custom: bool = True):
        """
        Initialize registry with built-in agents and load custom configs.

        Args:
            project_root: Optional project root for loading custom configs
            load_custom: Whether to load project config immediately
        """
        self._agents: dict[str, AgentConfig] = BUILTIN_AGENTS.copy()
        self._custom_project_root = project_root
        self._custom_loaded = False
        if load_custom:
            self.load_custom_agents_once()

    def load_custom_agents_once(self) -> None:
        """Load custom agent configs once, deferring pydantic config imports."""
        if self._custom_loaded:
            return
        self._load_custom_agents(self._custom_project_root)
        self._custom_loaded = True

    def _load_custom_agents(self, project_root: Path | None = None) -> None:
        """
        Load custom agent configurations from config file.

        Args:
            project_root: Optional project root for config loading
        """
        try:
            from config import get_config

            config = get_config(project_root)
            # Convert config agents to registry agent configs
            for name, agent_config in config.agents.items():
                # Build tools_enabled dict from config
                tools_enabled = {}
                if agent_config.tools:
                    # If specific tools are listed, only enable those
                    for tool in agent_config.tools:
                        tools_enabled[tool] = True
                else:
                    # If no tools specified, use global tools config
                    tools_enabled = {
                        "python": config.tools.python,
                        "shell": config.tools.shell,
                        "read": config.tools.read,
                        "write": config.tools.write,
                        "search": config.tools.search,
                        "ls": config.tools.ls,
                        "fetch": config.tools.fetch,
                        "web": config.tools.web,
                    }

                # Create AgentConfig from config file
                registry_config = AgentConfig(
                    name=name,
                    description=f"Custom agent: {name}",
                    mode=AgentMode.PRIMARY,  # Could be extended in config
                    system_prompt=agent_config.system_prompt or BUILTIN_AGENTS["build"].system_prompt,
                    temperature=agent_config.temperature or 0.7,
                    top_p=0.9,  # Could be added to config
                    tools_enabled=tools_enabled,
                    allowed_shell_patterns=None,  # Could be added to config permissions
                )
                self._agents[name] = registry_config
        except Exception as e:
            # Don't fail if config loading fails
            print(f"Warning: Failed to load custom agent configs: {e}")

    def register(self, config: AgentConfig) -> None:
        """
        Register a new agent configuration.

        Args:
            config: Agent configuration to register
        """
        self._agents[config.name] = config

    def get(self, name: str) -> AgentConfig | None:
        """
        Get agent configuration by name.

        Args:
            name: Agent name

        Returns:
            Agent configuration or None if not found
        """
        return self._agents.get(name)

    def list(self) -> list[AgentConfig]:
        """
        List all registered agents.

        Returns:
            List of all agent configurations
        """
        return list(self._agents.values())

    def list_names(self) -> list[str]:
        """
        List all registered agent names.

        Returns:
            List of agent names
        """
        return list(self._agents.keys())

    def exists(self, name: str) -> bool:
        """
        Check if an agent exists.

        Args:
            name: Agent name

        Returns:
            True if agent exists
        """
        return name in self._agents


# Global registry instance. Custom config loading is deferred so importing this
# module does not initialize pydantic-heavy configuration models.
_registry = AgentRegistry(load_custom=False)


def get_agent_config(name: str) -> AgentConfig | None:
    """
    Get agent configuration by name from the global registry.

    Args:
        name: Agent name

    Returns:
        Agent configuration or None if not found
    """
    _registry.load_custom_agents_once()
    return _registry.get(name)


def list_agents() -> list[AgentConfig]:
    """
    List all available agents.

    Returns:
        List of all agent configurations
    """
    _registry.load_custom_agents_once()
    return _registry.list()


def list_agent_names() -> list[str]:
    """
    List all available agent names.

    Returns:
        List of agent names
    """
    _registry.load_custom_agents_once()
    return _registry.list_names()


def register_agent(config: AgentConfig) -> None:
    """
    Register a custom agent configuration.

    Args:
        config: Agent configuration to register
    """
    _registry.register(config)


def agent_exists(name: str) -> bool:
    """
    Check if an agent exists.

    Args:
        name: Agent name

    Returns:
        True if agent exists
    """
    _registry.load_custom_agents_once()
    return _registry.exists(name)
