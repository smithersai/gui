"""
MultiEdit tool for performing multiple string replacements in a single file atomically.

This tool allows performing multiple find-replace operations on a single file
in one atomic operation. Each edit is applied in sequence, with each subsequent
edit operating on the result of the previous edit.

Based on the Go reference implementation from agent-bak-bak/tool/multiedit.go.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any

from .edit import (
    DEFAULT_FILE_MODE,
    ERROR_FILE_NOT_FOUND,
    ERROR_PATH_IS_DIRECTORY,
    create_diff,
    replace,
    resolve_and_validate_path,
)

# Error messages (matching Go implementation)
ERROR_FILE_PATH_REQUIRED = "file_path parameter is required"
ERROR_EDITS_REQUIRED = "edits parameter is required and must be an array"
ERROR_EDITS_EMPTY = "edits array cannot be empty"
ERROR_EDIT_INVALID = "edit at index {} is not a valid object"
ERROR_EDIT_MISSING_OLD = "edit at index {} is missing old_string"
ERROR_EDIT_MISSING_NEW = "edit at index {} is missing new_string"
ERROR_EDIT_SAME_OLD_NEW = "edit at index {} has identical old_string and new_string"
ERROR_EDIT_FAILED = "edit {} failed: {}"


@dataclass
class EditOperation:
    """Single edit operation."""

    old_string: str
    new_string: str
    replace_all: bool = False


@dataclass
class MultiEditResult:
    """Result from a multi-edit operation."""

    success: bool
    file_path: str
    edit_count: int = 0
    error: str = ""
    metadata: dict[str, Any] = field(default_factory=dict)


def validate_edits(edits: list[Any]) -> tuple[list[EditOperation], str | None]:
    """
    Validate and parse the edits array.

    Args:
        edits: Raw edits array from user input

    Returns:
        Tuple of (parsed_operations, error_message or None)
    """
    if not edits:
        return [], ERROR_EDITS_EMPTY

    operations: list[EditOperation] = []

    for i, edit_item in enumerate(edits):
        # Check if edit is a valid dict/object
        if not isinstance(edit_item, dict):
            return [], ERROR_EDIT_INVALID.format(i)

        # Validate old_string
        old_string = edit_item.get("old_string")
        if old_string is None:
            return [], ERROR_EDIT_MISSING_OLD.format(i)
        if not isinstance(old_string, str):
            return [], ERROR_EDIT_MISSING_OLD.format(i)

        # Validate new_string
        new_string = edit_item.get("new_string")
        if new_string is None:
            return [], ERROR_EDIT_MISSING_NEW.format(i)
        if not isinstance(new_string, str):
            return [], ERROR_EDIT_MISSING_NEW.format(i)

        # Check old_string != new_string
        if old_string == new_string:
            return [], ERROR_EDIT_SAME_OLD_NEW.format(i)

        # Parse replace_all (optional, defaults to False)
        replace_all = bool(edit_item.get("replace_all", False))

        operations.append(
            EditOperation(
                old_string=old_string,
                new_string=new_string,
                replace_all=replace_all,
            )
        )

    return operations, None


async def multiedit(
    file_path: str,
    edits: list[dict[str, Any]],
    working_dir: str | None = None,
) -> dict[str, Any]:
    """
    Perform multiple edits to a single file atomically.

    All edits are validated before any are applied. Each edit operates on
    the result of the previous edit, allowing dependent changes.

    Args:
        file_path: Absolute path to file to modify
        edits: Array of edit operations, each with:
            - old_string: Text to replace (empty creates file on first edit)
            - new_string: Replacement text
            - replace_all: (optional) Replace all occurrences
        working_dir: Working directory for path validation

    Returns:
        dict with:
            - success: bool
            - file_path: str
            - edit_count: int
            - error: str (if success=False)
            - metadata: dict with results from all edits
    """
    # Validate file_path
    if not file_path or not isinstance(file_path, str):
        return {
            "success": False,
            "file_path": "",
            "edit_count": 0,
            "error": ERROR_FILE_PATH_REQUIRED,
        }

    # Validate and resolve path
    abs_file_path, path_error = resolve_and_validate_path(file_path, working_dir)
    if path_error:
        return {
            "success": False,
            "file_path": file_path,
            "edit_count": 0,
            "error": path_error,
        }

    # Validate edits parameter type
    if not isinstance(edits, list):
        return {
            "success": False,
            "file_path": file_path,
            "edit_count": 0,
            "error": ERROR_EDITS_REQUIRED,
        }

    # Validate and parse all edits before applying any
    operations, validation_error = validate_edits(edits)
    if validation_error:
        return {
            "success": False,
            "file_path": file_path,
            "edit_count": 0,
            "error": validation_error,
        }

    # Get relative path for output
    cwd = working_dir or os.getcwd()
    try:
        rel_path = os.path.relpath(abs_file_path, cwd)
    except ValueError:
        rel_path = abs_file_path

    original_exists = os.path.exists(abs_file_path)
    if original_exists and os.path.isdir(abs_file_path):
        return {
            "success": False,
            "file_path": file_path,
            "edit_count": 0,
            "error": ERROR_PATH_IS_DIRECTORY.format(abs_file_path),
        }

    if not original_exists and operations[0].old_string != "":
        return {
            "success": False,
            "file_path": file_path,
            "edit_count": 0,
            "error": ERROR_FILE_NOT_FOUND.format(abs_file_path),
        }

    if original_exists:
        try:
            with open(abs_file_path, "r", encoding="utf-8") as f:
                content_original = f.read()
        except OSError as e:
            return {
                "success": False,
                "file_path": file_path,
                "edit_count": 0,
                "error": f"failed to read file: {e}",
            }

        try:
            file_mode = os.stat(abs_file_path).st_mode
        except OSError:
            file_mode = DEFAULT_FILE_MODE
    else:
        content_original = ""
        file_mode = DEFAULT_FILE_MODE

    # Simulate every edit before touching disk. Empty old_string mirrors the Edit
    # tool's file-creation behavior by replacing the whole in-memory content.
    content_current = content_original
    results: list[dict[str, Any]] = []
    for i, operation in enumerate(operations):
        content_before = content_current

        if operation.old_string == "":
            content_current = operation.new_string
            replace_error = None
        else:
            content_current, replace_error = replace(
                content_current,
                operation.old_string,
                operation.new_string,
                operation.replace_all,
            )

        if replace_error:
            return {
                "success": False,
                "file_path": rel_path,
                "edit_count": 0,
                "error": ERROR_EDIT_FAILED.format(i + 1, replace_error),
                "metadata": {
                    "results": results,
                    "failed_at": i,
                },
            }

        results.append({
            "index": i,
            "success": True,
            "diff": create_diff(rel_path, content_before, content_current),
            "metadata": {
                "filePath": abs_file_path,
                "created": not original_exists and i == 0,
            },
        })

    parent_dir = os.path.dirname(abs_file_path)
    if parent_dir and not os.path.exists(parent_dir):
        try:
            os.makedirs(parent_dir, exist_ok=True)
        except OSError as e:
            return {
                "success": False,
                "file_path": file_path,
                "edit_count": 0,
                "error": f"failed to create directory: {e}",
            }

    try:
        with open(abs_file_path, "w", encoding="utf-8") as f:
            f.write(content_current)
        if original_exists:
            os.chmod(abs_file_path, file_mode)
    except OSError as e:
        return {
            "success": False,
            "file_path": file_path,
            "edit_count": 0,
            "error": f"failed to write file: {e}",
        }

    # All edits successful
    final_diff = create_diff(rel_path, content_original, content_current)

    return {
        "success": True,
        "file_path": rel_path,
        "edit_count": len(operations),
        "output": final_diff,
        "metadata": {
            "results": [r.get("metadata", {}) for r in results],
        },
    }


# Tool description for agent registration
MULTIEDIT_DESCRIPTION = """Perform multiple find-and-replace operations on a single file atomically.

This tool allows making multiple edits to the same file in one operation. All edits
are validated before any are applied, ensuring atomic behavior.

Before using this tool:
1. Use the Read tool to understand the file's contents and context
2. Verify the file path is correct

Parameters:
- file_path: The absolute path to the file to modify
- edits: An array of edit operations, where each edit contains:
    - old_string: The text to replace (must match exactly, including whitespace)
    - new_string: The text to replace it with
    - replace_all: (optional) Replace all occurrences (default: false)

IMPORTANT:
- All edits are applied in sequence, in the order they are provided
- Each edit operates on the result of the previous edit
- All edits must be valid for the operation to succeed - if any edit fails, none are applied
- Plan your edits carefully to avoid conflicts between sequential operations

WARNING:
- The tool will fail if old_string doesn't match the file contents exactly (including whitespace)
- The tool will fail if old_string and new_string are the same
- Since edits are applied in sequence, ensure earlier edits don't affect the text that later edits need to find

For single edits, use a 1-element edits array.

FILE CREATION SUPPORT:
To create a new file, use:
- First edit: empty old_string and the new file's contents as new_string
- Subsequent edits: normal edit operations on the created content
"""
