"""Plugin storage for persisting plugins to disk.

Provides CRUD operations for plugins stored in ~/.agent/plugins/.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

# Default plugin storage directory
PLUGINS_DIR = Path.home() / ".agent" / "plugins"
PLUGIN_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,80}$")


class InvalidPluginName(ValueError):
    """Raised when a plugin name cannot be mapped to a safe filename."""


def validate_plugin_name(name: str) -> str:
    """Validate and normalize a plugin name used for on-disk storage."""
    if name.endswith(".py"):
        name = name[:-3]
    if not PLUGIN_NAME_RE.fullmatch(name):
        raise InvalidPluginName(
            "Plugin names may only contain letters, numbers, underscores, and hyphens"
        )
    return name


def plugin_path_for(name: str, plugins_dir: Path | None = None) -> Path:
    """Return a safe plugin path under the configured plugin directory."""
    safe_name = validate_plugin_name(name)
    target_dir = ensure_plugins_dir(plugins_dir)
    root = target_dir.resolve()
    path = (root / f"{safe_name}.py").resolve()
    if path.parent != root:
        raise InvalidPluginName("Plugin path escapes the configured plugins directory")
    return path


def ensure_plugins_dir(plugins_dir: Path | None = None) -> Path:
    """Ensure the plugins directory exists.

    Args:
        plugins_dir: Optional custom plugins directory (defaults to PLUGINS_DIR)

    Returns:
        Path to the plugins directory
    """
    target_dir = plugins_dir or PLUGINS_DIR
    target_dir.mkdir(parents=True, exist_ok=True)
    return target_dir


def save_plugin(
    name: str,
    content: str,
    plugins_dir: Path | None = None,
) -> Path:
    """Save a plugin to disk.

    Args:
        name: Plugin name (used as filename without .py extension)
        content: Plugin source code
        plugins_dir: Optional custom plugins directory

    Returns:
        Path to the saved plugin file
    """
    safe_name = validate_plugin_name(name)
    path = plugin_path_for(safe_name, plugins_dir)
    path.write_text(content)
    logger.info("Saved plugin '%s' to %s", safe_name, path)
    return path


def list_plugins(plugins_dir: Path | None = None) -> list[Path]:
    """List all available plugin files.

    Args:
        plugins_dir: Optional custom plugins directory

    Returns:
        List of paths to plugin files
    """
    target_dir = ensure_plugins_dir(plugins_dir)
    plugins = []
    for path in target_dir.glob("*.py"):
        try:
            validate_plugin_name(path.stem)
        except InvalidPluginName:
            logger.warning("Ignoring plugin file with unsafe name: %s", path)
            continue
        plugins.append(path)
    return sorted(plugins, key=lambda p: p.stem)


def get_plugin_path(name: str, plugins_dir: Path | None = None) -> Optional[Path]:
    """Get the path to a plugin by name.

    Args:
        name: Plugin name (without .py extension)
        plugins_dir: Optional custom plugins directory

    Returns:
        Path to the plugin file, or None if not found
    """
    path = plugin_path_for(name, plugins_dir)
    return path if path.exists() else None


def get_plugin_content(name: str, plugins_dir: Path | None = None) -> Optional[str]:
    """Get the content of a plugin by name.

    Args:
        name: Plugin name (without .py extension)
        plugins_dir: Optional custom plugins directory

    Returns:
        Plugin source code, or None if not found
    """
    path = get_plugin_path(name, plugins_dir)
    if path:
        return path.read_text()
    return None


def delete_plugin(name: str, plugins_dir: Path | None = None) -> bool:
    """Delete a plugin by name.

    Args:
        name: Plugin name (without .py extension)
        plugins_dir: Optional custom plugins directory

    Returns:
        True if the plugin was deleted, False if not found
    """
    path = get_plugin_path(name, plugins_dir)
    if path:
        path.unlink()
        logger.info("Deleted plugin '%s' from %s", validate_plugin_name(name), path)
        return True
    return False


def plugin_exists(name: str, plugins_dir: Path | None = None) -> bool:
    """Check if a plugin exists.

    Args:
        name: Plugin name (without .py extension)
        plugins_dir: Optional custom plugins directory

    Returns:
        True if the plugin exists
    """
    return get_plugin_path(name, plugins_dir) is not None
