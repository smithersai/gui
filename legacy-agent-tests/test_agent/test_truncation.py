"""
Tests for tool output truncation functionality.
"""
import importlib
import os
import subprocess
import sys
import tempfile
import pytest
from agent.agent import MAX_BASH_OUTPUT_LENGTH
from agent.tools.filesystem import set_current_session_id
from agent.tools.read_file_safe import (
    MAX_LINE_LENGTH,
    read_file_safe as read_file_safe_impl,
    truncate_long_lines as _truncate_long_lines,
)
from core.state import get_file_tracker


def import_mcp_server_shell():
    """Import mcp_server_shell.server only after a timeout-guarded probe."""
    try:
        subprocess.run(
            [sys.executable, "-c", "import mcp_server_shell.server"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except subprocess.TimeoutExpired:
        pytest.skip("mcp_server_shell.server import timed out in this environment")
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        pytest.skip(f"mcp_server_shell.server unavailable: {e}")

    return importlib.import_module("mcp_server_shell.server")


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
        mcp_server = import_mcp_server_shell()

        assert mcp_server.MAX_BASH_OUTPUT_LENGTH == 30000
        assert mcp_server.TRUNCATION_MESSAGE == "\n... (output truncated)"


class TestReadFileSafeTruncation:
    """Test read_file_safe tool with truncation."""

    @pytest.mark.asyncio
    async def test_read_file_safe_short_file(self, mock_env_vars):
        """Test reading a file with no truncation needed."""
        # Create a temporary file with short lines
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
            f.write("Line 1\n")
            f.write("Line 2\n")
            f.write("Line 3\n")
            temp_file = f.name

        try:
            result = await read_file_safe_impl(
                file_path=temp_file,
                working_dir=os.path.dirname(temp_file),
            )

            assert "Line 1" in result
            assert "Line 2" in result
            assert "Line 3" in result
            assert "truncated" not in result.lower()
        finally:
            os.unlink(temp_file)

    @pytest.mark.asyncio
    async def test_read_file_safe_long_lines(self, mock_env_vars):
        """Test reading a file with lines that need truncation."""
        # Create a temporary file with very long lines
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
            # Write a line longer than MAX_LINE_LENGTH
            long_line = "x" * (MAX_LINE_LENGTH + 500)
            f.write(long_line + "\n")
            f.write("Short line\n")
            temp_file = f.name

        try:
            result = await read_file_safe_impl(
                file_path=temp_file,
                working_dir=os.path.dirname(temp_file),
            )

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
        # Create a temporary file with multiple lines
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt') as f:
            for i in range(100):
                f.write(f"Line {i}\n")
            temp_file = f.name

        try:
            # Read with offset and limit
            result = await read_file_safe_impl(
                file_path=temp_file,
                offset=10,
                limit=5,
                working_dir=os.path.dirname(temp_file),
            )

            assert "Line 10" in result
            assert "Line 14" in result
            assert "Line 9" not in result  # Before offset
            assert "Line 15" not in result  # After limit
        finally:
            os.unlink(temp_file)

    @pytest.mark.asyncio
    async def test_read_file_safe_nonexistent_file(self, mock_env_vars, tmp_path):
        """Test reading a file that doesn't exist."""
        result = await read_file_safe_impl(
            file_path=str(tmp_path / "missing.txt"),
            working_dir=str(tmp_path),
        )

        assert "Error" in result
        assert "not found" in result.lower()

    @pytest.mark.asyncio
    async def test_read_file_safe_rejects_path_outside_working_dir(self, tmp_path):
        """Test read_file_safe cannot read outside its working directory."""
        outside_file = tmp_path.parent / f"{tmp_path.name}-outside.txt"
        outside_file.write_text("secret")

        try:
            result = await read_file_safe_impl(
                file_path=str(outside_file),
                working_dir=str(tmp_path),
            )
        finally:
            outside_file.unlink(missing_ok=True)

        assert "Error" in result
        assert "not in the current working directory" in result

    @pytest.mark.asyncio
    async def test_read_file_safe_marks_file_read(self, tmp_path):
        """Test successful reads update session file tracking."""
        set_current_session_id("read-file-safe-test")
        test_file = tmp_path / "tracked.txt"
        test_file.write_text("tracked")

        result = await read_file_safe_impl(
            file_path=str(test_file),
            working_dir=str(tmp_path),
        )

        assert result == "tracked"
        assert get_file_tracker("read-file-safe-test").is_read(str(test_file))


class TestTruncationMetadata:
    """Test that truncation metadata is properly reported."""

    def test_bash_truncation_metadata_fields(self):
        """Test that CommandResult has truncation metadata fields."""
        mcp_server = import_mcp_server_shell()

        # Create a result with truncation
        result = mcp_server.CommandResult(
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
        mcp_server = import_mcp_server_shell()

        # Create a result without truncation
        result = mcp_server.CommandResult(
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
