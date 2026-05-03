"""Non-executing plugin source inspection."""

from __future__ import annotations

import ast
from dataclasses import dataclass, field
from typing import Any

from .loader import PLUGIN_API_VERSION, _is_compatible_version

HOOK_DECORATORS = frozenset(
    {
        "on_begin",
        "on_tool_call",
        "on_resolve_tool",
        "on_tool_result",
        "on_final",
        "on_done",
    }
)


@dataclass
class PluginInspection:
    """Safe plugin metadata extracted without executing plugin code."""

    name: str
    hooks: list[str] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)


def inspect_plugin_source(source: str, fallback_name: str) -> PluginInspection:
    """Parse plugin source and return metadata/hooks without executing it."""
    tree = ast.parse(source, filename=f"{fallback_name}.py")
    metadata = _extract_metadata(tree, fallback_name)
    plugin_api = metadata.get("api", PLUGIN_API_VERSION)
    if not _is_compatible_version(plugin_api, PLUGIN_API_VERSION):
        raise ValueError(
            f"Incompatible plugin API version: {plugin_api} "
            f"(expected {PLUGIN_API_VERSION})"
        )

    hooks = sorted(_extract_hooks(tree))
    name = str(metadata.get("name", fallback_name))
    return PluginInspection(name=name, hooks=hooks, metadata=metadata)


def _extract_metadata(tree: ast.Module, fallback_name: str) -> dict[str, Any]:
    metadata: dict[str, Any] = {"api": PLUGIN_API_VERSION, "name": fallback_name}
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if not any(
            isinstance(target, ast.Name) and target.id == "__plugin__"
            for target in node.targets
        ):
            continue
        value = ast.literal_eval(node.value)
        if not isinstance(value, dict):
            raise ValueError("__plugin__ metadata must be a dict")
        metadata.update(value)
    return metadata


def _extract_hooks(tree: ast.Module) -> set[str]:
    hooks: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for decorator in node.decorator_list:
            hook_name = _decorator_name(decorator)
            if hook_name in HOOK_DECORATORS:
                hooks.add(hook_name)
    return hooks


def _decorator_name(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    if isinstance(node, ast.Call):
        return _decorator_name(node.func)
    return None
