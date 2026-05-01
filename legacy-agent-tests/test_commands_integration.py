"""
Integration tests for custom slash commands system.

Tests the complete flow of loading, listing, and expanding custom commands.
"""

import pytest
from pathlib import Path
from tempfile import TemporaryDirectory

from config.commands import CommandRegistry, CustomCommand, CommandArg
from server.routes.commands import BUILTIN_COMMANDS


class TestCommandRegistry:
    """Test CommandRegistry functionality."""

    def test_registry_initialization(self):
        """Test that registry can be initialized with custom directory."""
        with TemporaryDirectory() as tmpdir:
            registry = CommandRegistry(prompts_dir=Path(tmpdir))
            assert registry.prompts_dir == Path(tmpdir)
            assert len(registry._commands) == 0

    def test_load_commands_creates_directory(self):
        """Test that load_commands creates directory if it doesn't exist."""
        with TemporaryDirectory() as tmpdir:
            prompts_dir = Path(tmpdir) / "prompts"
            assert not prompts_dir.exists()

            registry = CommandRegistry(prompts_dir=prompts_dir)
            registry.load_commands()

            assert prompts_dir.exists()
            assert len(registry._commands) == 0

    def test_load_simple_command(self):
        """Test loading a simple command without frontmatter."""
        with TemporaryDirectory() as tmpdir:
            prompts_dir = Path(tmpdir)
            cmd_file = prompts_dir / "hello.md"
            cmd_file.write_text("Say hello to the user!")

            registry = CommandRegistry(prompts_dir=prompts_dir)
            registry.load_commands()

            assert len(registry._commands) == 1
            cmd = registry.get_command("hello")
            assert cmd is not None
            assert cmd.name == "hello"
            assert cmd.template == "Say hello to the user!"
            assert cmd.description == ""
            assert len(cmd.args) == 0

    def test_load_command_with_frontmatter(self):
        """Test loading a command with YAML frontmatter."""
        with TemporaryDirectory() as tmpdir:
            prompts_dir = Path(tmpdir)
            cmd_file = prompts_dir / "review.md"
            cmd_file.write_text("""---
name: review-pr
description: Review a pull request
args:
  - name: pr_number
    required: true
    description: PR number to review
---

Review PR #{{pr_number}}.
""")

            registry = CommandRegistry(prompts_dir=prompts_dir)
            registry.load_commands()

            cmd = registry.get_command("review-pr")
            assert cmd is not None
            assert cmd.name == "review-pr"
            assert cmd.description == "Review a pull request"
            assert len(cmd.args) == 1
            assert cmd.args[0].name == "pr_number"
            assert cmd.args[0].required is True
            assert cmd.args[0].description == "PR number to review"
            assert "Review PR #{{pr_number}}." in cmd.template

    def test_lazy_loading(self):
        """Test that commands are loaded lazily on first access."""
        with TemporaryDirectory() as tmpdir:
            prompts_dir = Path(tmpdir)
            cmd_file = prompts_dir / "test.md"
            cmd_file.write_text("Test command")

            registry = CommandRegistry(prompts_dir=prompts_dir)
            assert not registry._loaded

            # First access triggers loading
            commands = registry.list_commands()
            assert registry._loaded
            assert len(commands) == 1

    def test_reload_commands(self):
        """Test that reload() reloads commands from disk."""
        with TemporaryDirectory() as tmpdir:
            prompts_dir = Path(tmpdir)
            cmd_file = prompts_dir / "test.md"
            cmd_file.write_text("First version")

            registry = CommandRegistry(prompts_dir=prompts_dir)
            registry.load_commands()
            assert len(registry._commands) == 1

            # Modify the file
            cmd_file.write_text("Second version")
            registry.reload()

            cmd = registry.get_command("test")
            assert cmd.template == "Second version"


class TestCommandExpansion:
    """Test command template expansion."""

    def test_expand_no_args(self):
        """Test expanding a command with no arguments."""
        with TemporaryDirectory() as tmpdir:
            prompts_dir = Path(tmpdir)
            cmd_file = prompts_dir / "help.md"
            cmd_file.write_text("Show help information.")

            registry = CommandRegistry(prompts_dir=prompts_dir)
            registry.load_commands()

            expanded = registry.expand_command("help")
            assert expanded == "Show help information."

    def test_expand_positional_args(self):
        """Test expanding with positional arguments ($1, $2)."""
        with TemporaryDirectory() as tmpdir:
            prompts_dir = Path(tmpdir)
            cmd_file = prompts_dir / "greet.md"
            cmd_file.write_text("Hello $1, welcome to $2!")

            registry = CommandRegistry(prompts_dir=prompts_dir)
            registry.load_commands()

            expanded = registry.expand_command("greet", args=["Alice", "Wonderland"])
            assert expanded == "Hello Alice, welcome to Wonderland!"

    def test_expand_named_args(self):
        """Test expanding with named arguments ({{name}})."""
        with TemporaryDirectory() as tmpdir:
            prompts_dir = Path(tmpdir)
            cmd_file = prompts_dir / "greet.md"
            cmd_file.write_text("Hello {{name}}, you are {{age}} years old!")

            registry = CommandRegistry(prompts_dir=prompts_dir)
            registry.load_commands()

            expanded = registry.expand_command(
                "greet", kwargs={"name": "Bob", "age": "30"}
            )
            assert expanded == "Hello Bob, you are 30 years old!"

    def test_expand_with_defaults(self):
        """Test expanding with default values."""
        with TemporaryDirectory() as tmpdir:
            prompts_dir = Path(tmpdir)
            cmd_file = prompts_dir / "test.md"
            cmd_file.write_text("""---
args:
  - name: file
    required: true
  - name: framework
    default: pytest
---

Test {{file}} using {{framework}}.
""")

            registry = CommandRegistry(prompts_dir=prompts_dir)
            registry.load_commands()

            # Use default
            expanded = registry.expand_command("test", args=["utils.py"])
            assert expanded == "Test utils.py using pytest."

            # Override default
            expanded = registry.expand_command("test", args=["utils.py", "unittest"])
            assert expanded == "Test utils.py using unittest."

    def test_expand_missing_required_arg(self):
        """Test that missing required argument raises ValueError."""
        with TemporaryDirectory() as tmpdir:
            prompts_dir = Path(tmpdir)
            cmd_file = prompts_dir / "review.md"
            cmd_file.write_text("""---
args:
  - name: pr_number
    required: true
---

Review PR #{{pr_number}}.
""")

            registry = CommandRegistry(prompts_dir=prompts_dir)
            registry.load_commands()

            with pytest.raises(ValueError, match="Required argument missing: pr_number"):
                registry.expand_command("review", args=[])

    def test_expand_nonexistent_command(self):
        """Test that expanding nonexistent command returns None."""
        with TemporaryDirectory() as tmpdir:
            registry = CommandRegistry(prompts_dir=Path(tmpdir))
            registry.load_commands()

            expanded = registry.expand_command("nonexistent")
            assert expanded is None


