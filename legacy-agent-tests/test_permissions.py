"""Tests for the permission system."""

import pytest

from core.events import NullEventBus
from core.permissions import (
    Action,
    Level,
    PermissionChecker,
    PermissionStore,
    PermissionsConfig,
    Request,
    Response,
    is_dangerous_bash_command,
    match_pattern,
)


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
        assert "EXTREMELY DANGEROUS" in warning

        is_dangerous, warning = is_dangerous_bash_command("dd if=/dev/zero")
        assert is_dangerous
        assert "dd if=" in warning

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


class TestPermissionStore:
    """Tests for permission storage."""

    def test_default_config(self):
        """Test default configuration."""
        store = PermissionStore()
        config = store.get_config("test_session")
        assert config.edit == Level.ASK
        assert config.bash.default == Level.ASK
        assert config.webfetch == Level.ALLOW

    def test_add_bash_pattern(self):
        """Test adding bash patterns."""
        store = PermissionStore()
        store.add_bash_pattern("test_session", "git *", Level.ALLOW)

        config = store.get_config("test_session")
        assert "git *" in config.bash.patterns
        assert config.bash.patterns["git *"] == Level.ALLOW

    def test_pending_requests(self):
        """Test pending request tracking."""
        store = PermissionStore()
        request = Request(
            id="req_123",
            session_id="test_session",
            message_id="msg_123",
            operation="bash",
            details={"command": "ls -la"},
        )

        store.add_pending_request(request)
        retrieved = store.get_pending_request("req_123")
        assert retrieved == request

        store.remove_pending_request("req_123")
        assert store.get_pending_request("req_123") is None

    def test_apply_response_always(self):
        """Test applying 'always' response."""
        store = PermissionStore()
        request = Request(
            id="req_123",
            session_id="test_session",
            message_id="msg_123",
            operation="bash",
            details={"command": "git status"},
        )
        response = Response(
            request_id="req_123",
            action=Action.APPROVE_ALWAYS,
        )

        store.apply_response(request, response)

        config = store.get_config("test_session")
        assert "git status" in config.bash.patterns
        assert config.bash.patterns["git status"] == Level.ALLOW

    def test_apply_response_pattern(self):
        """Test applying custom pattern response."""
        store = PermissionStore()
        request = Request(
            id="req_123",
            session_id="test_session",
            message_id="msg_123",
            operation="bash",
            details={"command": "git commit -m 'test'"},
        )
        response = Response(
            request_id="req_123",
            action=Action.APPROVE_PATTERN,
            pattern="git *",
        )

        store.apply_response(request, response)

        config = store.get_config("test_session")
        assert "git *" in config.bash.patterns
        assert config.bash.patterns["git *"] == Level.ALLOW

    def test_clear_session(self):
        """Test clearing session permissions."""
        store = PermissionStore()
        store.add_bash_pattern("test_session", "git *", Level.ALLOW)

        store.clear_session("test_session")

        # Should get fresh default config
        config = store.get_config("test_session")
        assert "git *" not in config.bash.patterns


class TestPermissionChecker:
    """Tests for permission checker."""

    def test_check_bash_exact_match(self):
        """Test bash permission check with exact match."""
        store = PermissionStore()
        store.add_bash_pattern("test_session", "ls", Level.ALLOW)

        checker = PermissionChecker(store, NullEventBus())

        assert checker.check_bash("ls", "test_session") == Level.ALLOW
        assert checker.check_bash("ls -la", "test_session") == Level.ASK

    def test_check_bash_pattern_match(self):
        """Test bash permission check with pattern match."""
        store = PermissionStore()
        store.add_bash_pattern("test_session", "git *", Level.ALLOW)

        checker = PermissionChecker(store, NullEventBus())

        assert checker.check_bash("git status", "test_session") == Level.ALLOW
        assert checker.check_bash("git commit", "test_session") == Level.ALLOW
        assert checker.check_bash("npm install", "test_session") == Level.ASK

    def test_check_bash_default(self):
        """Test bash permission check with default."""
        store = PermissionStore()
        checker = PermissionChecker(store, NullEventBus())

        # No patterns, should return default
        assert checker.check_bash("ls", "test_session") == Level.ASK

    def test_check_edit(self):
        """Test edit permission check."""
        store = PermissionStore()
        checker = PermissionChecker(store, NullEventBus())

        assert checker.check_edit("/tmp/test.txt", "test_session") == Level.ASK

    def test_check_webfetch(self):
        """Test webfetch permission check."""
        store = PermissionStore()
        checker = PermissionChecker(store, NullEventBus())

        assert checker.check_webfetch("https://example.com", "test_session") == Level.ALLOW

    def test_respond_to_request(self):
        """Test responding to permission request."""
        store = PermissionStore()
        checker = PermissionChecker(store, NullEventBus())

        # Create a future-like scenario
        response = Response(
            request_id="req_123",
            action=Action.APPROVE_ONCE,
        )

        # Should not raise error even if request doesn't exist
        checker.respond_to_request(response)


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
