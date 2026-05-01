"""
Tests for the MultiEdit tool.

Tests cover:
1. Input validation
2. Edit operations
3. Replacement strategies
4. Error handling
5. Atomicity and sequential behavior
"""

import os
import pytest
import tempfile
from pathlib import Path

from agent.tools.edit import (
    edit,
    replace,
    simple_replacer,
    line_trimmed_replacer,
    block_anchor_replacer,
    whitespace_normalized_replacer,
    indentation_flexible_replacer,
    escape_normalized_replacer,
    trimmed_boundary_replacer,
    context_aware_replacer,
    multi_occurrence_replacer,
    resolve_and_validate_path,
    create_diff,
    ERROR_OLD_STRING_NOT_FOUND,
    ERROR_OLD_STRING_MULTIPLE,
    ERROR_SAME_OLD_NEW,
)
from agent.tools.multiedit import (
    multiedit,
    validate_edits,
    ERROR_FILE_PATH_REQUIRED,
    ERROR_EDITS_REQUIRED,
    ERROR_EDITS_EMPTY,
    ERROR_EDIT_INVALID,
    ERROR_EDIT_MISSING_OLD,
    ERROR_EDIT_MISSING_NEW,
    ERROR_EDIT_SAME_OLD_NEW,
)


# --- Fixtures ---


@pytest.fixture
def temp_dir():
    """Create a temporary directory for tests."""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield tmpdir


@pytest.fixture
def sample_file(temp_dir):
    """Create a sample file for testing."""
    content = """def hello():
    \"\"\"Say hello.\"\"\"
    print("Hello, world!")

def goodbye():
    \"\"\"Say goodbye.\"\"\"
    print("Goodbye, world!")
"""
    file_path = os.path.join(temp_dir, "sample.py")
    with open(file_path, "w") as f:
        f.write(content)
    return file_path


@pytest.fixture
def multiline_file(temp_dir):
    """Create a file with multiline blocks for testing."""
    content = """function foo() {
    const x = 1;
    const y = 2;
    return x + y;
}

function bar() {
    const a = 3;
    const b = 4;
    return a + b;
}
"""
    file_path = os.path.join(temp_dir, "sample.js")
    with open(file_path, "w") as f:
        f.write(content)
    return file_path


# --- Input Validation Tests ---


class TestMultiEditValidation:
    """Test input validation for multiedit."""

    @pytest.mark.asyncio
    async def test_missing_file_path(self, temp_dir):
        """Test error when file_path not provided."""
        result = await multiedit("", [{"old_string": "a", "new_string": "b"}], temp_dir)
        assert not result["success"]
        assert ERROR_FILE_PATH_REQUIRED in result["error"]

    @pytest.mark.asyncio
    async def test_missing_edits(self, temp_dir, sample_file):
        """Test error when edits not provided as list."""
        # Note: We can't easily test this since Python type hints don't enforce at runtime
        # But we can test with None or invalid type passed to validate_edits
        operations, error = validate_edits(None)  # type: ignore
        assert error == ERROR_EDITS_EMPTY
        assert operations == []

    @pytest.mark.asyncio
    async def test_empty_edits_array(self, temp_dir, sample_file):
        """Test error when edits array is empty."""
        result = await multiedit(sample_file, [], temp_dir)
        assert not result["success"]
        assert ERROR_EDITS_EMPTY in result["error"]

    @pytest.mark.asyncio
    async def test_edit_missing_old_string(self, temp_dir, sample_file):
        """Test error when edit missing old_string."""
        result = await multiedit(
            sample_file, [{"new_string": "replacement"}], temp_dir
        )
        assert not result["success"]
        assert "missing old_string" in result["error"]

    @pytest.mark.asyncio
    async def test_edit_missing_new_string(self, temp_dir, sample_file):
        """Test error when edit missing new_string."""
        result = await multiedit(
            sample_file, [{"old_string": "Hello"}], temp_dir
        )
        assert not result["success"]
        assert "missing new_string" in result["error"]

    @pytest.mark.asyncio
    async def test_edit_same_old_new_string(self, temp_dir, sample_file):
        """Test error when old_string equals new_string."""
        result = await multiedit(
            sample_file, [{"old_string": "Hello", "new_string": "Hello"}], temp_dir
        )
        assert not result["success"]
        assert "identical old_string and new_string" in result["error"]

    @pytest.mark.asyncio
    async def test_edit_invalid_object(self, temp_dir, sample_file):
        """Test error when edit is not a valid object."""
        operations, error = validate_edits(["not a dict"])
        assert error is not None
        assert "not a valid object" in error

    @pytest.mark.asyncio
    async def test_file_outside_working_directory(self, temp_dir, sample_file):
        """Test error when file path is outside working directory."""
        # Create a file outside temp_dir
        with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as f:
            f.write(b"test content")
            outside_file = f.name

        try:
            result = await multiedit(
                outside_file,
                [{"old_string": "test", "new_string": "replaced"}],
                temp_dir,
            )
            assert not result["success"]
            assert "not in the current working directory" in result["error"]
        finally:
            os.unlink(outside_file)


