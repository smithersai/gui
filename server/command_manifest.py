"""Pure slash-command manifest helpers."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class BuiltInCommand:
    """A built-in slash command definition."""

    name: str
    description: str


BUILTIN_COMMANDS = [
    BuiltInCommand(name="help", description="Show help information"),
    BuiltInCommand(name="clear", description="Clear conversation"),
    BuiltInCommand(name="new", description="Start new session"),
    BuiltInCommand(name="sessions", description="List all sessions"),
    BuiltInCommand(name="compact", description="Summarize conversation to reduce context"),
    BuiltInCommand(name="model", description="Select AI model"),
    BuiltInCommand(name="agent", description="Select agent mode"),
    BuiltInCommand(name="theme", description="Change color theme"),
    BuiltInCommand(name="settings", description="Open settings"),
    BuiltInCommand(name="diff", description="Show file changes in session"),
    BuiltInCommand(name="copy", description="Copy last response"),
    BuiltInCommand(name="quit", description="Exit application"),
    BuiltInCommand(name="plugin", description="Create a new plugin interactively"),
    BuiltInCommand(
        name="script",
        description="Create a new plugin interactively (alias for /plugin)",
    ),
]
