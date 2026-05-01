"""
Unit tests for bypass mode functionality.

Tests the bypass mode feature including:
- Session creation with bypass_mode flag
- PermissionChecker utility behavior
- Session model validation
"""
import pytest


class TestPermissionCheckerImport:
    """Test PermissionChecker can be imported and used."""

    def test_import_permission_checker(self):
        """PermissionChecker should import correctly."""
        from config.permissions_config import PermissionChecker, PermissionsConfig
        assert PermissionChecker is not None
        assert PermissionsConfig is not None


class TestPermissionChecker:
    """Test PermissionChecker utility."""

    def test_should_skip_checks_with_bypass_mode(self):
        """Bypass mode should skip permission checks."""
        from config.permissions_config import PermissionChecker
        assert PermissionChecker.should_skip_checks(bypass_mode=True) is True

    def test_should_skip_checks_without_bypass_mode(self):
        """Normal mode should not skip permission checks."""
        from config.permissions_config import PermissionChecker
        assert PermissionChecker.should_skip_checks(bypass_mode=False) is False

    def test_check_bash_permission_with_bypass_mode(self):
        """Bypass mode should allow any bash command."""
        from config.permissions_config import PermissionChecker
        # Even with empty patterns, bypass mode allows all
        assert PermissionChecker.check_bash_permission(
            command="rm -rf /",
            patterns=[],
            bypass_mode=True
        ) is True

    def test_check_bash_permission_without_bypass_mode(self):
        """Normal mode should respect patterns."""
        from config.permissions_config import PermissionChecker
        # Command not matching patterns should be denied
        assert PermissionChecker.check_bash_permission(
            command="dangerous_command",
            patterns=["safe_*"],
            bypass_mode=False
        ) is False

        # Command matching pattern should be allowed
        assert PermissionChecker.check_bash_permission(
            command="safe_command",
            patterns=["safe_*"],
            bypass_mode=False
        ) is True

    def test_check_file_permission_with_bypass_mode(self):
        """Bypass mode should allow any file operation."""
        from config.permissions_config import PermissionChecker
        assert PermissionChecker.check_file_permission(
            file_path="/etc/passwd",
            patterns=[],
            bypass_mode=True
        ) is True

    def test_check_file_permission_without_bypass_mode(self):
        """Normal mode should respect patterns."""
        from config.permissions_config import PermissionChecker
        # File not matching patterns should be denied
        assert PermissionChecker.check_file_permission(
            file_path="/etc/passwd",
            patterns=["*.txt"],
            bypass_mode=False
        ) is False

        # File matching pattern should be allowed
        assert PermissionChecker.check_file_permission(
            file_path="test.txt",
            patterns=["*.txt"],
            bypass_mode=False
        ) is True

    def test_check_webfetch_permission_with_bypass_mode(self):
        """Bypass mode should allow web fetch even if disabled."""
        from config.permissions_config import PermissionChecker
        assert PermissionChecker.check_webfetch_permission(
            url="https://example.com",
            webfetch_enabled=False,
            bypass_mode=True
        ) is True

    def test_check_webfetch_permission_without_bypass_mode(self):
        """Normal mode should respect webfetch_enabled flag."""
        from config.permissions_config import PermissionChecker
        # Disabled webfetch should deny
        assert PermissionChecker.check_webfetch_permission(
            url="https://example.com",
            webfetch_enabled=False,
            bypass_mode=False
        ) is False

        # Enabled webfetch should allow
        assert PermissionChecker.check_webfetch_permission(
            url="https://example.com",
            webfetch_enabled=True,
            bypass_mode=False
        ) is True


class TestSessionModel:
    """Test Session model with bypass_mode field."""

    @pytest.mark.skip(reason="Circular import issue with core.models - tested in e2e tests instead")
    def test_session_defaults_to_normal_mode(self):
        """New sessions should default to bypass_mode=False."""
        from core.models.session import Session
        from core.models.session_time import SessionTime
        session = Session(
            id="ses_123",
            projectID="test",
            directory="/tmp",
            title="Test Session",
            version="1.0.0",
            time=SessionTime(created=0.0, updated=0.0),
        )
        assert session.bypass_mode is False

    @pytest.mark.skip(reason="Circular import issue with core.models - tested in e2e tests instead")
    def test_session_can_enable_bypass_mode(self):
        """Sessions can be created with bypass_mode=True."""
        from core.models.session import Session
        from core.models.session_time import SessionTime
        session = Session(
            id="ses_456",
            projectID="test",
            directory="/tmp",
            title="Bypass Session",
            version="1.0.0",
            time=SessionTime(created=0.0, updated=0.0),
            bypass_mode=True,
        )
        assert session.bypass_mode is True

    @pytest.mark.skip(reason="Circular import issue with core.models - tested in e2e tests instead")
    def test_session_serialization_includes_bypass_mode(self):
        """Session serialization should include bypass_mode field."""
        from core.models.session import Session
        from core.models.session_time import SessionTime
        session = Session(
            id="ses_789",
            projectID="test",
            directory="/tmp",
            title="Test",
            version="1.0.0",
            time=SessionTime(created=0.0, updated=0.0),
            bypass_mode=True,
        )
        data = session.model_dump()
        assert "bypass_mode" in data
        assert data["bypass_mode"] is True


class TestPermissionsConfig:
    """Test PermissionsConfig model."""

    def test_default_permissions_config(self):
        """Default config should have sensible defaults."""
        from config.permissions_config import PermissionsConfig
        config = PermissionsConfig()
        assert config.edit_patterns == ["**/*"]
        assert config.bash_patterns == ["*"]
        assert config.webfetch_enabled is True

    def test_custom_permissions_config(self):
        """Config can be customized."""
        from config.permissions_config import PermissionsConfig
        config = PermissionsConfig(
            edit_patterns=["*.py"],
            bash_patterns=["ls", "pwd"],
            webfetch_enabled=False,
        )
        assert config.edit_patterns == ["*.py"]
        assert config.bash_patterns == ["ls", "pwd"]
        assert config.webfetch_enabled is False
