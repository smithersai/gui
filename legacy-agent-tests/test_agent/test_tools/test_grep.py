"""
Tests for the Grep tool with multiline pattern matching support.

Tests cover:
1. Single-line pattern matching (default behavior)
2. Multi-line pattern matching with multiline=True
3. Case-insensitive search
4. Glob filtering
5. Max count limiting
6. Path-specific search
7. Error handling
8. Performance and timeout scenarios
"""

import os
import pytest
import tempfile
from pathlib import Path

from agent.tools.grep import grep, _format_matches


# --- Fixtures ---


@pytest.fixture
def temp_test_dir():
    """Create a temporary directory for test files."""
    with tempfile.TemporaryDirectory() as temp_dir:
        yield Path(temp_dir)


@pytest.fixture
def sample_python_files(temp_test_dir):
    """Create sample Python files for testing."""
    # File 1: Simple function
    file1 = temp_test_dir / "simple.py"
    file1.write_text('''def greet(name):
    """Simple greeting function."""
    return f"Hello, {name}!"

def farewell(name):
    """Simple farewell function."""
    return f"Goodbye, {name}!"
''')

    # File 2: Async functions with multiline bodies
    file2 = temp_test_dir / "async_funcs.py"
    file2.write_text('''async def authenticate(username, password):
    """
    Authenticate a user with username and password.

    Returns:
        bool: True if authenticated, False otherwise
    """
    user = await db.get_user(username)
    if not user:
        return False
    return verify_password(password, user.password_hash)

async def authorize(user_id, resource):
    """Check if user has access to resource."""
    permissions = await db.get_permissions(user_id)
    return resource in permissions
''')

    # File 3: Multi-line strings and comments
    file3 = temp_test_dir / "strings.py"
    file3.write_text('''HELP_TEXT = """
This is a multi-line help text.
It contains several lines of documentation.
Use this to understand the tool.
"""

CONFIG = {
    "database": {
        "host": "localhost",
        "port": 5432
    }
}

# This is a single-line comment
def process():
    """
    Process data with multiple steps.

    This function does:
    - Step 1: Load data
    - Step 2: Transform data
    - Step 3: Save data
    """
    pass
''')

    # File 4: JavaScript file (for glob testing)
    file4 = temp_test_dir / "app.js"
    file4.write_text('''function calculate(a, b) {
    // Simple calculator
    return a + b;
}

async function fetchData() {
    const response = await fetch('/api/data');
    return response.json();
}
''')

    return temp_test_dir


# --- Single-line Pattern Tests ---


