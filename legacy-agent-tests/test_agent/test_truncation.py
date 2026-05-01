"""
Tests for tool output truncation functionality.
"""
import os
import tempfile
import pytest
from agent.agent import _truncate_long_lines, MAX_LINE_LENGTH, MAX_BASH_OUTPUT_LENGTH


class TestLineTruncation:
    """Test line truncation helper function."""

    def test_no_truncation_needed(self):
        """Test that short content is not truncated."""
        content = "Short line 1\nShort line 2\n"
        result, was_truncated, original_length = _truncate_long_lines(content)

        assert result == content
        assert was_truncated is False
        assert original_length == len(content)

    def test_truncate_single_long_line(self):
        """Test truncating a single line that exceeds max length."""
        long_line = "x" * (MAX_LINE_LENGTH + 100) + "\n"
        content = long_line
        result, was_truncated, original_length = _truncate_long_lines(content)

        assert was_truncated is True
        assert original_length == len(content)
        assert len(result) < len(content)
        assert "..." in result

    def test_truncate_multiple_long_lines(self):
        """Test truncating multiple lines that exceed max length."""
        long_line1 = "a" * (MAX_LINE_LENGTH + 50) + "\n"
        long_line2 = "b" * (MAX_LINE_LENGTH + 100) + "\n"
        short_line = "Short line\n"
        content = long_line1 + short_line + long_line2

        result, was_truncated, original_length = _truncate_long_lines(content)

        assert was_truncated is True
        assert original_length == len(content)
        # Check that short line is preserved
        assert "Short line" in result
        # Check that long lines are truncated
        lines = result.splitlines(keepends=True)
        for line in lines:
            assert len(line) <= MAX_LINE_LENGTH + 4  # +4 for "...\n"

    def test_exact_boundary_no_truncation(self):
        """Test that a line exactly at max length is not truncated."""
        exact_line = "x" * MAX_LINE_LENGTH + "\n"
        content = exact_line
        result, was_truncated, original_length = _truncate_long_lines(content)

        assert was_truncated is False
        assert result == content

    def test_boundary_plus_one_truncates(self):
        """Test that a line one character over max length is truncated."""
        over_line = "x" * (MAX_LINE_LENGTH + 1) + "\n"
        content = over_line
        result, was_truncated, original_length = _truncate_long_lines(content)

        assert was_truncated is True
        # Truncated line will be MAX_LINE_LENGTH + "...\n" (4 chars)
        # Original was MAX_LINE_LENGTH + 1 + "\n" (2 chars)
        # So truncated should be 2 chars longer than original
        assert len(result) == MAX_LINE_LENGTH + 4

    def test_empty_content(self):
        """Test truncation with empty content."""
        content = ""
        result, was_truncated, original_length = _truncate_long_lines(content)

        assert result == content
        assert was_truncated is False
        assert original_length == 0

    def test_custom_max_length(self):
        """Test truncation with custom max length."""
        custom_max = 100
        long_line = "y" * (custom_max + 50) + "\n"
        content = long_line
        result, was_truncated, original_length = _truncate_long_lines(content, custom_max)

        assert was_truncated is True
        assert "..." in result
        # Result should be custom_max + "...\n"
        assert len(result) <= custom_max + 4


class TestBashOutputTruncation:
    """Test bash output truncation via MCP server."""

    def test_max_bash_output_constant(self):
        """Verify MAX_BASH_OUTPUT_LENGTH constant is defined correctly."""
        assert MAX_BASH_OUTPUT_LENGTH == 30000

    def test_truncation_message_format(self):
        """Test that truncation produces expected message format."""
        # We can't easily test the MCP server directly, but we can verify
        # the constant is set correctly
        from mcp_server_shell.server import MAX_BASH_OUTPUT_LENGTH as MCP_MAX
        from mcp_server_shell.server import TRUNCATION_MESSAGE

        assert MCP_MAX == 30000
        assert TRUNCATION_MESSAGE == "\n... (output truncated)"


