"""
Grep tool with multiline pattern matching and pagination support.

This module provides a custom grep/search tool using ripgrep that supports
multiline pattern matching and paginated results, allowing patterns to span 
across line boundaries and navigate large result sets efficiently.
"""

import json
import os
import subprocess
from typing import Any

from .edit import resolve_and_validate_path

# Constants
DEFAULT_TIMEOUT_SECONDS = 30
MAX_COUNT_DEFAULT = None
DEFAULT_HEAD_LIMIT = 0  # 0 means unlimited
DEFAULT_OFFSET = 0


async def grep(
    pattern: str,
    path: str | None = None,
    glob: str | None = None,
    multiline: bool = False,
    case_insensitive: bool = False,
    max_count: int | None = MAX_COUNT_DEFAULT,
    working_dir: str | None = None,
    context_before: int | None = None,
    context_after: int | None = None,
    context_lines: int | None = None,
    head_limit: int = DEFAULT_HEAD_LIMIT,
    offset: int = DEFAULT_OFFSET,
) -> dict[str, Any]:
    """Search for patterns in files using ripgrep.

    This tool provides powerful pattern matching with optional multiline support
    and pagination for large result sets.
    
    When multiline mode is enabled, patterns can match across line boundaries,
    making it useful for finding function definitions, multi-line comments,
    configuration blocks, and other multi-line code structures.

    Args:
        pattern: Regular expression pattern to search for
        path: Directory or file to search in (defaults to working directory)
        glob: File pattern to filter (e.g., "*.py", "*.{ts,tsx}")
        multiline: Enable multiline mode where . matches newlines and patterns can span lines
        case_insensitive: Case-insensitive search
        max_count: Maximum number of matches per file
        working_dir: Working directory for relative paths (defaults to cwd)
        context_before: Number of lines to show before each match (like -B flag)
        context_after: Number of lines to show after each match (like -A flag)
        context_lines: Number of lines to show before AND after each match (like -C flag, takes precedence over context_before/context_after)
        head_limit: Limit output to first N matches (0 = unlimited)
        offset: Skip first N matches before applying head_limit (0 = start from beginning)

    Examples:
        # Single-line search (default)
        await grep(pattern="def authenticate", glob="*.py")

        # Get first 10 results
        await grep(pattern="error", head_limit=10)

        # Get second page of results (items 11-20)
        await grep(pattern="error", offset=10, head_limit=10)

        # Search with context lines (2 lines before and after)
        await grep(pattern="def calculate", context_lines=2, glob="*.py")

        # Multi-line search for function with body
        await grep(
            pattern=r"def authenticate(.*?):.*?return",
            multiline=True,
            glob="*.py"
        )

        # Find multi-line docstrings with pagination
        # await grep(pattern="docstring pattern", multiline=True, glob="*.py", head_limit=5)
        await grep(pattern=r'\'\'\'.*?\'\'\'', multiline=True, glob="*.py", head_limit=5)

    Returns:
        Dictionary with:
            - success: bool - Whether the operation succeeded
            - matches: list - List of match dictionaries (if successful)
            - formatted_output: str - Human-readable formatted output
            - error: str - Error message (if failed)
            - truncated: bool - Whether results were truncated by pagination
            - total_count: int - Total matches before pagination

    Performance Note:
        Multiline searches are slower than single-line searches because:
        - Ripgrep must read entire file contents into memory
        - Pattern matching across line boundaries is more complex
        - Complex regex patterns may cause backtracking

        To improve performance:
        - Use glob parameter to narrow file search scope
        - Set max_count to limit results per file
        - Use head_limit for pagination instead of getting all results
        - Keep patterns as specific as possible
    """
    cwd = working_dir or os.getcwd()
    search_path = path
    if search_path is not None:
        search_path, path_error = resolve_and_validate_path(search_path, cwd)
        if path_error:
            return {
                "success": False,
                "error": path_error,
            }

    # Get ripgrep path
    rg_path = "rg"  # Assume ripgrep is in PATH

    # Build ripgrep arguments
    args = [
        rg_path,
        "--json",  # Output as JSON for easy parsing
        "--hidden",  # Include hidden files
        "--glob=!.git/*",  # Exclude .git directory
    ]

    # Add multiline flags if requested
    if multiline:
        args.extend(["-U", "--multiline-dotall"])

    # Add case-insensitive flag
    if case_insensitive:
        args.append("-i")

    # Add context line flags (-C takes precedence over -A/-B)
    if context_lines is not None and context_lines > 0:
        args.append(f"-C{context_lines}")
    else:
        if context_after is not None and context_after > 0:
            args.append(f"-A{context_after}")
        if context_before is not None and context_before > 0:
            args.append(f"-B{context_before}")

    # Add glob filter
    if glob:
        args.append(f"--glob={glob}")

    # Add max count per file
    if max_count is not None and max_count > 0:
        args.append(f"--max-count={max_count}")

    # Add pattern
    args.append(pattern)

    # Add path to search
    if search_path:
        args.append(search_path)
    elif working_dir:
        args.append(working_dir)

    try:
        # Run ripgrep with timeout
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=DEFAULT_TIMEOUT_SECONDS,
            cwd=cwd,
        )

        # Handle no matches (exit code 1)
        if result.returncode == 1:
            return {
                "success": True,
                "matches": [],
                "formatted_output": "No matches found",
                "truncated": False,
                "total_count": 0,
            }

        # Handle errors (exit code != 0 and != 1)
        if result.returncode != 0:
            error_msg = result.stderr.strip() or "Unknown error"
            return {
                "success": False,
                "error": error_msg,
            }

        # Parse JSON output from ripgrep
        lines = result.stdout.strip().split("\n")
        matches = []
        context_groups = []  # Groups of matches with their context lines
        current_group = []

        for line in lines:
            if not line:
                continue
            try:
                data = json.loads(line)
                msg_type = data.get("type")

                if msg_type == "begin":
                    # Start of a new file/group - save previous group if any
                    if current_group:
                        context_groups.append(current_group)
                    current_group = []

                elif msg_type == "match":
                    match_data = data["data"]
                    match_obj = {
                        "type": "match",
                        "path": match_data["path"]["text"],
                        "line_number": match_data["line_number"],
                        "text": match_data["lines"]["text"].rstrip("\n"),
                        "absolute_offset": match_data.get("absolute_offset"),
                        "submatches": match_data.get("submatches", []),
                    }
                    matches.append(match_obj)
                    current_group.append(match_obj)

                elif msg_type == "context":
                    # Context line (before or after match)
                    context_data = data["data"]
                    context_obj = {
                        "type": "context",
                        "path": context_data["path"]["text"],
                        "line_number": context_data["line_number"],
                        "text": context_data["lines"]["text"].rstrip("\n"),
                    }
                    current_group.append(context_obj)

                elif msg_type == "end":
                    # End of a file/group - finalize current group
                    if current_group:
                        context_groups.append(current_group)
                        current_group = []

            except json.JSONDecodeError:
                # Skip malformed JSON lines
                continue

        # Add final group if exists (in case there's no "end" marker)
        if current_group:
            context_groups.append(current_group)

        if not matches:
            return {
                "success": True,
                "matches": [],
                "formatted_output": "No matches found",
                "truncated": False,
                "total_count": 0,
            }

        # Apply pagination
        total_count = len(matches)
        paginated_matches = matches

        # Apply offset
        if offset > 0:
            paginated_matches = paginated_matches[offset:]

        # Apply head limit
        truncated = False
        if head_limit > 0 and len(paginated_matches) > head_limit:
            paginated_matches = paginated_matches[:head_limit]
            truncated = True

        # Format output for human readability
        has_context = any([context_lines, context_before, context_after])
        formatted_output = _format_matches(
            paginated_matches,
            multiline,
            context_groups if has_context else None,
            total_count=total_count,
            offset=offset,
            head_limit=head_limit,
            truncated=truncated,
        )

        return {
            "success": True,
            "matches": paginated_matches,
            "formatted_output": formatted_output,
            "truncated": truncated,
            "total_count": total_count,
        }

    except subprocess.TimeoutExpired:
        return {
            "success": False,
            "error": f"Search timed out ({DEFAULT_TIMEOUT_SECONDS}s limit)",
        }
    except FileNotFoundError:
        return {
            "success": False,
            "error": "ripgrep (rg) not found in PATH. Please install ripgrep.",
        }
    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {str(e)}",
        }


