"""
Tests for the patch tool.

Tests all patch operations: add, update, delete, and move.
"""

import os
from pathlib import Path

import pytest

from agent.tools.patch import (
    patch,
    parse_patch,
    AddHunk,
    DeleteHunk,
    UpdateHunk,
    UpdateFileChunk,
    seek_sequence,
    _compute_replacements,
    _apply_replacements,
    Replacement,
)


@pytest.mark.asyncio
async def test_simple_add_file(temp_dir: Path):
    """Test adding a new file."""
    patch_text = """*** Begin Patch
*** Add File: new_file.txt
+Hello World
+This is a new file
+Line 3
*** End Patch"""

    result = await patch(patch_text, working_dir=str(temp_dir))

    assert "1 files changed" in result
    new_file = temp_dir / "new_file.txt"
    assert new_file.exists()
    content = new_file.read_text()
    assert content == "Hello World\nThis is a new file\nLine 3"


@pytest.mark.asyncio
async def test_simple_update_file(temp_dir: Path):
    """Test basic file update without context."""
    # Create initial file
    test_file = temp_dir / "test.txt"
    test_file.write_text("old line\n")

    patch_text = """*** Begin Patch
*** Update File: test.txt
-old line
+new line
*** End Patch"""

    result = await patch(patch_text, working_dir=str(temp_dir))

    assert "1 files changed" in result
    content = test_file.read_text()
    assert content == "new line\n"


@pytest.mark.asyncio
async def test_context_aware_update(temp_dir: Path):
    """Test update with @@ context marker."""
    # Create initial file
    test_file = temp_dir / "test.py"
    test_file.write_text("""def main():
    print("old")
    return 0
""")

    patch_text = """*** Begin Patch
*** Update File: test.py
@@ def main():
 def main():
-    print("old")
+    print("new")
     return 0
*** End Patch"""

    result = await patch(patch_text, working_dir=str(temp_dir))

    assert "1 files changed" in result
    content = test_file.read_text()
    assert 'print("new")' in content
    assert 'print("old")' not in content


@pytest.mark.asyncio
async def test_delete_file(temp_dir: Path):
    """Test deleting a file."""
    # Create file to delete
    test_file = temp_dir / "to_delete.txt"
    test_file.write_text("This will be deleted\n")

    patch_text = """*** Begin Patch
*** Delete File: to_delete.txt
*** End Patch"""

    result = await patch(patch_text, working_dir=str(temp_dir))

    assert "1 files changed" in result
    assert not test_file.exists()


@pytest.mark.asyncio
async def test_file_move(temp_dir: Path):
    """Test moving/renaming file with content update."""
    # Create initial file
    old_file = temp_dir / "old_name.py"
    old_file.write_text("""class MyClass:
    pass
""")

    patch_text = """*** Begin Patch
*** Update File: old_name.py
*** Move to: new_name.py
@@ class MyClass:
 class MyClass:
-    pass
+    def method(self):
+        pass
*** End Patch"""

    result = await patch(patch_text, working_dir=str(temp_dir))

    assert "1 files changed" in result
    assert not old_file.exists()
    new_file = temp_dir / "new_name.py"
    assert new_file.exists()
    content = new_file.read_text()
    assert "def method(self):" in content


@pytest.mark.asyncio
async def test_multi_file_operations(temp_dir: Path):
    """Test multiple operations in one patch."""
    # Create existing file
    existing = temp_dir / "existing.txt"
    existing.write_text("old content\n")

    # Create file to delete
    to_delete = temp_dir / "obsolete.txt"
    to_delete.write_text("delete me\n")

    patch_text = """*** Begin Patch
*** Add File: new.txt
+Hello World

*** Update File: existing.txt
-old content
+new content

*** Delete File: obsolete.txt
*** End Patch"""

    result = await patch(patch_text, working_dir=str(temp_dir))

    assert "3 files changed" in result

    # Check new file
    new_file = temp_dir / "new.txt"
    assert new_file.exists()
    assert new_file.read_text() == "Hello World"

    # Check updated file
    assert existing.read_text() == "new content\n"

    # Check deleted file
    assert not to_delete.exists()


@pytest.mark.asyncio
async def test_multiple_chunks_in_update(temp_dir: Path):
    """Test update with multiple chunks."""
    test_file = temp_dir / "multi.py"
    test_file.write_text("""def func1():
    print("old1")

def func2():
    print("old2")
""")

    patch_text = """*** Begin Patch
*** Update File: multi.py
@@ def func1():
 def func1():
-    print("old1")
+    print("new1")

@@ def func2():
 def func2():
-    print("old2")
+    print("new2")
*** End Patch"""

    result = await patch(patch_text, working_dir=str(temp_dir))

    assert "1 files changed" in result
    content = test_file.read_text()
    assert 'print("new1")' in content
    assert 'print("new2")' in content
    assert 'print("old1")' not in content
    assert 'print("old2")' not in content


