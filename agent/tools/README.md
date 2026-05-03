# File Safety Tools - Read-Before-Write Enforcement

This module implements read-before-write enforcement to prevent blind file overwrites and race conditions.

## Architecture

### Core Components

1. **FileTimeTracker** (`file_time.py`)
   - Tracks file modification times when files are read
   - Validates files haven't been modified before writes
   - Normalizes paths and resolves symlinks for accurate tracking

2. **Session-Scoped Tracking** (`core/state.py`)
   - Each session has its own FileTimeTracker instance
   - Prevents cross-session interference
   - Automatically cleaned up when sessions end

3. **Helper Functions** (`filesystem.py`)
   - `set_current_session_id()` - Sets the active session for tracking
   - `mark_file_read()` - Records a file as read
   - `check_file_writable()` - Enforces read-before-write rules

4. **Integration Points** (`wrapper.py`, `read_file_safe.py`)
   - Sets session context before agent execution
   - Rejects unsafe MCP write-like tool calls before execution
   - Records successful MCP read and write results
   - Provides a safe direct read helper with path containment and truncation

## How It Works

### Reading Files

When a file is read:
1. The file's current modification time is recorded
2. The file path is normalized (absolute + symlink resolution)
3. The timestamp is stored in the session's tracker

### Writing Files

When a file is written:
1. If the file exists, check if it's been read in this session
2. If not read, raise error: "File has not been read in this session"
3. If read, verify the modification time hasn't changed
4. If changed, raise error: "File has been modified since it was last read"
5. If checks pass, allow write and update timestamp

### New Files

New files (non-existent paths) can be written without requiring a read.

## Implementation Status

- FileTimeTracker class with full path normalization
- Session-scoped tracking infrastructure
- Helper functions for marking reads, writes, and checking write safety
- Context variable for session tracking
- Session ID propagation in wrapper
- MCP file-tool enforcement in wrapper for read, write, edit, and move operations
- Safe direct read helper with working-directory containment and line truncation

## Usage Examples

### Direct Usage

```python
from agent.tools.file_time import FileTimeTracker
from agent.tools.filesystem import set_current_session_id, mark_file_read, check_file_writable

# Set up session
set_current_session_id("session-123")

# Read a file
with open("/path/to/file.txt") as f:
    content = f.read()
mark_file_read("/path/to/file.txt")

# Write the file (this will succeed)
check_file_writable("/path/to/file.txt")  # No error
with open("/path/to/file.txt", "w") as f:
    f.write("new content")

# Try to write without reading first
check_file_writable("/path/to/other.txt")  # Raises ValueError!
```

### With Agent Wrapper

```python
async with create_mcp_wrapper(model_id="claude-sonnet-4") as wrapper:
    # Session ID is automatically set
    async for event in wrapper.stream_async("Read and modify config.py", session_id="session-123"):
        print(event)
```

## Testing

Run the test suite:

```bash
poetry run python -m pytest \
  legacy-agent-tests/test_agent/test_tools/test_file_safety.py \
  legacy-agent-tests/test_agent/test_wrapper_file_safety.py \
  legacy-agent-tests/test_agent/test_truncation.py \
  -q
```

Test coverage:
- Path normalization (relative, absolute)
- Symlink resolution
- Session isolation
- External modification detection
- New file creation
- Wrapper-level MCP read/write tracking
- Direct safe read path containment and truncation
- Edge cases (permissions, rapid cycles, etc.)

## Error Messages

The system provides clear, actionable error messages:

### File Not Read
```
ValueError: File /path/to/file.txt has not been read in this session.
You MUST use the Read tool first before writing to existing files
```

### File Modified Externally
```
ValueError: File /path/to/file.txt has been modified since it was last read.
Please use the Read tool again to get the latest contents
```

## Design Decisions

### Why Session-Scoped?

Session-scoped tracking prevents issues when multiple conversations/sessions operate on the same files simultaneously. Each session has its own timeline of file operations.

### Why Modification Time?

Using modification time (mtime) is the standard approach for detecting external changes. It's:
- Fast (no content hashing required)
- Reliable on most filesystems
- Standard in tools like Make, Git, etc.

### Why Allow New Files?

Requiring reads for new files would be overly restrictive. The agent needs to create new files freely. The safety concern is only about overwriting existing content without reading it first.

### Why Context Variables?

ContextVars are async-safe and automatically propagate through async call chains. This makes them ideal for tracking session state across tool calls.

## Related Files

- `agent/tools/file_time.py` - FileTimeTracker implementation
- `agent/tools/filesystem.py` - Helper functions and safe file operations
- `agent/tools/read_file_safe.py` - Safe direct read helper and line truncation
- `core/state.py` - Session state management
- `agent/wrapper.py` - Session context propagation
- `legacy-agent-tests/test_agent/test_tools/test_file_safety.py` - Tracker test suite
- `legacy-agent-tests/test_agent/test_wrapper_file_safety.py` - Wrapper enforcement tests
