"""Pydantic AI agent package."""

from importlib import import_module

_SYMBOL_MODULES = {
    "create_agent": "agent.agent",
    "create_agent_with_mcp": "agent.agent",
    "AgentConfig": "agent.registry",
    "AgentMode": "agent.registry",
    "get_agent_config": "agent.registry",
    "list_agents": "agent.registry",
    "list_agent_names": "agent.registry",
    "register_agent": "agent.registry",
    "agent_exists": "agent.registry",
    "AgentWrapper": "agent.wrapper",
    "StreamEvent": "agent.wrapper",
    "create_mcp_wrapper": "agent.wrapper",
    "create_simple_wrapper": "agent.wrapper",
}


def __getattr__(name: str):
    """Load public agent exports on first access."""
    module_name = _SYMBOL_MODULES.get(name)
    if module_name is None:
        raise AttributeError(f"module 'agent' has no attribute {name!r}")
    value = getattr(import_module(module_name), name)
    globals()[name] = value
    return value


__all__ = [
    # Agent creation
    "create_agent",
    "create_agent_with_mcp",
    # Wrappers
    "AgentWrapper",
    "StreamEvent",
    "create_mcp_wrapper",
    "create_simple_wrapper",
    # Registry
    "AgentConfig",
    "AgentMode",
    "get_agent_config",
    "list_agents",
    "list_agent_names",
    "register_agent",
    "agent_exists",
]