@pytest.mark.asyncio
async def test_error_file_not_found(temp_dir: Path):
    """Test error when trying to update non-existent file."""
    patch_text = """*** Begin Patch
*** Update File: nonexistent.txt
-old
+new
*** End Patch"""

    with pytest.raises(ValueError, match="File not found"):
        await patch(patch_text, working_dir=str(temp_dir))


@pytest.mark.asyncio
async def test_error_context_not_found(temp_dir: Path):
    """Test error when context line cannot be found."""
    test_file = temp_dir / "test.txt"
    test_file.write_text("some content\n")

    patch_text = """*** Begin Patch
*** Update File: test.txt
@@ nonexistent context
-line
+replacement
*** End Patch"""

    with pytest.raises(ValueError, match="Failed to find context"):
        await patch(patch_text, working_dir=str(temp_dir))


@pytest.mark.asyncio
async def test_error_invalid_patch_format(temp_dir: Path):
    """Test error with invalid patch format."""
    patch_text = "This is not a valid patch"

    with pytest.raises(ValueError, match="Invalid patch format"):
        await patch(patch_text, working_dir=str(temp_dir))


@pytest.mark.asyncio
async def test_error_no_changes(temp_dir: Path):
    """Test error when patch has no file changes."""
    patch_text = """*** Begin Patch
*** End Patch"""

    with pytest.raises(ValueError, match="No file changes found"):
        await patch(patch_text, working_dir=str(temp_dir))


@pytest.mark.asyncio
async def test_path_validation(temp_dir: Path):
    """Test that paths are validated to be within working directory."""
    patch_text = """*** Begin Patch
*** Add File: ../../escape.txt
+This should fail
*** End Patch"""

    with pytest.raises(ValueError, match="not in the current working directory"):
        await patch(patch_text, working_dir=str(temp_dir))


@pytest.mark.asyncio
async def test_add_file_with_subdirectory(temp_dir: Path):
    """Test adding file in subdirectory (creates parent dirs)."""
    patch_text = """*** Begin Patch
*** Add File: subdir/nested/file.txt
+Nested file content
*** End Patch"""

    result = await patch(patch_text, working_dir=str(temp_dir))

    assert "1 files changed" in result
    new_file = temp_dir / "subdir" / "nested" / "file.txt"
    assert new_file.exists()
    assert new_file.read_text() == "Nested file content"


def test_parse_patch_add():
    """Test parsing Add File operation."""
    patch_text = """*** Begin Patch
*** Add File: test.txt
+line 1
+line 2
*** End Patch"""

    hunks = parse_patch(patch_text)

    assert len(hunks) == 1
    assert isinstance(hunks[0], AddHunk)
    assert hunks[0].path == "test.txt"
    assert hunks[0].contents == "line 1\nline 2"


def test_parse_patch_delete():
    """Test parsing Delete File operation."""
    patch_text = """*** Begin Patch
*** Delete File: test.txt
*** End Patch"""

    hunks = parse_patch(patch_text)

    assert len(hunks) == 1
    assert isinstance(hunks[0], DeleteHunk)
    assert hunks[0].path == "test.txt"


def test_parse_patch_update():
    """Test parsing Update File operation."""
    patch_text = """*** Begin Patch
*** Update File: test.txt
@@ context
-old
+new
*** End Patch"""

    hunks = parse_patch(patch_text)

    assert len(hunks) == 1
    assert isinstance(hunks[0], UpdateHunk)
    assert hunks[0].path == "test.txt"
    assert len(hunks[0].chunks) == 1
    chunk = hunks[0].chunks[0]
    assert chunk.change_context == "context"
    assert chunk.old_lines == ["old"]
    assert chunk.new_lines == ["new"]


def test_parse_patch_update_with_move():
    """Test parsing Update File with Move directive."""
    patch_text = """*** Begin Patch
*** Update File: old.txt
*** Move to: new.txt
-old
+new
*** End Patch"""

    hunks = parse_patch(patch_text)

    assert len(hunks) == 1
    assert isinstance(hunks[0], UpdateHunk)
    assert hunks[0].path == "old.txt"
    assert hunks[0].move_path == "new.txt"


def test_parse_patch_multiple_operations():
    """Test parsing patch with multiple operations."""
    patch_text = """*** Begin Patch
*** Add File: new.txt
+content

*** Update File: existing.txt
-old
+new

*** Delete File: obsolete.txt
*** End Patch"""

    hunks = parse_patch(patch_text)

    assert len(hunks) == 3
    assert isinstance(hunks[0], AddHunk)
    assert isinstance(hunks[1], UpdateHunk)
    assert isinstance(hunks[2], DeleteHunk)


def test_seek_sequence_exact_match():
    """Test seek_sequence with exact match."""
    lines = ["line 1", "line 2", "line 3", "line 4"]
    pattern = ["line 2", "line 3"]

    index = seek_sequence(lines, pattern, 0)

    assert index == 1


def test_seek_sequence_trimmed_match():
    """Test seek_sequence with whitespace-insensitive match."""
    lines = ["  line 1  ", "line 2", "  line 3"]
    pattern = ["line 1", "line 2"]

    index = seek_sequence(lines, pattern, 0)

    assert index == 0  # Should match with trimmed comparison