class TestCommandAPIEndpoints:
    """Test API endpoints for commands."""

    @pytest.fixture
    def test_registry(self):
        """Create a test registry with sample commands."""
        from config.commands import command_registry

        with TemporaryDirectory() as tmpdir:
            prompts_dir = Path(tmpdir)

            # Create test commands
            (prompts_dir / "simple.md").write_text("Simple command")
            (prompts_dir / "complex.md").write_text("""---
name: complex
description: Complex command with args
args:
  - name: arg1
    required: true
  - name: arg2
    default: default_value
---

Command with {{arg1}} and {{arg2}}.
""")

            # Override the global registry temporarily
            original_dir = command_registry.prompts_dir
            command_registry.prompts_dir = prompts_dir
            command_registry._loaded = False

            yield command_registry

            # Restore original directory
            command_registry.prompts_dir = original_dir
            command_registry._loaded = False

    def test_list_commands_includes_builtin(self, test_registry):
        """Test that list_commands includes built-in commands."""
        from fastapi.testclient import TestClient
        from fastapi import FastAPI
        from server.routes.commands import router

        app = FastAPI()
        app.include_router(router)
        client = TestClient(app)

        response = client.get("/command")
        assert response.status_code == 200

        commands = response.json()
        assert len(commands) >= len(BUILTIN_COMMANDS)

        # Check that built-in commands are present
        builtin_names = {cmd.name for cmd in BUILTIN_COMMANDS}
        response_names = {cmd["name"] for cmd in commands}
        assert builtin_names.issubset(response_names)

    def test_list_commands_includes_custom(self, test_registry):
        """Test that list_commands includes custom commands."""
        from fastapi.testclient import TestClient
        from fastapi import FastAPI
        from server.routes.commands import router

        app = FastAPI()
        app.include_router(router)
        client = TestClient(app)

        response = client.get("/command")
        assert response.status_code == 200

        commands = response.json()
        custom_commands = [c for c in commands if c.get("custom")]
        assert len(custom_commands) == 2

        names = {c["name"] for c in custom_commands}
        assert "simple" in names
        assert "complex" in names

    def test_get_command_detail(self, test_registry):
        """Test getting detailed command information."""
        from fastapi.testclient import TestClient
        from fastapi import FastAPI
        from server.routes.commands import router

        app = FastAPI()
        app.include_router(router)
        client = TestClient(app)

        response = client.get("/command/complex")
        assert response.status_code == 200

        cmd = response.json()
        assert cmd["name"] == "complex"
        assert cmd["description"] == "Complex command with args"
        assert len(cmd["args"]) == 2
        assert cmd["args"][0]["name"] == "arg1"
        assert cmd["args"][0]["required"] is True

    def test_get_nonexistent_command(self, test_registry):
        """Test getting a nonexistent command returns 404."""
        from fastapi.testclient import TestClient
        from fastapi import FastAPI
        from server.routes.commands import router

        app = FastAPI()
        app.include_router(router)
        client = TestClient(app)

        response = client.get("/command/nonexistent")
        assert response.status_code == 404

    def test_expand_command_endpoint(self, test_registry):
        """Test the expand command endpoint."""
        from fastapi.testclient import TestClient
        from fastapi import FastAPI
        from server.routes.commands import router

        app = FastAPI()
        app.include_router(router)
        client = TestClient(app)

        response = client.post(
            "/command/expand",
            json={"name": "complex", "args": ["value1", "value2"]},
        )
        assert response.status_code == 200

        result = response.json()
        assert "expanded" in result
        assert "value1" in result["expanded"]
        assert "value2" in result["expanded"]

    def test_expand_missing_required_arg_returns_400(self, test_registry):
        """Test that expanding with missing required arg returns 400."""
        from fastapi.testclient import TestClient
        from fastapi import FastAPI
        from server.routes.commands import router

        app = FastAPI()
        app.include_router(router)
        client = TestClient(app)

        response = client.post(
            "/command/expand",
            json={"name": "complex", "args": []},
        )
        assert response.status_code == 400
        assert "Required argument missing" in response.json()["detail"]

    def test_reload_commands_endpoint(self, test_registry):
        """Test the reload commands endpoint."""
        from fastapi.testclient import TestClient
        from fastapi import FastAPI
        from server.routes.commands import router

        app = FastAPI()
        app.include_router(router)
        client = TestClient(app)

        response = client.post("/command/reload")
        assert response.status_code == 200

        result = response.json()
        assert "count" in result
        assert result["count"] >= 0
