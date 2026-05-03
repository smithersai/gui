"""Tests for safe plugin source inspection."""

import pytest

from plugins.validator import inspect_plugin_source


def test_inspect_plugin_source_extracts_metadata_and_hooks():
    source = '''
__plugin__ = {"api": "1.0", "name": "sample"}

@on_begin
async def begin(ctx):
    pass

@on_tool_result
def result(ctx, call, result):
    return None
'''

    inspected = inspect_plugin_source(source, "fallback")

    assert inspected.name == "sample"
    assert inspected.metadata["api"] == "1.0"
    assert inspected.hooks == ["on_begin", "on_tool_result"]


def test_inspect_plugin_source_does_not_execute_code():
    source = '''
raise RuntimeError("executed")

@on_begin
async def begin(ctx):
    pass
'''

    inspected = inspect_plugin_source(source, "safe")

    assert inspected.name == "safe"
    assert inspected.hooks == ["on_begin"]


def test_inspect_plugin_source_rejects_bad_api_version():
    source = '''
__plugin__ = {"api": "99.0", "name": "future"}
'''

    with pytest.raises(ValueError, match="Incompatible plugin API version"):
        inspect_plugin_source(source, "future")