def _format_matches(
    matches: list[dict],
    multiline: bool,
    context_groups: list[list[dict]] | None = None,
    total_count: int | None = None,
    offset: int = 0,
    head_limit: int = 0,
    truncated: bool = False,
) -> str:
    """Format matches for human-readable output.

    Args:
        matches: List of match dictionaries
        multiline: Whether this was a multiline search
        context_groups: Optional context line groups
        total_count: Total number of matches before pagination
        offset: Offset used in pagination
        head_limit: Head limit used in pagination
        truncated: Whether results were truncated

    Returns:
        Formatted string output
    """
    output_lines = [f"Found {len(matches)} match{'es' if len(matches) != 1 else ''}"]

    # Add pagination info if applicable
    if total_count is not None and (offset > 0 or head_limit > 0):
        if truncated:
            output_lines.append(f"(showing matches {offset + 1}-{offset + len(matches)} of {total_count} total)")
        elif offset > 0:
            remaining = total_count - offset
            output_lines.append(f"(showing matches {offset + 1}-{offset + remaining} of {total_count} total)")

    if multiline:
        output_lines.append("(multiline mode enabled)")

    output_lines.append("")

    # If we have context groups, format with context
    if context_groups:
        return _format_with_context(matches, context_groups, multiline, output_lines)

    # Otherwise, format without context (original behavior)
    current_file = ""

    for match in matches:
        # Print file header if changed
        if current_file != match["path"]:
            if current_file:
                output_lines.append("")
            current_file = match["path"]
            output_lines.append(f"{match['path']}:")

        # Format the match
        line_num = match["line_number"]
        text = match["text"]

        # For multiline matches, show first and last line numbers if text spans multiple lines
        if multiline and "\n" in text:
            text_lines = text.split("\n")
            last_line_num = line_num + len(text_lines) - 1
            output_lines.append(f"  Lines {line_num}-{last_line_num}:")
            # Indent each line of the match
            for i, text_line in enumerate(text_lines):
                output_lines.append(f"    {line_num + i}: {text_line}")
        else:
            # Single line match
            output_lines.append(f"  Line {line_num}: {text}")

    # Add truncation message at the end
    if truncated and head_limit > 0:
        output_lines.append("")
        output_lines.append(f"(Output truncated to first {head_limit} matches. Use offset parameter to see more results.)")

    return "\n".join(output_lines)


