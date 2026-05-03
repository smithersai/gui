"""Tools for the agent."""

from importlib import import_module

_SYMBOL_MODULES = {
    "grep": "agent.tools.grep",
    "Diagnostic": "agent.tools.lsp",
    "DiagnosticSeverity": "agent.tools.lsp",
    "DiagnosticsResult": "agent.tools.lsp",
    "diagnostics": "agent.tools.lsp",
    "get_all_diagnostics_summary": "agent.tools.lsp",
    "get_lsp_manager": "agent.tools.lsp",
    "hover": "agent.tools.lsp",
    "touch_file": "agent.tools.lsp",
    "MULTIEDIT_DESCRIPTION": "agent.tools.multiedit",
    "multiedit": "agent.tools.multiedit",
    "PATCH_DESCRIPTION": "agent.tools.patch",
    "patch": "agent.tools.patch",
}


def __getattr__(name: str):
    """Load public tool exports on first access."""
    module_name = _SYMBOL_MODULES.get(name)
    if module_name is None:
        raise AttributeError(f"module 'agent.tools' has no attribute {name!r}")
    value = getattr(import_module(module_name), name)
    globals()[name] = value
    return value


__all__ = [
    # Search tools
    "grep",
    # LSP tools
    "Diagnostic",
    "DiagnosticSeverity",
    "DiagnosticsResult",
    "diagnostics",
    "get_all_diagnostics_summary",
    "get_lsp_manager",
    "hover",
    "touch_file",
    # Edit tools
    "multiedit",
    "MULTIEDIT_DESCRIPTION",
    "patch",
    "PATCH_DESCRIPTION",
]
