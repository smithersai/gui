"""Read-file helper with line truncation and read tracking."""

from __future__ import annotations

from .edit import resolve_and_validate_path
from .filesystem import mark_file_read

MAX_LINE_LENGTH = 2000
DEFAULT_READ_LIMIT = 2000


def truncate_long_lines(
    content: str,
    max_line_length: int = MAX_LINE_LENGTH,
) -> tuple[str, bool, int]:
    """Truncate individual long lines while preserving line boundaries."""
    lines = content.splitlines(keepends=True)
    truncated_lines = []
    was_truncated = False
    original_length = len(content)

    for line in lines:
        line_without_newline = line.rstrip("\r\n")
        if len(line_without_newline) > max_line_length:
            truncated_lines.append(line_without_newline[:max_line_length] + "...\n")
            was_truncated = True
        else:
            truncated_lines.append(line)

    return "".join(truncated_lines), was_truncated, original_length


async def read_file_safe(
    file_path: str,
    offset: int = 0,
    limit: int = DEFAULT_READ_LIMIT,
    working_dir: str | None = None,
) -> str:
    """Read a text file inside working_dir with line truncation and tracking."""
    abs_file_path, path_error = resolve_and_validate_path(file_path, working_dir)
    if path_error:
        return f"Error: {path_error}"

    try:
        with open(abs_file_path, "r", encoding="utf-8") as f:
            all_lines = f.readlines()

        lines_to_read = all_lines[offset : offset + limit] if limit > 0 else all_lines[offset:]
        content = "".join(lines_to_read)
        truncated_content, was_truncated, original_length = truncate_long_lines(content)

        if was_truncated:
            truncated_content += (
                "\n\n[Note: Some lines were truncated. "
                f"Original content length: {original_length} chars, "
                f"Max line length: {MAX_LINE_LENGTH} chars]"
            )

        mark_file_read(abs_file_path)
        return truncated_content

    except FileNotFoundError:
        return f"Error: File not found: {abs_file_path}"
    except PermissionError:
        return f"Error: Permission denied: {abs_file_path}"
    except UnicodeDecodeError:
        return f"Error: File is not a text file or uses unsupported encoding: {abs_file_path}"
    except Exception as e:
        return f"Error reading file: {str(e)}"