def _format_with_context(
    matches: list[dict],
    context_groups: list[list[dict]],
    multiline: bool,
    header_lines: list[str],
) -> str:
    """Format matches with context lines.

    Args:
        matches: List of match dictionaries
        context_groups: List of context groups (matches + context lines)
        multiline: Whether this was a multiline search
        header_lines: Header lines to prepend

    Returns:
        Formatted string output with context
    """
    output_lines = header_lines.copy()
    current_file = ""
    first_group = True

    for group in context_groups:
        if not group:
            continue

        # Get file from first item in group
        file_path = group[0]["path"]

        # Print file header if changed
        if current_file != file_path:
            if current_file:
                output_lines.append("")
            current_file = file_path
            output_lines.append(f"{file_path}:")
        elif not first_group:
            # Add separator between groups in the same file
            output_lines.append("  --")

        # Format each line in the group
        for item in group:
            line_num = item["line_number"]
            text = item["text"]
            is_match = item.get("type") == "match"

            # For multiline matches, show first and last line numbers if text spans multiple lines
            if is_match and multiline and "\n" in text:
                text_lines = text.split("\n")
                last_line_num = line_num + len(text_lines) - 1
                output_lines.append(f"  Lines {line_num}-{last_line_num}:")
                # Indent each line of the match
                for i, text_line in enumerate(text_lines):
                    output_lines.append(f"    {line_num + i}: {text_line}")
            else:
                # Single line (either match or context)
                prefix = "  " if is_match else "  "
                output_lines.append(f"{prefix}{line_num}: {text}")

        first_group = False

    return "\n".join(output_lines)