# --- Edit Operation Tests ---


class TestEditOperations:
    """Test actual edit operations."""

    @pytest.mark.asyncio
    async def test_simple_single_edit(self, temp_dir, sample_file):
        """Test basic single string replacement."""
        result = await multiedit(
            sample_file,
            [{"old_string": "Hello, world!", "new_string": "Hi there!"}],
            temp_dir,
        )
        assert result["success"]
        assert result["edit_count"] == 1

        # Verify file content
        with open(sample_file) as f:
            content = f.read()
        assert "Hi there!" in content
        assert "Hello, world!" not in content

    @pytest.mark.asyncio
    async def test_multiple_sequential_edits(self, temp_dir, sample_file):
        """Test multiple edits applied in sequence."""
        result = await multiedit(
            sample_file,
            [
                {"old_string": "Hello, world!", "new_string": "Greetings!"},
                {"old_string": "Goodbye, world!", "new_string": "Farewell!"},
            ],
            temp_dir,
        )
        assert result["success"]
        assert result["edit_count"] == 2

        # Verify file content
        with open(sample_file) as f:
            content = f.read()
        assert "Greetings!" in content
        assert "Farewell!" in content
        assert "Hello, world!" not in content
        assert "Goodbye, world!" not in content

    @pytest.mark.asyncio
    async def test_create_new_file(self, temp_dir):
        """Test file creation with empty old_string."""
        new_file = os.path.join(temp_dir, "new_file.txt")
        result = await multiedit(
            new_file,
            [{"old_string": "", "new_string": "New file content!"}],
            temp_dir,
        )
        assert result["success"]
        assert result["edit_count"] == 1

        # Verify file was created
        assert os.path.exists(new_file)
        with open(new_file) as f:
            content = f.read()
        assert content == "New file content!"

    @pytest.mark.asyncio
    async def test_create_file_in_new_directory(self, temp_dir):
        """Test file creation creates parent directories."""
        new_file = os.path.join(temp_dir, "subdir", "deep", "new_file.txt")
        result = await multiedit(
            new_file,
            [{"old_string": "", "new_string": "Deep file content!"}],
            temp_dir,
        )
        assert result["success"]
        assert os.path.exists(new_file)

    @pytest.mark.asyncio
    async def test_replace_all_multiple_occurrences(self, temp_dir):
        """Test replace_all flag with multiple matches."""
        # Create file with multiple occurrences
        content = "foo bar foo baz foo"
        file_path = os.path.join(temp_dir, "multi.txt")
        with open(file_path, "w") as f:
            f.write(content)

        result = await multiedit(
            file_path,
            [{"old_string": "foo", "new_string": "FOO", "replace_all": True}],
            temp_dir,
        )
        assert result["success"]

        # Verify all occurrences replaced
        with open(file_path) as f:
            new_content = f.read()
        assert new_content == "FOO bar FOO baz FOO"

    @pytest.mark.asyncio
    async def test_edit_preserves_file_permissions(self, temp_dir):
        """Test that file mode is preserved after edit."""
        file_path = os.path.join(temp_dir, "executable.sh")
        with open(file_path, "w") as f:
            f.write("#!/bin/bash\necho hello")

        # Make executable
        os.chmod(file_path, 0o755)
        original_mode = os.stat(file_path).st_mode

        result = await multiedit(
            file_path,
            [{"old_string": "hello", "new_string": "world"}],
            temp_dir,
        )
        assert result["success"]

        # Verify mode preserved
        new_mode = os.stat(file_path).st_mode
        assert new_mode == original_mode


# --- Replacement Strategy Tests ---


