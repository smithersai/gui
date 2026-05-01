"""
Shared pytest fixtures for all tests.
"""
import os
import tempfile
from pathlib import Path
from typing import Iterator

import pytest


@pytest.fixture
def temp_dir() -> Iterator[Path]:
    """Create a temporary directory for testing."""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield Path(tmpdir)


@pytest.fixture
def temp_file(temp_dir: Path) -> Path:
    """Create a temporary file for testing."""
    file_path = temp_dir / "test_file.txt"
    file_path.write_text("Hello, World!\nThis is a test file.\nLine 3\n")
    return file_path


@pytest.fixture
def sample_python_code() -> str:
    """Sample Python code for testing execution."""
    return """
print("Hello from Python!")
result = 2 + 2
print(f"2 + 2 = {result}")
"""


@pytest.fixture
def sample_shell_command() -> str:
    """Sample shell command for testing."""
    return "echo 'Hello from shell'"


@pytest.fixture
def mock_env_vars(monkeypatch):
    """Set up mock environment variables for testing."""
    # Set a test API key to avoid requiring real credentials
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key-123")
    # Disable path validation to allow tests to use temp directories
    monkeypatch.setenv("DISABLE_PATH_VALIDATION", "1")
    return monkeypatch
