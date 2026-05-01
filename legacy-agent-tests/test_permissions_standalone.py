"""Standalone tests for the permission system that avoid circular imports."""

import sys
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

# Import only permissions modules to avoid circular import
from core.permissions.models import (
    Action,
    Level,
    PermissionsConfig,
    BashPermission,
    Request,
    Response,
)
from core.permissions.patterns import match_pattern
from core.permissions.dangerous import is_dangerous_bash_command


class TestPatternMatching:
    """Tests for pattern matching."""

    def test_wildcard_only(self):
        """Test wildcard-only pattern."""
        assert match_pattern("*", "anything")
        assert match_pattern("*", "git status")
        assert match_pattern("*", "")

    def test_prefix_wildcard(self):
        """Test prefix wildcard patterns."""
        assert match_pattern("git *", "git status")
        assert match_pattern("git *", "git commit -m 'test'")
        assert not match_pattern("git *", "ls -la")
        assert not match_pattern("git *", "status git")

    def test_exact_match(self):
        """Test exact matching."""
        assert match_pattern("ls", "ls")
        assert not match_pattern("ls", "ls -la")

    def test_glob_patterns(self):
        """Test glob patterns with fnmatch."""
        assert match_pattern("*.py", "test.py")
        assert match_pattern("*.py", "main.py")
        assert not match_pattern("*.py", "test.txt")

        assert match_pattern("test_*.py", "test_permissions.py")
        assert match_pattern("test_*.py", "test_core.py")
        assert not match_pattern("test_*.py", "permissions.py")


class TestDangerousCommands:
    """Tests for dangerous command detection."""

    def test_dangerous_exact_match(self):
        """Test exact dangerous command matches."""
        is_dangerous, warning = is_dangerous_bash_command("rm -rf /")
        assert is_dangerous
        assert "EXTREMELY DANGEROUS" in warning or "rm -rf" in warning

        is_dangerous, warning = is_dangerous_bash_command("dd if=/dev/zero")
        assert is_dangerous
        assert "dd if=" in warning or "dd if=/dev/" in warning

    def test_dangerous_prefix(self):
        """Test dangerous command prefixes."""
        is_dangerous, warning = is_dangerous_bash_command("rm -rf /tmp/test")
        assert is_dangerous
        assert "rm -rf" in warning

        is_dangerous, warning = is_dangerous_bash_command("mkfs.ext4 /dev/sda")
        assert is_dangerous
        assert "mkfs." in warning

    def test_safe_commands(self):
        """Test that safe commands are not flagged."""
        is_dangerous, _ = is_dangerous_bash_command("ls -la")
        assert not is_dangerous

        is_dangerous, _ = is_dangerous_bash_command("git status")
        assert not is_dangerous

        is_dangerous, _ = is_dangerous_bash_command("echo 'hello'")
        assert not is_dangerous


class TestPermissionsConfig:
    """Tests for permissions configuration model."""

    def test_default_config_creation(self):
        """Test creating default config."""
        config = PermissionsConfig()

        assert config.edit == Level.ASK
        assert config.bash.default == Level.ASK
        assert config.bash.patterns == {}
        assert config.webfetch == Level.ALLOW

    def test_custom_config_creation(self):
        """Test creating custom config."""
        config = PermissionsConfig(
            edit=Level.DENY,
            webfetch=Level.ASK,
        )

        assert config.edit == Level.DENY
        assert config.webfetch == Level.ASK

    def test_model_dump(self):
        """Test serializing config to dict."""
        config = PermissionsConfig()
        config.bash.patterns["git *"] = Level.ALLOW

        dumped = config.model_dump()

        assert dumped["edit"] == "ask"
        assert dumped["bash"]["default"] == "ask"
        assert dumped["bash"]["patterns"]["git *"] == "allow"
        assert dumped["webfetch"] == "allow"


class TestPermissionRequest:
    """Tests for permission request model."""

    def test_create_request(self):
        """Test creating a permission request."""
        request = Request(
            id="req_123",
            session_id="sess_456",
            message_id="msg_789",
            call_id="call_abc",
            operation="bash",
            details={"command": "rm -rf /tmp/test"},
        )

        assert request.id == "req_123"
        assert request.session_id == "sess_456"
        assert request.operation == "bash"
        assert request.details["command"] == "rm -rf /tmp/test"
        assert not request.is_dangerous  # Not set yet

    def test_request_with_danger_flag(self):
        """Test request with danger flag."""
        request = Request(
            id="req_123",
            session_id="sess_456",
            message_id="msg_789",
            operation="bash",
            details={"command": "rm -rf /"},
            is_dangerous=True,
            warning="⚠️  WARNING: Extremely dangerous",
        )

        assert request.is_dangerous
        assert "WARNING" in request.warning


class TestPermissionResponse:
    """Tests for permission response model."""

    def test_create_response_once(self):
        """Test creating approval once response."""
        response = Response(
            request_id="req_123",
            action=Action.APPROVE_ONCE,
        )

        assert response.request_id == "req_123"
        assert response.action == Action.APPROVE_ONCE
        assert response.pattern is None

    def test_create_response_pattern(self):
        """Test creating pattern response."""
        response = Response(
            request_id="req_123",
            action=Action.APPROVE_PATTERN,
            pattern="git *",
        )

        assert response.action == Action.APPROVE_PATTERN
        assert response.pattern == "git *"

    def test_create_response_deny(self):
        """Test creating deny response."""
        response = Response(
            request_id="req_123",
            action=Action.DENY,
        )

        assert response.action == Action.DENY
