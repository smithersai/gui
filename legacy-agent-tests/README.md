# Test Suite

Comprehensive integration tests for the agent project. **NO MOCKS** - all tests use real functionality.

## Running Tests

Run all tests:
```bash
uv run pytest
```

Run with environment variable (if fixtures don't work):
```bash
DISABLE_PATH_VALIDATION=1 uv run pytest
```

Run specific test file:
```bash
uv run pytest tests/test_server.py
```

Run specific test:
```bash
uv run pytest tests/test_agent/test_tools/test_code_execution.py::TestExecutePython::test_simple_print
```

Run with coverage:
```bash
uv run pytest --cov=agent --cov=server --cov-report=html
```

## Test Structure

```
tests/
├── conftest.py              # Shared fixtures (temp dirs, env vars)
├── test_server.py           # FastAPI endpoint tests (130 tests total)
└── test_agent/
    ├── test_agent.py        # Agent creation and configuration
    ├── test_wrapper.py      # AgentWrapper streaming tests
    └── test_tools/
        ├── test_code_execution.py    # Python/shell execution
        ├── test_file_operations.py   # File read/write/search
        └── test_web.py              # HTTP fetch and search
```

## Test Categories

### Tool Tests
- **Code Execution** (`test_code_execution.py`): Tests actual Python and shell command execution
  - Python code execution with stdout/stderr
  - Shell commands with pipes and redirects
  - Timeout handling
  - Error cases

- **File Operations** (`test_file_operations.py`): Tests real file system operations
  - Reading and writing files
  - Directory listing
  - File searching with glob patterns
  - Path validation (disabled in tests via env var)

- **Web Tools** (`test_web.py`): Tests real HTTP requests
  - Fetching URLs with httpx
  - HTML text extraction
  - Error handling for 404s, timeouts
  - Concurrent requests

### Agent Tests
- **Agent Creation** (`test_agent.py`): Tests Pydantic AI agent instantiation
  - Different model configurations
  - Tool registration
  - Multiple agent instances

- **Wrapper Tests** (`test_wrapper.py`): Tests streaming wrapper
  - Message history management
  - StreamEvent data structures
  - Multiple wrapper instances

### Server Tests
- **HTTP Endpoints** (`test_server.py`): Tests FastAPI routes with TestClient
  - Session CRUD operations
  - Message management
  - Session actions (fork, revert, diff)
  - Request validation
  - Concurrent requests
  - ID generation

## Testing Philosophy

**Integration Tests Only - No Mocks**

This test suite uses real:
- File system operations (with temp directories)
- HTTP requests to real URLs
- Process execution for Python/shell commands
- FastAPI TestClient for real HTTP handlers
- Pydantic AI agents (without API calls)

## Environment Variables

Tests use these environment variables (set via `conftest.py` fixtures):
- `DISABLE_PATH_VALIDATION=1` - Allows file operations outside CWD for testing
- `ANTHROPIC_API_KEY=test-key-123` - Mock API key to avoid requiring real credentials

## Fixtures

Defined in `conftest.py`:
- `temp_dir`: Temporary directory that's cleaned up after test
- `temp_file`: Temporary file with sample content
- `mock_env_vars`: Sets up test environment variables
- `sample_python_code`: Sample Python code for execution tests
- `sample_shell_command`: Sample shell command for execution tests

## Test Coverage

Current test count: **130 tests**

Coverage by module:
- Code execution: 20 tests
- File operations: 26 tests
- Web tools: 15 tests
- Agent creation: 15 tests
- Wrapper: 17 tests
- Server endpoints: 37 tests

All tests pass with:
```
============================= 130 passed in 5.38s ==============================
```

## Adding New Tests

1. Create test file following naming convention: `test_*.py`
2. Use appropriate fixtures from `conftest.py`
3. Write integration tests that test real functionality
4. Run tests to verify they pass
5. Document any new fixtures or special setup

Example:
```python
import pytest
from agent.tools.code_execution import execute_python

class TestMyNewFeature:
    @pytest.mark.asyncio
    async def test_feature_works(self, temp_dir, mock_env_vars):
        """Test that my feature works correctly."""
        result = await execute_python("print('test')")
        assert "test" in result
```
