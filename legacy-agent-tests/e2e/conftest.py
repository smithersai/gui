"""
E2E test fixtures for real API testing with MCP tools.

Uses httpx.AsyncClient for proper async SSE streaming.
"""
import asyncio
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import AsyncGenerator, Generator

import httpx
import pytest
import pytest_asyncio
import uvicorn

from agent.wrapper import create_mcp_wrapper
from core.state import session_messages, sessions
from server import app, set_agent


# =============================================================================
# Constants
# =============================================================================

E2E_TIMEOUT_SECONDS = 180
TEST_SERVER_PORT = 18765


# =============================================================================
# Markers
# =============================================================================

def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line("markers", "slow: marks tests as slow")
    config.addinivalue_line("markers", "requires_api_key: requires real API key")


# =============================================================================
# API Key Check
# =============================================================================

@pytest.fixture(scope="session")
def api_key() -> str:
    """Get API key from environment, skip if not present."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        pytest.skip("ANTHROPIC_API_KEY not set")
    return key


# =============================================================================
# Temporary Directory with Fixture Files
# =============================================================================

@pytest.fixture
def e2e_temp_dir() -> Generator[Path, None, None]:
    """Create isolated temp directory for E2E tests with git init."""
    with tempfile.TemporaryDirectory(prefix="e2e_test_") as tmpdir:
        # Initialize as git repo for snapshot system
        subprocess.run(
            ["git", "init", "--quiet"],
            cwd=tmpdir,
            capture_output=True,
        )
        # Configure git user for commits
        subprocess.run(
            ["git", "config", "user.email", "test@test.com"],
            cwd=tmpdir,
            capture_output=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Test"],
            cwd=tmpdir,
            capture_output=True,
        )
        yield Path(tmpdir)


@pytest.fixture
def fixture_file(e2e_temp_dir: Path) -> Path:
    """Create a fixture file with known content."""
    file_path = e2e_temp_dir / "fixture.txt"
    file_path.write_text("5 + 5 = ??")
    return file_path


@pytest.fixture
def multi_file_fixture(e2e_temp_dir: Path) -> dict[str, Path]:
    """Create multiple fixture files for search tests."""
    files = {
        "file1.txt": "Hello World\nLine 2",
        "file2.txt": "Goodbye World\nLine 2",
        "subdir/file3.txt": "Nested Hello",
        "code.py": "def hello():\n    print('Hello')",
    }
    result = {}
    for name, content in files.items():
        path = e2e_temp_dir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        result[name] = path
    return result


# =============================================================================
# Server with MCP Agent - Async Fixtures
# =============================================================================

@pytest.fixture(autouse=True)
def clear_state():
    """Clear server state before each test."""
    sessions.clear()
    session_messages.clear()
    yield
    sessions.clear()
    session_messages.clear()


@pytest_asyncio.fixture
async def mcp_agent(api_key: str, e2e_temp_dir: Path):
    """Create MCP-enabled agent and configure server."""
    wrapper = None
    try:
        async with create_mcp_wrapper(
            working_dir=str(e2e_temp_dir),
        ) as wrapper:
            set_agent(wrapper)
            yield wrapper
    except RuntimeError as e:
        # MCP cleanup can fail with task context errors - this is expected
        # The tests still pass, this is just a teardown issue
        if "cancel scope" in str(e):
            pass
        else:
            raise
    finally:
        set_agent(None)


@pytest_asyncio.fixture
async def e2e_client(mcp_agent) -> AsyncGenerator[httpx.AsyncClient, None]:
    """Create async HTTP client for testing."""
    # Run server in background
    config = uvicorn.Config(app, host="127.0.0.1", port=TEST_SERVER_PORT, log_level="warning")
    server = uvicorn.Server(config)

    # Start server in background task
    server_task = asyncio.create_task(server.serve())

    # Wait for server to start
    await asyncio.sleep(0.5)

    async with httpx.AsyncClient(
        base_url=f"http://127.0.0.1:{TEST_SERVER_PORT}",
        timeout=httpx.Timeout(E2E_TIMEOUT_SECONDS),
    ) as client:
        yield client

    # Shutdown server
    server.should_exit = True
    await server_task


# =============================================================================
# SSE Stream Helpers
# =============================================================================

class SSECollector:
    """Collects and parses SSE events from streaming response."""

    def __init__(self):
        self.events: list[dict] = []
        self.final_text: str = ""
        self.tool_calls: list[dict] = []
        self.tool_results: list[dict] = []
        self.errors: list[str] = []

    async def parse_stream(self, response: httpx.Response) -> None:
        """Parse SSE stream from async response."""
        current_event = None
        async for line in response.aiter_lines():
            if line.startswith("event:"):
                current_event = line[6:].strip()
            elif line.startswith("data:"):
                data_str = line[5:].strip()
                try:
                    data = json.loads(data_str)
                    self.events.append({"event": current_event, "data": data})
                    self._process_event(current_event, data)
                except json.JSONDecodeError:
                    pass

    def _process_event(self, event_type: str, data: dict) -> None:
        """Process individual event."""
        if event_type == "error":
            self.errors.append(data.get("error", "Unknown error"))
        elif event_type == "part.updated":
            props = data.get("properties", {})
            if props.get("type") == "text":
                self.final_text = props.get("text", "")
            elif props.get("type") == "tool":
                state = props.get("state", {})
                tool_info = {
                    "tool": props.get("tool"),
                    "id": props.get("id"),
                }
                if state.get("status") == "running":
                    tool_info["input"] = state.get("input", {})
                    self.tool_calls.append(tool_info)
                elif state.get("status") == "completed":
                    tool_info["output"] = state.get("output")
                    self.tool_results.append(tool_info)


async def collect_sse_response(response: httpx.Response) -> SSECollector:
    """Helper to collect SSE events from async response."""
    collector = SSECollector()
    await collector.parse_stream(response)
    return collector


# =============================================================================
# Assertion Helpers
# =============================================================================

def assert_file_contains(file_path: Path, expected: str, msg: str = "") -> None:
    """Assert file contains expected content."""
    assert file_path.exists(), f"File does not exist: {file_path}"
    content = file_path.read_text()
    assert expected in content, (
        f"Expected '{expected}' in file. {msg}\nActual content: {content}"
    )


def assert_file_exact(file_path: Path, expected: str, msg: str = "") -> None:
    """Assert file has exact content."""
    assert file_path.exists(), f"File does not exist: {file_path}"
    content = file_path.read_text()
    assert content == expected, (
        f"File content mismatch. {msg}\nExpected: {expected}\nActual: {content}"
    )
