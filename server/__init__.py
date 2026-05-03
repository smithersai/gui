"""
OpenCode-compatible API server.

Implements the OpenCode API specification for use with OpenCode clients
(including Go Bubbletea TUI).
"""

from importlib import import_module
from typing import Any

_SYMBOL_MODULES = {
    "app": "server.app",
    "get_agent": "server.state",
    "set_agent": "server.state",
    "get_permission_checker": "server.state",
    "set_permission_checker": "server.state",
}


def __getattr__(name: str) -> Any:
    """Load server exports on first access."""
    module_name = _SYMBOL_MODULES.get(name)
    if module_name is None:
        raise AttributeError(f"module 'server' has no attribute {name!r}")
    value = getattr(import_module(module_name), name)
    globals()[name] = value
    return value


__all__ = [
    "app",
    "set_agent",
    "get_agent",
    "set_permission_checker",
    "get_permission_checker",
]