class TestReadFileSafeTruncation:
    """Test read_file_safe tool with truncation."""

    @pytest.mark.asyncio
    async def test_read_file_safe_short_file(self, mock_env_vars):
        """Test reading a file with no truncation needed."""
        from agent.agent import create_agent_with_mcp

        # Create a temporary file with short lines
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
            f.write("Line 1\n")
            f.write("Line 2\n")
            f.write("Line 3\n")
            temp_file = f.name

        try:
            async with create_agent_with_mcp() as agent:
                # Get the read_file_safe tool
                tools_dict = agent._function_toolset.tools
                assert 'read_file_safe' in tools_dict

                # Call the tool directly
                read_tool = tools_dict['read_file_safe']
                result = await read_tool.function(file_path=temp_file)

                assert "Line 1" in result
                assert "Line 2" in result
                assert "Line 3" in result
                assert "truncated" not in result.lower()
        finally:
            os.unlink(temp_file)

    @pytest.mark.asyncio
    async def test_read_file_safe_long_lines(self, mock_env_vars):
        """Test reading a file with lines that need truncation."""
        from agent.agent import create_agent_with_mcp

        # Create a temporary file with very long lines
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
            # Write a line longer than MAX_LINE_LENGTH
            long_line = "x" * (MAX_LINE_LENGTH + 500)
            f.write(long_line + "\n")
            f.write("Short line\n")
            temp_file = f.name

        try:
            async with create_agent_with_mcp() as agent:
                # Get the read_file_safe tool
                tools_dict = agent._function_toolset.tools
                read_tool = tools_dict['read_file_safe']
                result = await read_tool.function(file_path=temp_file)

                # Should indicate truncation
                assert "truncated" in result.lower()
                # Should preserve short line
                assert "Short line" in result
                # Should contain the truncation note
                assert "Max line length" in result
        finally:
            os.unlink(temp_file)

    @pytest.mark.asyncio
    async def test_read_file_safe_with_offset_and_limit(self, mock_env_vars):
        """Test reading a file with offset and limit parameters."""
        from agent.agent import create_agent_with_mcp

        # Create a temporary file with multiple lines
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
            for i in range(100):
                f.write(f"Line {i}\n")
            temp_file = f.name

        try:
            async with create_agent_with_mcp() as agent:
                tools_dict = agent._function_toolset.tools
                read_tool = tools_dict['read_file_safe']

                # Read with offset and limit
                result = await read_tool.function(file_path=temp_file, offset=10, limit=5)

                assert "Line 10" in result
                assert "Line 14" in result
                assert "Line 9" not in result  # Before offset
                assert "Line 15" not in result  # After limit
        finally:
            os.unlink(temp_file)

    @pytest.mark.asyncio
    async def test_read_file_safe_nonexistent_file(self, mock_env_vars):
        """Test reading a file that doesn't exist."""
        from agent.agent import create_agent_with_mcp

        async with create_agent_with_mcp() as agent:
            tools_dict = agent._function_toolset.tools
            read_tool = tools_dict['read_file_safe']

            result = await read_tool.function(file_path="/nonexistent/file.txt")

            assert "Error" in result
            assert "not found" in result.lower()


class TestTruncationMetadata:
    """Test that truncation metadata is properly reported."""

    def test_bash_truncation_metadata_fields(self):
        """Test that CommandResult has truncation metadata fields."""
        from mcp_server_shell.server import CommandResult

        # Create a result with truncation
        result = CommandResult(
            command="test",
            output="output",
            return_code=0,
            truncated=True,
            original_length=50000,
            max_length=30000
        )

        assert result.truncated is True
        assert result.original_length == 50000
        assert result.max_length == 30000

    def test_bash_no_truncation_metadata(self):
        """Test that CommandResult metadata is correct when not truncated."""
        from mcp_server_shell.server import CommandResult

        # Create a result without truncation
        result = CommandResult(
            command="test",
            output="short output",
            return_code=0,
            truncated=False,
            original_length=None,
            max_length=30000
        )

        assert result.truncated is False
        assert result.original_length is None
        assert result.max_length == 30000
