"""
Tests for the feature flags system.
"""

import pytest
from fastapi.testclient import TestClient

from config.features import (
    FEATURE_FLAGS,
    FeatureFlag,
    FeatureManager,
    FeatureStage,
    feature_manager,
)
from server.app import app


client = TestClient(app)


class TestFeatureFlag:
    """Test FeatureFlag dataclass."""

    def test_create_feature_flag(self):
        """Test creating a feature flag."""
        flag = FeatureFlag(
            name="test_feature",
            description="Test feature",
            stage=FeatureStage.EXPERIMENTAL,
            default=False,
        )
        assert flag.name == "test_feature"
        assert flag.description == "Test feature"
        assert flag.stage == FeatureStage.EXPERIMENTAL
        assert flag.default is False
        assert flag.deprecated is False
        assert flag.deprecated_by is None

    def test_deprecated_feature_flag(self):
        """Test creating a deprecated feature flag."""
        flag = FeatureFlag(
            name="old_feature",
            description="Old feature",
            stage=FeatureStage.STABLE,
            default=True,
            deprecated=True,
            deprecated_by="new_feature",
        )
        assert flag.deprecated is True
        assert flag.deprecated_by == "new_feature"


class TestFeatureStage:
    """Test FeatureStage enum."""

    def test_feature_stages(self):
        """Test that all feature stages exist."""
        assert FeatureStage.EXPERIMENTAL.value == "experimental"
        assert FeatureStage.BETA.value == "beta"
        assert FeatureStage.STABLE.value == "stable"


class TestFeatureRegistry:
    """Test the FEATURE_FLAGS registry."""

    def test_registry_exists(self):
        """Test that the feature flags registry exists."""
        assert isinstance(FEATURE_FLAGS, dict)
        assert len(FEATURE_FLAGS) > 0

    def test_stable_features(self):
        """Test stable features are in the registry."""
        assert "shell_tool" in FEATURE_FLAGS
        assert FEATURE_FLAGS["shell_tool"].stage == FeatureStage.STABLE
        assert FEATURE_FLAGS["shell_tool"].default is True

        assert "view_image" in FEATURE_FLAGS
        assert FEATURE_FLAGS["view_image"].stage == FeatureStage.STABLE
        assert FEATURE_FLAGS["view_image"].default is True

    def test_beta_features(self):
        """Test beta features are in the registry."""
        assert "web_search" in FEATURE_FLAGS
        assert FEATURE_FLAGS["web_search"].stage == FeatureStage.BETA

        assert "patch_tool" in FEATURE_FLAGS
        assert FEATURE_FLAGS["patch_tool"].stage == FeatureStage.BETA

    def test_experimental_features(self):
        """Test experimental features are in the registry."""
        assert "ghost_commit" in FEATURE_FLAGS
        assert FEATURE_FLAGS["ghost_commit"].stage == FeatureStage.EXPERIMENTAL
        assert FEATURE_FLAGS["ghost_commit"].default is False

        assert "skills" in FEATURE_FLAGS
        assert FEATURE_FLAGS["skills"].stage == FeatureStage.EXPERIMENTAL

        assert "unified_exec" in FEATURE_FLAGS
        assert FEATURE_FLAGS["unified_exec"].stage == FeatureStage.EXPERIMENTAL

        assert "parallel_tools" in FEATURE_FLAGS
        assert FEATURE_FLAGS["parallel_tools"].stage == FeatureStage.EXPERIMENTAL