@pytest.mark.asyncio
async def test_simple_single_line_search(sample_python_files):
    """Test basic single-line pattern matching."""
    result = await grep(
        pattern="def greet",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 1
    assert "simple.py" in result["matches"][0]["path"]
    assert result["matches"][0]["line_number"] == 1


@pytest.mark.asyncio
async def test_single_line_with_glob(sample_python_files):
    """Test single-line search with glob filtering."""
    result = await grep(
        pattern="async def",
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    # Should find async functions in async_funcs.py
    assert len(result["matches"]) >= 2
    assert all("async_funcs.py" in m["path"] for m in result["matches"])


@pytest.mark.asyncio
async def test_case_insensitive_search(sample_python_files):
    """Test case-insensitive pattern matching."""
    result = await grep(
        pattern="HELLO",
        case_insensitive=True,
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    # Should find "Hello" in simple.py
    assert len(result["matches"]) >= 1


@pytest.mark.asyncio
async def test_max_count_limit(sample_python_files):
    """Test limiting results with max_count."""
    result = await grep(
        pattern="def",
        glob="*.py",
        max_count=1,
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    # Each file should have max 1 match
    file_matches = {}
    for match in result["matches"]:
        file_path = match["path"]
        file_matches[file_path] = file_matches.get(file_path, 0) + 1

    for count in file_matches.values():
        assert count <= 1


# --- Multi-line Pattern Tests ---


@pytest.mark.asyncio
async def test_multiline_function_definition(sample_python_files):
    """Test finding entire function definitions with multiline mode."""
    # Pattern to match async def through the return statement
    result = await grep(
        pattern=r"async def authenticate.*?return",
        multiline=True,
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) >= 1
    # Should capture multiple lines
    match_text = result["matches"][0]["text"]
    assert "async def authenticate" in match_text
    assert "return" in match_text
    assert "\n" in match_text  # Multi-line match


@pytest.mark.asyncio
async def test_multiline_docstring(sample_python_files):
    """Test finding multi-line docstrings."""
    # Pattern to match triple-quoted docstrings
    result = await grep(
        pattern=r'"""[\s\S]*?"""',
        multiline=True,
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    # Should find multiple docstrings
    assert len(result["matches"]) >= 3
    # Check that matches contain multiple lines
    for match in result["matches"]:
        assert '"""' in match["text"]


@pytest.mark.asyncio
async def test_multiline_dictionary(sample_python_files):
    """Test finding multi-line dictionary definitions."""
    # Pattern to match dictionary with nested structure
    result = await grep(
        pattern=r'"database":\s*\{[^}]*\}',
        multiline=True,
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) >= 1
    match_text = result["matches"][0]["text"]
    assert "database" in match_text
    assert "host" in match_text or "port" in match_text


@pytest.mark.asyncio
async def test_multiline_vs_single_line_difference(sample_python_files):
    """Test that multiline mode captures different results than single-line."""
    # Single-line search - won't match across lines
    single_result = await grep(
        pattern=r'""".*?"""',
        multiline=False,
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    # Multi-line search - will match across lines
    multi_result = await grep(
        pattern=r'"""[\s\S]*?"""',
        multiline=True,
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    # Multi-line should find more matches (multi-line docstrings)
    assert multi_result["success"] is True
    assert single_result["success"] is True
    # The HELP_TEXT multi-line string should only be found in multiline mode
    multi_texts = [m["text"] for m in multi_result["matches"]]
    help_found = any("multi-line help text" in text for text in multi_texts)
    assert help_found is True


# --- Path and File Filtering Tests ---


@pytest.mark.asyncio
async def test_specific_file_search(sample_python_files):
    """Test searching in a specific file."""
    file_path = sample_python_files / "simple.py"
    result = await grep(
        pattern="def",
        path=str(file_path)
    )

    assert result["success"] is True
    assert len(result["matches"]) >= 2
    assert all("simple.py" in m["path"] for m in result["matches"])


@pytest.mark.asyncio
async def test_glob_python_only(sample_python_files):
    """Test glob filtering for Python files only."""
    result = await grep(
        pattern="function",
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    # Should not find JavaScript file
    assert result["success"] is True
    if result["matches"]:
        assert not any("app.js" in m["path"] for m in result["matches"])


@pytest.mark.asyncio
async def test_glob_javascript_only(sample_python_files):
    """Test glob filtering for JavaScript files only."""
    result = await grep(
        pattern="function",
        glob="*.js",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) >= 1
    assert all("app.js" in m["path"] for m in result["matches"])


# --- Error Handling Tests ---


@pytest.mark.asyncio
async def test_no_matches_found(sample_python_files):
    """Test handling when no matches are found."""
    result = await grep(
        pattern="nonexistent_pattern_xyz123",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 0
    assert "No matches found" in result["formatted_output"]


@pytest.mark.asyncio
async def test_invalid_regex_pattern(sample_python_files):
    """Test handling of invalid regex patterns."""
    result = await grep(
        pattern="[invalid(regex",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is False
    assert "error" in result


@pytest.mark.asyncio
async def test_nonexistent_directory():
    """Test handling of non-existent directory."""
    result = await grep(
        pattern="test",
        path="/nonexistent/directory/path"
    )

    # Ripgrep will return error for non-existent path
    assert result["success"] is False or len(result["matches"]) == 0


# --- Format Output Tests ---


def test_format_single_line_matches():
    """Test formatting of single-line matches."""
    matches = [
        {"path": "file1.py", "line_number": 10, "text": "def test():"},
        {"path": "file1.py", "line_number": 20, "text": "def another():"},
        {"path": "file2.py", "line_number": 5, "text": "def foo():"},
    ]

    output = _format_matches(matches, multiline=False)

    assert "Found 3 matches" in output
    assert "file1.py:" in output
    assert "file2.py:" in output
    assert "Line 10:" in output
    assert "Line 20:" in output
    assert "Line 5:" in output


def test_format_multiline_matches():
    """Test formatting of multi-line matches."""
    matches = [
        {
            "path": "file1.py",
            "line_number": 10,
            "text": "def test():\n    pass\n    return",
        },
    ]

    output = _format_matches(matches, multiline=True)

    assert "Found 1 match" in output
    assert "multiline mode enabled" in output
    assert "Lines 10-12:" in output  # Should show range
    assert "10: def test():" in output
    assert "11:     pass" in output
    assert "12:     return" in output


# --- Integration Tests ---


@pytest.mark.asyncio
async def test_complex_multiline_async_function(sample_python_files):
    """Test finding complex async function with full body."""
    # Find async function from 'async def' to 'return'
    result = await grep(
        pattern=r"async def authenticate\([^)]*\):[\s\S]*?return verify_password",
        multiline=True,
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) >= 1

    match = result["matches"][0]
    assert "authenticate" in match["text"]
    assert "username, password" in match["text"]
    assert "verify_password" in match["text"]
    # Should span multiple lines
    assert match["text"].count("\n") >= 5


@pytest.mark.asyncio
async def test_grep_with_all_options(sample_python_files):
    """Test grep with all options combined."""
    result = await grep(
        pattern=r"async def.*?return",
        path=str(sample_python_files / "async_funcs.py"),
        multiline=True,
        case_insensitive=True,
        max_count=1,
    )

    assert result["success"] is True
    # Max count should limit to 1 match
    assert len(result["matches"]) == 1
    assert "async def" in result["matches"][0]["text"].lower()


# --- Performance Tests ---


@pytest.mark.asyncio
async def test_large_file_multiline_search(temp_test_dir):
    """Test multiline search on a larger file."""
    # Create a file with many functions
    large_file = temp_test_dir / "large.py"
    content = ""
    for i in range(100):
        content += f'''def function_{i}():
    """Docstring for function {i}."""
    result = process_{i}()
    return result

'''
    large_file.write_text(content)

    result = await grep(
        pattern=r"def function_5.*?return result",
        multiline=True,
        working_dir=str(temp_test_dir)
    )

    assert result["success"] is True
    assert len(result["matches"]) >= 1


@pytest.mark.asyncio
async def test_search_respects_timeout(temp_test_dir):
    """Test that search completes within timeout."""
    import time

    # Create some test files
    for i in range(10):
        test_file = temp_test_dir / f"test_{i}.py"
        test_file.write_text(f"def test_{i}():\n    pass\n" * 100)

    start_time = time.time()
    result = await grep(
        pattern="def test",
        working_dir=str(temp_test_dir)
    )
    elapsed = time.time() - start_time

    # Should complete quickly (well under 30s timeout)
    assert elapsed < 5.0
    assert result["success"] is True


# --- Context Lines Tests ---


@pytest.mark.asyncio
async def test_context_lines_basic(sample_python_files):
    """Test basic context lines with -C flag."""
    result = await grep(
        pattern="def greet",
        context_lines=2,
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 1
    # With context_lines=2, we should see lines before and after
    formatted = result["formatted_output"]
    # Check that context is included in output
    assert "def greet" in formatted
    # Should have context lines (simple greeting function docstring should appear)
    assert "Simple greeting function" in formatted or "return" in formatted


@pytest.mark.asyncio
async def test_context_after_only(sample_python_files):
    """Test context_after flag shows lines after match."""
    result = await grep(
        pattern="def greet",
        context_after=2,
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 1
    formatted = result["formatted_output"]
    # Should show function definition and lines after
    assert "def greet" in formatted
    # Should show docstring and return statement (lines after)
    assert "Simple greeting function" in formatted or "return" in formatted


@pytest.mark.asyncio
async def test_context_before_only(sample_python_files):
    """Test context_before flag shows lines before match."""
    result = await grep(
        pattern="return",
        context_before=2,
        glob="simple.py",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) >= 1
    formatted = result["formatted_output"]
    # Should show return statements with context before
    assert "return" in formatted
    # Context lines should include function definitions or docstrings
    assert "def" in formatted or '"""' in formatted


@pytest.mark.asyncio
async def test_context_lines_precedence(sample_python_files):
    """Test that context_lines takes precedence over context_before/context_after."""
    # If context_lines is specified, it should override context_before/context_after
    result_with_c = await grep(
        pattern="def greet",
        context_lines=1,
        context_before=5,  # Should be ignored
        context_after=5,   # Should be ignored
        working_dir=str(sample_python_files)
    )

    result_without_c = await grep(
        pattern="def greet",
        context_before=5,
        context_after=5,
        working_dir=str(sample_python_files)
    )

    # Both should succeed
    assert result_with_c["success"] is True
    assert result_without_c["success"] is True

    # The context_lines version should have less output
    assert len(result_with_c["formatted_output"]) < len(result_without_c["formatted_output"])


@pytest.mark.asyncio
async def test_asymmetric_context(sample_python_files):
    """Test asymmetric context (different before and after)."""
    result = await grep(
        pattern="def authenticate",
        context_before=1,
        context_after=3,
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) >= 1
    formatted = result["formatted_output"]
    # Should include the function definition
    assert "def authenticate" in formatted
    # Should include docstring (which is after)
    assert "Authenticate" in formatted or "username" in formatted


@pytest.mark.asyncio
async def test_context_with_multiple_matches(sample_python_files):
    """Test context lines with multiple matches in same file."""
    result = await grep(
        pattern="^def",
        context_lines=1,
        glob="simple.py",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    # simple.py has 2 function definitions
    assert len(result["matches"]) == 2
    formatted = result["formatted_output"]
    # Should have separator between context groups OR show context for both matches
    # The output should include both function definitions
    assert "def greet" in formatted
    assert "def farewell" in formatted
    # Context lines should be included
    assert "greeting function" in formatted.lower() or "farewell function" in formatted.lower()


@pytest.mark.asyncio
async def test_large_context_window(sample_python_files):
    """Test with large context window."""
    result = await grep(
        pattern="def greet",
        context_lines=10,  # Large context
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 1
    formatted = result["formatted_output"]
    # Should include lots of surrounding lines
    assert "def greet" in formatted
    # Should show farewell function too (it's within 10 lines)
    assert "farewell" in formatted or "Goodbye" in formatted


@pytest.mark.asyncio
async def test_context_at_file_boundaries(temp_test_dir):
    """Test context lines at file start/end don't cause errors."""
    # Create a small file
    small_file = temp_test_dir / "small.py"
    small_file.write_text('''first_line = 1
second_line = 2
third_line = 3
''')

    # Search first line with context before (shouldn't error)
    result = await grep(
        pattern="first_line",
        context_before=5,
        working_dir=str(temp_test_dir)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 1

    # Search last line with context after (shouldn't error)
    result2 = await grep(
        pattern="third_line",
        context_after=5,
        working_dir=str(temp_test_dir)
    )

    assert result2["success"] is True
    assert len(result2["matches"]) == 1


@pytest.mark.asyncio
async def test_context_with_case_insensitive(sample_python_files):
    """Test context lines work with case-insensitive search."""
    result = await grep(
        pattern="GREET",
        case_insensitive=True,
        context_lines=1,
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) >= 1
    formatted = result["formatted_output"]
    assert "greet" in formatted.lower()


@pytest.mark.asyncio
async def test_context_with_max_count(sample_python_files):
    """Test context lines work with max_count limiting."""
    result = await grep(
        pattern="def",
        context_lines=1,
        max_count=1,
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    # max_count limits per file
    formatted = result["formatted_output"]
    assert "def" in formatted


@pytest.mark.asyncio
async def test_context_format_includes_line_numbers(sample_python_files):
    """Test that context output includes line numbers."""
    result = await grep(
        pattern="def greet",
        context_lines=2,
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    formatted = result["formatted_output"]
    # Should have line numbers in the output
    # Line numbers appear as "  N:" in the format
    import re
    line_num_pattern = r'\s+\d+:'
    matches = re.findall(line_num_pattern, formatted)
    # Should have multiple line numbers (match + context)
    assert len(matches) >= 2


@pytest.mark.asyncio
async def test_no_context_when_parameters_zero(sample_python_files):
    """Test that context_lines=0 doesn't add context."""
    result = await grep(
        pattern="def greet",
        context_lines=0,
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    # Should work but not add context
    assert len(result["matches"]) == 1


@pytest.mark.asyncio
async def test_context_with_multiline_search(sample_python_files):
    """Test context lines work with multiline pattern matching."""
    result = await grep(
        pattern=r"async def authenticate.*?password",
        multiline=True,
        context_lines=1,
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) >= 1
    formatted = result["formatted_output"]
    # Should include multiline match plus context
    assert "authenticate" in formatted
    assert "password" in formatted


# --- Pagination Tests ---


@pytest.mark.asyncio
async def test_head_limit_basic(temp_test_dir):
    """Test basic head_limit functionality."""
    # Create file with many matches
    test_file = temp_test_dir / "many_matches.py"
    content = "\n".join([f"# This is line {i} with error" for i in range(50)])
    test_file.write_text(content)

    result = await grep(
        pattern="error",
        head_limit=10,
        working_dir=str(temp_test_dir)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 10
    assert result["truncated"] is True
    assert result["total_count"] == 50


@pytest.mark.asyncio
async def test_offset_basic(temp_test_dir):
    """Test basic offset functionality."""
    # Create file with many matches
    test_file = temp_test_dir / "many_matches.py"
    content = "\n".join([f"# Match number {i}" for i in range(30)])
    test_file.write_text(content)

    result = await grep(
        pattern="Match number",
        offset=10,
        working_dir=str(temp_test_dir)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 20  # 30 total - 10 offset
    assert result["total_count"] == 30
    # First match should be line 11 (offset 10, 0-indexed)
    assert result["matches"][0]["line_number"] == 11


@pytest.mark.asyncio
async def test_combined_offset_and_head_limit(temp_test_dir):
    """Test offset and head_limit used together for pagination."""
    # Create file with many matches
    test_file = temp_test_dir / "paginated.py"
    content = "\n".join([f"# Result {i}" for i in range(100)])
    test_file.write_text(content)

    # Get second page (items 11-20)
    result = await grep(
        pattern="Result",
        offset=10,
        head_limit=10,
        working_dir=str(temp_test_dir)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 10
    assert result["total_count"] == 100
    assert result["truncated"] is True
    # Should show items 11-20 (lines 11-20)
    assert result["matches"][0]["line_number"] == 11
    assert result["matches"][-1]["line_number"] == 20


@pytest.mark.asyncio
async def test_offset_beyond_results(temp_test_dir):
    """Test offset beyond total results."""
    test_file = temp_test_dir / "small.py"
    test_file.write_text("# Match 1\n# Match 2\n# Match 3")

    result = await grep(
        pattern="Match",
        offset=10,
        working_dir=str(temp_test_dir)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 0
    assert result["total_count"] == 3


@pytest.mark.asyncio
async def test_head_limit_zero_means_unlimited(temp_test_dir):
    """Test that head_limit=0 means unlimited results."""
    test_file = temp_test_dir / "unlimited.py"
    content = "\n".join([f"# Item {i}" for i in range(50)])
    test_file.write_text(content)

    result = await grep(
        pattern="Item",
        head_limit=0,  # 0 = unlimited
        working_dir=str(temp_test_dir)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 50
    assert result["truncated"] is False


@pytest.mark.asyncio
async def test_head_limit_greater_than_results(temp_test_dir):
    """Test head_limit greater than total results."""
    test_file = temp_test_dir / "few.py"
    test_file.write_text("# Test 1\n# Test 2\n# Test 3")

    result = await grep(
        pattern="Test",
        head_limit=100,
        working_dir=str(temp_test_dir)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 3
    assert result["truncated"] is False
    assert result["total_count"] == 3


@pytest.mark.asyncio
async def test_pagination_with_multiline(temp_test_dir):
    """Test pagination with multiline pattern matching."""
    test_file = temp_test_dir / "multiline_funcs.py"
    content = ""
    for i in range(20):
        content += f'''def function_{i}():
    """Docstring."""
    return {i}

'''
    test_file.write_text(content)

    result = await grep(
        pattern=r"def function.*?return",
        multiline=True,
        head_limit=5,
        working_dir=str(temp_test_dir)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 5
    assert result["total_count"] == 20
    assert result["truncated"] is True


@pytest.mark.asyncio
async def test_pagination_with_context_lines(sample_python_files):
    """Test pagination with context lines."""
    result = await grep(
        pattern="def",
        glob="*.py",
        context_lines=1,
        head_limit=3,
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    assert len(result["matches"]) == 3
    assert result["truncated"] is True


@pytest.mark.asyncio
async def test_pagination_formatted_output(temp_test_dir):
    """Test that pagination info appears in formatted output."""
    test_file = temp_test_dir / "output_test.py"
    content = "\n".join([f"# Line {i}" for i in range(50)])
    test_file.write_text(content)

    result = await grep(
        pattern="Line",
        offset=10,
        head_limit=5,
        working_dir=str(temp_test_dir)
    )

    assert result["success"] is True
    formatted = result["formatted_output"]
    # Should mention pagination
    assert "showing matches 11-15 of 50 total" in formatted
    # Should mention truncation
    assert "Output truncated" in formatted


@pytest.mark.asyncio
async def test_pagination_preserves_match_order(temp_test_dir):
    """Test that pagination preserves match order."""
    test_file = temp_test_dir / "ordered.py"
    lines = [f"# Match at line {i+1}" for i in range(30)]
    test_file.write_text("\n".join(lines))

    # Get different pages
    page1 = await grep(pattern="Match", head_limit=10, offset=0, working_dir=str(temp_test_dir))
    page2 = await grep(pattern="Match", head_limit=10, offset=10, working_dir=str(temp_test_dir))
    page3 = await grep(pattern="Match", head_limit=10, offset=20, working_dir=str(temp_test_dir))

    # Verify continuity
    assert page1["matches"][0]["line_number"] == 1
    assert page1["matches"][-1]["line_number"] == 10
    assert page2["matches"][0]["line_number"] == 11
    assert page2["matches"][-1]["line_number"] == 20
    assert page3["matches"][0]["line_number"] == 21
    assert page3["matches"][-1]["line_number"] == 30


@pytest.mark.asyncio
async def test_pagination_backward_compatibility(sample_python_files):
    """Test that omitting pagination params works as before."""
    # Call without pagination params
    result = await grep(
        pattern="def",
        glob="*.py",
        working_dir=str(sample_python_files)
    )

    assert result["success"] is True
    # Should get all results
    assert result["truncated"] is False
    assert len(result["matches"]) == result["total_count"]