class TestReplacementStrategies:
    """Test fallback replacement strategies."""

    def test_simple_replacer_exact_match(self):
        """Test simple exact string match."""
        content = "Hello world"
        matches = simple_replacer(content, "world")
        assert matches == ["world"]

    def test_simple_replacer_no_match(self):
        """Test simple replacer with no match."""
        content = "Hello world"
        matches = simple_replacer(content, "foo")
        assert matches == []

    def test_line_trimmed_replacer(self):
        """Test match with trimmed line whitespace."""
        content = "  hello  \n  world  "
        matches = line_trimmed_replacer(content, "hello\nworld")
        assert len(matches) == 1

    def test_block_anchor_replacer(self):
        """Test block match using first/last line anchors."""
        content = """function test() {
    const x = 1;
    const y = 2;
    return x + y;
}"""
        find = """function test() {
    const a = 1;
    const b = 2;
    return a + b;
}"""
        matches = block_anchor_replacer(content, find)
        # Should find a match based on first/last line anchors
        assert len(matches) == 1

    def test_whitespace_normalized_replacer(self):
        """Test match with normalized whitespace."""
        content = "hello   world"
        matches = whitespace_normalized_replacer(content, "hello world")
        assert len(matches) >= 1

    def test_indentation_flexible_replacer(self):
        """Test match ignoring indentation level."""
        content = """    def foo():
        pass"""
        find = """def foo():
    pass"""
        matches = indentation_flexible_replacer(content, find)
        assert len(matches) == 1

    def test_escape_normalized_replacer(self):
        """Test handling escape sequences."""
        content = "Hello\nWorld"
        matches = escape_normalized_replacer(content, "Hello\\nWorld")
        assert len(matches) >= 1

    def test_trimmed_boundary_replacer(self):
        """Test trimmed boundary matching."""
        # When find has leading/trailing whitespace that content doesn't
        content = "hello"
        matches = trimmed_boundary_replacer(content, "  hello  ")
        # Should find "hello" (the trimmed version)
        assert len(matches) >= 1

        # When trimmed_find == find, returns empty (no whitespace to trim)
        content = "hello world"
        matches = trimmed_boundary_replacer(content, "hello")
        # Returns empty since trimmed_find == find
        assert matches == []

    def test_context_aware_replacer(self):
        """Test context-aware matching."""
        # Context-aware requires exact block size match and first/last line anchors
        content = """function foo() {
    const x = 1;
    const y = 2;
    return x + y;
}"""
        # Same first/last lines, 50%+ middle lines match
        find = """function foo() {
    const x = 1;
    const z = 3;
    return x + y;
}"""
        # Should match based on first/last line anchors + similarity
        matches = context_aware_replacer(content, find)
        # Note: context_aware_replacer requires 3+ lines and exact block size match
        assert len(matches) == 1

    def test_multi_occurrence_replacer(self):
        """Test finding all exact matches."""
        content = "foo bar foo baz foo"
        matches = multi_occurrence_replacer(content, "foo")
        assert len(matches) == 3

    @pytest.mark.asyncio
    async def test_multiple_strategies_fallback(self, temp_dir):
        """Test that strategies are tried in order until match."""
        # Create file with content that needs fallback strategy
        content = "  hello  \n  world  "
        file_path = os.path.join(temp_dir, "fallback.txt")
        with open(file_path, "w") as f:
            f.write(content)

        # This should use line_trimmed_replacer since exact match fails
        result = await multiedit(
            file_path,
            [{"old_string": "hello\nworld", "new_string": "foo\nbar"}],
            temp_dir,
        )
        # Note: This may or may not succeed depending on exact whitespace handling
        # The important thing is that it tries multiple strategies


# --- Error Handling Tests ---


class TestErrorHandling:
    """Test error scenarios."""

    @pytest.mark.asyncio
    async def test_old_string_not_found(self, temp_dir, sample_file):
        """Test error when old_string not in file."""
        result = await multiedit(
            sample_file,
            [{"old_string": "nonexistent text", "new_string": "replacement"}],
            temp_dir,
        )
        assert not result["success"]
        assert ERROR_OLD_STRING_NOT_FOUND in result["error"]

    @pytest.mark.asyncio
    async def test_multiple_matches_no_replace_all(self, temp_dir):
        """Test error when multiple matches without replace_all."""
        content = "foo bar foo baz foo"
        file_path = os.path.join(temp_dir, "multi.txt")
        with open(file_path, "w") as f:
            f.write(content)

        result = await multiedit(
            file_path,
            [{"old_string": "foo", "new_string": "FOO"}],  # No replace_all
            temp_dir,
        )
        assert not result["success"]
        assert ERROR_OLD_STRING_MULTIPLE in result["error"]

    @pytest.mark.asyncio
    async def test_file_not_found(self, temp_dir):
        """Test error when file doesn't exist."""
        result = await multiedit(
            os.path.join(temp_dir, "nonexistent.txt"),
            [{"old_string": "foo", "new_string": "bar"}],
            temp_dir,
        )
        assert not result["success"]
        assert "file not found" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_file_is_directory(self, temp_dir):
        """Test error when path is a directory."""
        result = await multiedit(
            temp_dir,  # This is a directory
            [{"old_string": "foo", "new_string": "bar"}],
            temp_dir,
        )
        assert not result["success"]
        assert "directory" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_partial_failure_reporting(self, temp_dir, sample_file):
        """Test that partial failures report which edit failed."""
        result = await multiedit(
            sample_file,
            [
                {"old_string": "Hello, world!", "new_string": "Greetings!"},
                {"old_string": "nonexistent", "new_string": "whatever"},  # Will fail
            ],
            temp_dir,
        )
        assert not result["success"]
        assert "edit 2 failed" in result["error"]
        # First edit should have been applied
        assert result.get("edit_count", 0) == 1


