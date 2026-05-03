"""Tests for plugin authoring mode prompt."""

from plugins.script_mode import get_plugin_author_prompt


def test_plugin_author_prompt_template_includes_required_imports():
    """The generated template should be directly runnable after saving."""
    prompt = get_plugin_author_prompt()

    assert "from plugins import ToolCall, ToolResult" in prompt
    assert "on_begin" in prompt
    assert "on_tool_call" in prompt
    assert "on_tool_result" in prompt
