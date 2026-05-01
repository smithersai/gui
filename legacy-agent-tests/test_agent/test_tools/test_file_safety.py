"""
Tests for file safety features (read-before-write enforcement).

Tests the FileTimeTracker class and its integration with file operations.
"""

import os
import tempfile
import time
from pathlib import Path

import pytest

from agent.tools.file_time import FileTimeTracker
from agent.tools.filesystem import (
    set_current_session_id,
    get_current_session_id,
    mark_file_read,
    check_file_writable,
)
from core.state import get_file_tracker


class TestFileTimeTracker:
    """Tests for FileTimeTracker class."""

    def test_mark_read_stores_timestamp(self, tmp_path):
        """Test that marking a file as read stores its modification time."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        tracker.mark_read(str(test_file))

        assert tracker.is_read(str(test_file))
        assert tracker.get_read_time(str(test_file)) is not None

    def test_assert_not_modified_succeeds_when_unchanged(self, tmp_path):
        """Test that asserting file not modified succeeds for unchanged files."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        tracker.mark_read(str(test_file))

        # Should not raise
        tracker.assert_not_modified(str(test_file))

    def test_assert_not_modified_fails_when_not_read(self, tmp_path):
        """Test that asserting file not modified fails if file wasn't read."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        with pytest.raises(ValueError, match="has not been read"):
            tracker.assert_not_modified(str(test_file))

    def test_assert_not_modified_fails_when_modified(self, tmp_path):
        """Test that asserting file not modified fails if file was modified."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        tracker.mark_read(str(test_file))

        # Wait a bit and modify file
        time.sleep(0.01)
        test_file.write_text("modified content")

        with pytest.raises(ValueError, match="has been modified since"):
            tracker.assert_not_modified(str(test_file))

    def test_path_normalization(self, tmp_path):
        """Test that paths are normalized correctly."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        # Mark with relative path
        os.chdir(tmp_path)
        tracker.mark_read("test.txt")

        # Check with absolute path
        assert tracker.is_read(str(test_file))

    def test_symlink_resolution(self, tmp_path):
        """Test that symlinks are resolved to real paths."""
        tracker = FileTimeTracker()
        real_file = tmp_path / "real.txt"
        real_file.write_text("content")

        link_file = tmp_path / "link.txt"
        link_file.symlink_to(real_file)

        # Mark via symlink
        tracker.mark_read(str(link_file))

        # Should be tracked under real path
        tracker.assert_not_modified(str(real_file))

    def test_deleted_file_allows_write(self, tmp_path):
        """Test that deleted files can be written (creating new file)."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        tracker.mark_read(str(test_file))
        test_file.unlink()

        # Should not raise - file was deleted
        tracker.assert_not_modified(str(test_file))

    def test_clear_removes_all_tracking(self, tmp_path):
        """Test that clear() removes all tracked files."""
        tracker = FileTimeTracker()
        test_file1 = tmp_path / "test1.txt"
        test_file2 = tmp_path / "test2.txt"
        test_file1.write_text("content1")
        test_file2.write_text("content2")

        tracker.mark_read(str(test_file1))
        tracker.mark_read(str(test_file2))

        tracker.clear()

        assert not tracker.is_read(str(test_file1))
        assert not tracker.is_read(str(test_file2))


class TestFilesystemHelpers:
    """Tests for filesystem helper functions."""

    def test_set_and_get_session_id(self):
        """Test setting and getting session ID from context."""
        set_current_session_id("test-session")
        assert get_current_session_id() == "test-session"

    def test_get_session_id_without_set_raises(self):
        """Test that getting session ID without setting raises error."""
        set_current_session_id(None)
        with pytest.raises(RuntimeError, match="No session ID set"):
            get_current_session_id()

    def test_mark_file_read_uses_session_tracker(self, tmp_path):
        """Test that mark_file_read uses the session's tracker."""
        set_current_session_id("session1")
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        mark_file_read(str(test_file))

        tracker = get_file_tracker("session1")
        assert tracker.is_read(str(test_file))

    def test_check_file_writable_allows_new_files(self, tmp_path):
        """Test that check_file_writable allows writing new files."""
        set_current_session_id("session1")
        new_file = tmp_path / "new.txt"

        # Should not raise for non-existent file
        check_file_writable(str(new_file))

    def test_check_file_writable_requires_read_for_existing(self, tmp_path):
        """Test that check_file_writable requires read for existing files."""
        set_current_session_id("session1")
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        with pytest.raises(ValueError, match="has not been read"):
            check_file_writable(str(test_file))

    def test_check_file_writable_allows_after_read(self, tmp_path):
        """Test that check_file_writable allows write after read."""
        set_current_session_id("session1")
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        mark_file_read(str(test_file))

        # Should not raise
        check_file_writable(str(test_file))


class TestSessionIsolation:
    """Tests for session-scoped tracking."""

    def test_different_sessions_have_separate_trackers(self, tmp_path):
        """Test that different sessions have separate file trackers."""
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        # Read in session 1
        set_current_session_id("session1")
        mark_file_read(str(test_file))

        # Should fail in session 2 (not read there)
        set_current_session_id("session2")
        with pytest.raises(ValueError, match="has not been read"):
            check_file_writable(str(test_file))

    def test_same_session_shares_state(self, tmp_path):
        """Test that the same session shares tracking state."""
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        set_current_session_id("session1")
        mark_file_read(str(test_file))

        # Should succeed in same session
        check_file_writable(str(test_file))