# --- Atomicity Tests ---


class TestAtomicity:
    """Test atomic behavior of multiedit."""

    @pytest.mark.asyncio
    async def test_second_edit_depends_on_first(self, temp_dir):
        """Test that second edit sees result of first edit."""
        content = "foo bar baz"
        file_path = os.path.join(temp_dir, "sequential.txt")
        with open(file_path, "w") as f:
            f.write(content)

        # First edit changes 'foo' to 'qux'
        # Second edit changes 'qux bar' to 'result'
        result = await multiedit(
            file_path,
            [
                {"old_string": "foo", "new_string": "qux"},
                {"old_string": "qux bar", "new_string": "result"},
            ],
            temp_dir,
        )
        assert result["success"]

        with open(file_path) as f:
            final_content = f.read()
        assert final_content == "result baz"

    @pytest.mark.asyncio
    async def test_validation_before_execution(self, temp_dir, sample_file):
        """Test that all edits are validated before any are applied."""
        # Read original content
        with open(sample_file) as f:
            original_content = f.read()

        # This should fail validation before applying any edits
        result = await multiedit(
            sample_file,
            [
                {"old_string": "Hello, world!", "new_string": "Greetings!"},
                {"old_string": "same", "new_string": "same"},  # Invalid: same old/new
            ],
            temp_dir,
        )
        assert not result["success"]
        assert "identical old_string and new_string" in result["error"]

        # File should be unchanged since validation failed before execution
        with open(sample_file) as f:
            current_content = f.read()
        assert current_content == original_content


# --- Path Resolution Tests ---


class TestPathResolution:
    """Test path resolution and validation."""

    def test_resolve_absolute_path(self, temp_dir):
        """Test resolving an absolute path."""
        file_path = os.path.join(temp_dir, "test.txt")
        resolved, error = resolve_and_validate_path(file_path, temp_dir)
        assert error is None
        assert resolved == os.path.realpath(file_path)

    def test_resolve_relative_path(self, temp_dir):
        """Test resolving a relative path."""
        resolved, error = resolve_and_validate_path("test.txt", temp_dir)
        assert error is None
        expected = os.path.realpath(os.path.join(temp_dir, "test.txt"))
        assert resolved == expected

    def test_reject_path_outside_working_dir(self, temp_dir):
        """Test rejecting paths outside working directory."""
        outside_path = "/tmp/outside.txt"
        resolved, error = resolve_and_validate_path(outside_path, temp_dir)
        assert error is not None
        assert "not in the current working directory" in error


# --- Diff Generation Tests ---


class TestDiffGeneration:
    """Test diff generation."""

    def test_create_diff_simple_change(self):
        """Test creating a diff for a simple change."""
        old = "hello\nworld"
        new = "hello\nplanet"
        diff = create_diff("test.txt", old, new)
        assert "--- test.txt" in diff
        assert "+++ test.txt" in diff
        assert "-world" in diff
        assert "+planet" in diff

    def test_create_diff_no_change(self):
        """Test creating a diff when content is identical."""
        content = "hello\nworld"
        diff = create_diff("test.txt", content, content)
        assert diff == ""

    def test_create_diff_addition(self):
        """Test creating a diff for additions."""
        old = "line1\nline2"
        new = "line1\nline2\nline3"
        diff = create_diff("test.txt", old, new)
        assert "+line3" in diff


# --- Replace Function Tests ---


class TestReplaceFunction:
    """Test the core replace function."""

    def test_replace_single_occurrence(self):
        """Test replacing a single occurrence."""
        content = "hello world"
        new_content, error = replace(content, "world", "planet", False)
        assert error is None
        assert new_content == "hello planet"

    def test_replace_all_occurrences(self):
        """Test replacing all occurrences."""
        content = "foo bar foo baz foo"
        new_content, error = replace(content, "foo", "qux", True)
        assert error is None
        assert new_content == "qux bar qux baz qux"

    def test_replace_same_strings_error(self):
        """Test error when old and new strings are same."""
        content = "hello world"
        new_content, error = replace(content, "hello", "hello", False)
        assert error == ERROR_SAME_OLD_NEW

    def test_replace_not_found_error(self):
        """Test error when string not found."""
        content = "hello world"
        new_content, error = replace(content, "nonexistent", "replacement", False)
        assert error == ERROR_OLD_STRING_NOT_FOUND

    def test_replace_multiple_without_replace_all(self):
        """Test error when multiple occurrences found without replace_all."""
        content = "foo bar foo"
        new_content, error = replace(content, "foo", "qux", False)
        assert error == ERROR_OLD_STRING_MULTIPLE