class TestFeatureManager:
    """Test FeatureManager class."""

    def setup_method(self):
        """Set up test fixtures."""
        self.manager = FeatureManager()

    def test_init(self):
        """Test FeatureManager initialization."""
        manager = FeatureManager()
        assert manager._overrides == {}

    def test_is_enabled_default(self):
        """Test checking default feature state."""
        # Stable feature (default enabled)
        assert self.manager.is_enabled("shell_tool") is True

        # Experimental feature (default disabled)
        assert self.manager.is_enabled("ghost_commit") is False

    def test_is_enabled_unknown_feature(self):
        """Test checking unknown feature returns False."""
        assert self.manager.is_enabled("unknown_feature") is False

    def test_enable(self):
        """Test enabling a feature."""
        # Enable an experimental feature
        self.manager.enable("ghost_commit")
        assert self.manager.is_enabled("ghost_commit") is True

    def test_disable(self):
        """Test disabling a feature."""
        # Disable a stable feature
        self.manager.disable("shell_tool")
        assert self.manager.is_enabled("shell_tool") is False

    def test_enable_unknown_feature(self):
        """Test enabling unknown feature is ignored."""
        self.manager.enable("unknown_feature")
        # Should not raise error, just be ignored
        assert self.manager.is_enabled("unknown_feature") is False

    def test_disable_unknown_feature(self):
        """Test disabling unknown feature is ignored."""
        self.manager.disable("unknown_feature")
        # Should not raise error, just be ignored
        assert self.manager.is_enabled("unknown_feature") is False

    def test_override_persists(self):
        """Test that overrides persist across checks."""
        self.manager.enable("ghost_commit")
        assert self.manager.is_enabled("ghost_commit") is True
        assert self.manager.is_enabled("ghost_commit") is True

    def test_load_from_config(self):
        """Test loading feature overrides from config."""
        config = {
            "features": {
                "ghost_commit": True,
                "shell_tool": False,
                "unknown_feature": True,  # Should be ignored
            }
        }
        self.manager.load_from_config(config)

        assert self.manager.is_enabled("ghost_commit") is True
        assert self.manager.is_enabled("shell_tool") is False
        assert self.manager.is_enabled("unknown_feature") is False

    def test_load_from_config_no_features(self):
        """Test loading config without features section."""
        config = {"theme": "dark"}
        self.manager.load_from_config(config)
        # Should not raise error
        assert self.manager.is_enabled("shell_tool") is True

    def test_list_features(self):
        """Test listing all features."""
        features = self.manager.list_features()

        assert isinstance(features, list)
        assert len(features) == len(FEATURE_FLAGS)

        # Check structure of first feature
        feature = features[0]
        assert "name" in feature
        assert "description" in feature
        assert "stage" in feature
        assert "default" in feature
        assert "enabled" in feature
        assert "overridden" in feature
        assert "deprecated" in feature

    def test_list_features_with_overrides(self):
        """Test listing features shows override status."""
        self.manager.enable("ghost_commit")

        features = self.manager.list_features()
        ghost_commit = next(f for f in features if f["name"] == "ghost_commit")

        assert ghost_commit["enabled"] is True
        assert ghost_commit["overridden"] is True
        assert ghost_commit["default"] is False

    def test_list_features_without_overrides(self):
        """Test listing features without overrides."""
        features = self.manager.list_features()
        shell_tool = next(f for f in features if f["name"] == "shell_tool")

        assert shell_tool["enabled"] is True
        assert shell_tool["overridden"] is False
        assert shell_tool["default"] is True


class TestGlobalFeatureManager:
    """Test the global feature_manager instance."""

    def setup_method(self):
        """Clear global feature manager overrides."""
        feature_manager._overrides.clear()

    def teardown_method(self):
        """Clean up after tests."""
        feature_manager._overrides.clear()

    def test_global_instance_exists(self):
        """Test that global feature_manager exists."""
        assert feature_manager is not None
        assert isinstance(feature_manager, FeatureManager)

    def test_global_instance_works(self):
        """Test that global instance works correctly."""
        feature_manager.enable("ghost_commit")
        assert feature_manager.is_enabled("ghost_commit") is True

        feature_manager.disable("ghost_commit")
        assert feature_manager.is_enabled("ghost_commit") is False


class TestFeaturesAPI:
    """Test the /features API endpoints."""

    def setup_method(self):
        """Clear global feature manager overrides."""
        feature_manager._overrides.clear()

    def teardown_method(self):
        """Clean up after tests."""
        feature_manager._overrides.clear()

    def test_list_features_endpoint(self):
        """Test GET /features endpoint."""
        response = client.get("/features")
        assert response.status_code == 200

        features = response.json()
        assert isinstance(features, list)
        assert len(features) == len(FEATURE_FLAGS)

        # Check structure
        feature = features[0]
        assert "name" in feature
        assert "description" in feature
        assert "stage" in feature
        assert "default" in feature
        assert "enabled" in feature
        assert "overridden" in feature
        assert "deprecated" in feature

    def test_list_features_contains_all_stages(self):
        """Test that list features includes all stages."""
        response = client.get("/features")
        features = response.json()

        stages = {f["stage"] for f in features}
        assert "stable" in stages
        assert "beta" in stages
        assert "experimental" in stages

    def test_get_feature_endpoint(self):
        """Test GET /features/{feature_name} endpoint."""
        response = client.get("/features/shell_tool")
        assert response.status_code == 200

        feature = response.json()
        assert feature["name"] == "shell_tool"
        assert feature["enabled"] is True

    def test_get_feature_disabled(self):
        """Test getting a disabled feature."""
        response = client.get("/features/ghost_commit")
        assert response.status_code == 200

        feature = response.json()
        assert feature["name"] == "ghost_commit"
        assert feature["enabled"] is False

    def test_get_feature_unknown(self):
        """Test getting an unknown feature returns False."""
        response = client.get("/features/unknown_feature")
        assert response.status_code == 200

        feature = response.json()
        assert feature["name"] == "unknown_feature"
        assert feature["enabled"] is False

    def test_features_reflect_overrides(self):
        """Test that API reflects feature overrides."""
        # Enable a feature
        feature_manager.enable("ghost_commit")

        response = client.get("/features")
        features = response.json()
        ghost_commit = next(f for f in features if f["name"] == "ghost_commit")

        assert ghost_commit["enabled"] is True
        assert ghost_commit["overridden"] is True

        # Also check individual endpoint
        response = client.get("/features/ghost_commit")
        feature = response.json()
        assert feature["enabled"] is True
