"""Tests for plugin decorators."""

import pytest
from plugins.decorators import (
    on_begin,
    on_tool_call,
    on_resolve_tool,
    on_tool_result,
    on_final,
    on_done,
)


class TestDecorators:
    """Tests for hook decorators."""

    def test_on_begin_attaches_metadata(self):
        """Test on_begin decorator attaches hook name."""

        @on_begin
        async def my_begin(ctx):
            pass

        assert hasattr(my_begin, "_hook_name")
        assert my_begin._hook_name == "on_begin"

    def test_on_tool_call_attaches_metadata(self):
        """Test on_tool_call decorator attaches hook name."""

        @on_tool_call
        async def my_tool_call(ctx, call):
            pass

        assert hasattr(my_tool_call, "_hook_name")
        assert my_tool_call._hook_name == "on_tool_call"

    def test_on_resolve_tool_attaches_metadata(self):
        """Test on_resolve_tool decorator attaches hook name."""

        @on_resolve_tool
        async def my_resolve_tool(ctx, call):
            return None

        assert hasattr(my_resolve_tool, "_hook_name")
        assert my_resolve_tool._hook_name == "on_resolve_tool"

    def test_on_tool_result_attaches_metadata(self):
        """Test on_tool_result decorator attaches hook name."""

        @on_tool_result
        async def my_tool_result(ctx, call, result):
            pass

        assert hasattr(my_tool_result, "_hook_name")
        assert my_tool_result._hook_name == "on_tool_result"

    def test_on_final_attaches_metadata(self):
        """Test on_final decorator attaches hook name."""

        @on_final
        async def my_final(ctx, text):
            return text

        assert hasattr(my_final, "_hook_name")
        assert my_final._hook_name == "on_final"

    def test_on_done_attaches_metadata(self):
        """Test on_done decorator attaches hook name."""

        @on_done
        async def my_done(ctx):
            pass

        assert hasattr(my_done, "_hook_name")
        assert my_done._hook_name == "on_done"

    def test_decorator_preserves_function(self):
        """Test decorator returns the same function."""

        @on_begin
        async def original_func(ctx):
            return "result"

        # The decorated function should be the same object
        assert callable(original_func)
        assert original_func.__name__ == "original_func"

    def test_decorator_works_with_sync_functions(self):
        """Test decorators also work with sync functions."""

        @on_begin
        def sync_begin(ctx):
            pass

        assert hasattr(sync_begin, "_hook_name")
        assert sync_begin._hook_name == "on_begin"