def test_seek_sequence_not_found():
    """Test seek_sequence when pattern not found."""
    lines = ["line 1", "line 2", "line 3"]
    pattern = ["nonexistent", "pattern"]

    index = seek_sequence(lines, pattern, 0)

    assert index == -1


def test_seek_sequence_with_start_index():
    """Test seek_sequence starting from specific index."""
    lines = ["line 1", "line 2", "line 3", "line 2", "line 3"]
    pattern = ["line 2", "line 3"]

    # Should find first occurrence after start index
    index = seek_sequence(lines, pattern, 2)

    assert index == 3


def test_compute_replacements():
    """Test computing replacements for chunks."""
    original_lines = ["def func():", "    print('old')", "    return 0"]
    chunks = [
        UpdateFileChunk(
            old_lines=["    print('old')"],
            new_lines=["    print('new')"],
            change_context="def func():"
        )
    ]

    replacements = _compute_replacements(original_lines, "test.py", chunks)

    assert len(replacements) == 1
    assert replacements[0].start_idx == 1
    assert replacements[0].old_len == 1
    assert replacements[0].new_segment == ["    print('new')"]


def test_apply_replacements():
    """Test applying replacements to lines."""
    lines = ["line 1", "line 2", "line 3", "line 4"]
    replacements = [
        Replacement(start_idx=1, old_len=2, new_segment=["new line 2", "new line 3"])
    ]

    result = _apply_replacements(lines, replacements)

    assert result == ["line 1", "new line 2", "new line 3", "line 4"]


def test_apply_multiple_replacements():
    """Test applying multiple replacements in reverse order."""
    lines = ["line 1", "line 2", "line 3", "line 4"]
    replacements = [
        Replacement(start_idx=0, old_len=1, new_segment=["new line 1"]),
        Replacement(start_idx=2, old_len=1, new_segment=["new line 3"])
    ]

    result = _apply_replacements(lines, replacements)

    assert result == ["new line 1", "line 2", "new line 3", "line 4"]


@pytest.mark.asyncio
async def test_unchanged_lines_in_chunk(temp_dir: Path):
    """Test update chunk with unchanged context lines."""
    test_file = temp_dir / "test.py"
    test_file.write_text("""def func():
    line1 = 1
    line2 = 2
    line3 = 3
""")

    patch_text = """*** Begin Patch
*** Update File: test.py
@@ def func():
 def func():
     line1 = 1
-    line2 = 2
+    line2 = 20
     line3 = 3
*** End Patch"""

    result = await patch(patch_text, working_dir=str(temp_dir))

    assert "1 files changed" in result
    content = test_file.read_text()
    assert "line2 = 20" in content
    assert "    line2 = 2\n" not in content  # Check full line to avoid substring match
    assert "line1 = 1" in content  # Unchanged
    assert "line3 = 3" in content  # Unchanged


@pytest.mark.asyncio
async def test_pure_addition_no_old_lines(temp_dir: Path):
    """Test adding lines without removing any (pure insertion)."""
    test_file = temp_dir / "test.py"
    test_file.write_text("""def func():
    pass
""")

    patch_text = """*** Begin Patch
*** Update File: test.py
@@ def func():
+    # New comment
+    new_line = 1
*** End Patch"""

    result = await patch(patch_text, working_dir=str(temp_dir))

    assert "1 files changed" in result
    content = test_file.read_text()
    assert "# New comment" in content
    assert "new_line = 1" in content


@pytest.mark.asyncio
async def test_complex_real_world_scenario(temp_dir: Path):
    """Test a complex real-world scenario with multiple files and operations."""
    # Create initial files
    config_file = temp_dir / "config.py"
    config_file.write_text("""DEBUG = False
VERSION = "1.0.0"
""")

    utils_file = temp_dir / "utils.py"
    utils_file.write_text("""def helper():
    return "old"
""")

    old_module = temp_dir / "old_module.py"
    old_module.write_text("""class OldClass:
    pass
""")

    patch_text = """*** Begin Patch
*** Add File: new_feature.py
+class NewFeature:
+    def __init__(self):
+        self.enabled = True

*** Update File: config.py
@@ VERSION = "1.0.0"
 VERSION = "1.0.0"
+FEATURE_ENABLED = True

*** Update File: utils.py
@@ def helper():
 def helper():
-    return "old"
+    return "new"

*** Update File: old_module.py
*** Move to: new_module.py
@@ class OldClass:
 class OldClass:
-    pass
+    def new_method(self):
+        return True
*** End Patch"""

    result = await patch(patch_text, working_dir=str(temp_dir))

    assert "4 files changed" in result

    # Verify new file
    new_feature = temp_dir / "new_feature.py"
    assert new_feature.exists()
    assert "class NewFeature" in new_feature.read_text()

    # Verify updated config
    assert "FEATURE_ENABLED = True" in config_file.read_text()

    # Verify updated utils
    assert 'return "new"' in utils_file.read_text()

    # Verify moved module
    assert not old_module.exists()
    new_module = temp_dir / "new_module.py"
    assert new_module.exists()
    assert "def new_method(self)" in new_module.read_text()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