class TestEdgeCases:
    """Tests for edge cases and error conditions."""

    def test_permission_error_handling(self, tmp_path):
        """Test handling of permission errors during stat."""
        if os.name == 'nt':
            pytest.skip("Permission test not reliable on Windows")

        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")
        tracker.mark_read(str(test_file))

        # Make file unreadable
        os.chmod(test_file, 0o000)

        try:
            # Should not raise - allows write to proceed
            tracker.assert_not_modified(str(test_file))
        finally:
            # Restore permissions for cleanup
            os.chmod(test_file, 0o644)

    def test_rapid_read_write_cycles(self, tmp_path):
        """Test rapid read-write-read cycles."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        for i in range(5):
            tracker.mark_read(str(test_file))
            test_file.write_text(f"content {i}")
            # Mark read again after write
            tracker.mark_read(str(test_file))

    def test_nonexistent_file_mark_read(self, tmp_path):
        """Test marking non-existent file as read."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "nonexistent.txt"

        # Should not raise - tracks the read attempt
        tracker.mark_read(str(test_file))
        assert tracker.is_read(str(test_file))

    def test_directory_vs_file(self, tmp_path):
        """Test that tracker handles both files and directories."""
        tracker = FileTimeTracker()
        test_dir = tmp_path / "testdir"
        test_dir.mkdir()

        tracker.mark_read(str(test_dir))
        assert tracker.is_read(str(test_dir))


class TestEnhancedFeatures:
    """Tests for enhanced file modification tracking features."""

    def test_mark_written_updates_timestamp(self, tmp_path):
        """Test that mark_written updates the tracked timestamp."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        tracker.mark_read(str(test_file))
        original_read_time = tracker.get_read_time(str(test_file))

        # Sleep and modify file
        time.sleep(0.01)
        test_file.write_text("new content")

        # Mark as written to update tracking
        tracker.mark_written(str(test_file))

        # Now should not raise even though file was modified
        tracker.assert_not_modified(str(test_file))

        # Verify timestamp was updated
        new_read_time = tracker.get_read_time(str(test_file))
        assert new_read_time > original_read_time

    def test_mark_written_after_agent_write(self, tmp_path):
        """Test typical workflow: read -> write -> mark_written."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("original")

        # Agent reads file
        tracker.mark_read(str(test_file))

        # Sleep to ensure different mtime
        time.sleep(0.01)

        # Agent modifies file
        test_file.write_text("modified by agent")

        # Mark as written
        tracker.mark_written(str(test_file))

        # Subsequent write should still work (file was tracked)
        tracker.assert_not_modified(str(test_file))

    def test_clear_file_removes_tracking(self, tmp_path):
        """Test that clear_file removes tracking for specific file."""
        tracker = FileTimeTracker()
        test_file1 = tmp_path / "file1.txt"
        test_file2 = tmp_path / "file2.txt"
        test_file1.write_text("content1")
        test_file2.write_text("content2")

        tracker.mark_read(str(test_file1))
        tracker.mark_read(str(test_file2))

        # Clear only file1
        tracker.clear_file(str(test_file1))

        # file1 should not be tracked
        assert not tracker.is_read(str(test_file1))

        # file2 should still be tracked
        assert tracker.is_read(str(test_file2))

    def test_error_message_includes_timestamps(self, tmp_path):
        """Test that error messages include readable timestamps."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        tracker.mark_read(str(test_file))

        # Wait and modify file
        time.sleep(0.01)
        test_file.write_text("modified")

        # Check that error message includes timestamps
        try:
            tracker.assert_not_modified(str(test_file))
            pytest.fail("Should have raised ValueError")
        except ValueError as e:
            error_msg = str(e)
            # Should include both timestamps
            assert "Last modification:" in error_msg
            assert "Last read:" in error_msg
            # Should be in ISO format
            assert "T" in error_msg  # ISO format includes T separator

    def test_external_modification_scenario(self, tmp_path):
        """Test the scenario where external tool modifies file."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "config.json"
        test_file.write_text('{"key": "value"}')

        # Agent reads file
        tracker.mark_read(str(test_file))

        # External formatter modifies file
        time.sleep(0.01)
        test_file.write_text('{\n  "key": "value"\n}')

        # Agent tries to write - should fail
        with pytest.raises(ValueError, match="has been modified since"):
            tracker.assert_not_modified(str(test_file))

        # Agent re-reads file
        tracker.mark_read(str(test_file))

        # Now write should succeed
        tracker.assert_not_modified(str(test_file))

    def test_mark_written_handles_deleted_file(self, tmp_path):
        """Test that mark_written handles deleted files gracefully."""
        tracker = FileTimeTracker()
        test_file = tmp_path / "test.txt"
        test_file.write_text("content")

        tracker.mark_read(str(test_file))
        test_file.unlink()

        # Should not raise
        tracker.mark_written(str(test_file))

        # File should no longer be tracked
        assert not tracker.is_read(str(test_file))


@pytest.fixture(autouse=True)
def cleanup_session():
    """Cleanup session context after each test."""
    yield
    set_current_session_id(None)
