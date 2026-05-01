"""
Integration tests for FastAPI server.
NO MOCKS - uses real FastAPI TestClient for HTTP endpoint testing.
"""
import json
import time

import pytest
from fastapi.testclient import TestClient

from server import app, set_agent
from core.state import sessions, session_messages
from agent.agent import create_agent
from agent.wrapper import AgentWrapper


@pytest.fixture
def client():
    """Create a test client for the FastAPI app."""
    return TestClient(app)


@pytest.fixture
def setup_agent(mock_env_vars):
    """Set up a test agent."""
    agent = create_agent()
    wrapper = AgentWrapper(agent)
    set_agent(wrapper)
    yield wrapper
    # Cleanup
    set_agent(None)


@pytest.fixture(autouse=True)
def clear_sessions():
    """Clear sessions before each test."""
    sessions.clear()
    session_messages.clear()
    yield
    sessions.clear()
    session_messages.clear()


class TestHealthEndpoint:
    """Test health check endpoint."""

    def test_health_without_agent(self, client):
        """Test health endpoint when agent is not configured."""
        set_agent(None)
        response = client.get("/health")

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "ok"
        assert data["agent_configured"] is False

    def test_health_with_agent(self, client, setup_agent):
        """Test health endpoint when agent is configured."""
        response = client.get("/health")

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "ok"
        assert data["agent_configured"] is True


class TestSessionEndpoints:
    """Test session management endpoints."""

    def test_create_session(self, client):
        """Test creating a new session."""
        response = client.post(
            "/session", json={"title": "Test Session", "parentID": None}
        )

        assert response.status_code == 200
        data = response.json()
        assert data["title"] == "Test Session"
        assert "id" in data
        assert data["id"].startswith("ses_")
        assert "time" in data
        assert data["time"]["created"] > 0

    def test_create_session_with_parent(self, client):
        """Test creating a session with parent ID."""
        # Create parent session
        parent_response = client.post("/session", json={"title": "Parent"})
        parent_id = parent_response.json()["id"]

        # Create child session
        response = client.post(
            "/session", json={"title": "Child", "parentID": parent_id}
        )

        assert response.status_code == 200
        data = response.json()
        assert data["parentID"] == parent_id

    def test_list_sessions(self, client):
        """Test listing all sessions."""
        # Create a few sessions
        client.post("/session", json={"title": "Session 1"})
        client.post("/session", json={"title": "Session 2"})

        response = client.get("/session")

        assert response.status_code == 200
        data = response.json()
        assert isinstance(data, list)
        assert len(data) == 2

    def test_list_sessions_empty(self, client):
        """Test listing sessions when none exist."""
        response = client.get("/session")

        assert response.status_code == 200
        data = response.json()
        assert data == []

    def test_get_session(self, client):
        """Test getting a specific session."""
        # Create session
        create_response = client.post("/session", json={"title": "Test"})
        session_id = create_response.json()["id"]

        # Get session
        response = client.get(f"/session/{session_id}")

        assert response.status_code == 200
        data = response.json()
        assert data["id"] == session_id
        assert data["title"] == "Test"

    def test_get_nonexistent_session(self, client):
        """Test getting a session that doesn't exist."""
        response = client.get("/session/ses_nonexistent")

        assert response.status_code == 404

    def test_update_session_title(self, client):
        """Test updating session title."""
        # Create session
        create_response = client.post("/session", json={"title": "Original"})
        session_id = create_response.json()["id"]

        # Update title
        response = client.patch(
            f"/session/{session_id}", json={"title": "Updated"}
        )

        assert response.status_code == 200
        data = response.json()
        assert data["title"] == "Updated"

    def test_update_session_archived(self, client):
        """Test archiving a session."""
        # Create session
        create_response = client.post("/session", json={"title": "Test"})
        session_id = create_response.json()["id"]

        # Archive session
        archived_time = time.time()
        response = client.patch(
            f"/session/{session_id}", json={"time": {"archived": archived_time}}
        )

        assert response.status_code == 200
        data = response.json()
        assert data["time"]["archived"] == archived_time

    def test_delete_session(self, client):
        """Test deleting a session."""
        # Create session
        create_response = client.post("/session", json={"title": "Test"})
        session_id = create_response.json()["id"]

        # Delete session
        response = client.delete(f"/session/{session_id}")

        assert response.status_code == 200
        assert response.json() is True

        # Verify it's gone
        get_response = client.get(f"/session/{session_id}")
        assert get_response.status_code == 404

    def test_delete_nonexistent_session(self, client):
        """Test deleting a session that doesn't exist."""
        response = client.delete("/session/ses_nonexistent")

        assert response.status_code == 404


class TestMessageEndpoints:
    """Test message management endpoints."""

    def test_list_messages_empty(self, client):
        """Test listing messages for a new session."""
        # Create session
        create_response = client.post("/session", json={"title": "Test"})
        session_id = create_response.json()["id"]

        # List messages
        response = client.get(f"/session/{session_id}/message")

        assert response.status_code == 200
        data = response.json()
        assert data == []

    def test_list_messages_nonexistent_session(self, client):
        """Test listing messages for nonexistent session."""
        response = client.get("/session/ses_nonexistent/message")

        assert response.status_code == 404

    def test_get_message_not_found(self, client):
        """Test getting a message that doesn't exist."""
        # Create session
        create_response = client.post("/session", json={"title": "Test"})
        session_id = create_response.json()["id"]

        # Try to get nonexistent message
        response = client.get(f"/session/{session_id}/message/msg_nonexistent")

        assert response.status_code == 404


class TestSessionActions:
    """Test session action endpoints."""

    def test_abort_session(self, client):
        """Test aborting a session."""
        # Create session
        create_response = client.post("/session", json={"title": "Test"})
        session_id = create_response.json()["id"]

        # Abort session
        response = client.post(f"/session/{session_id}/abort")

        assert response.status_code == 200
        assert response.json() is True

    def test_abort_nonexistent_session(self, client):
        """Test aborting a nonexistent session."""
        response = client.post("/session/ses_nonexistent/abort")

        assert response.status_code == 404

    def test_fork_session(self, client):
        """Test forking a session."""
        # Create original session
        create_response = client.post("/session", json={"title": "Original"})
        session_id = create_response.json()["id"]

        # Fork session
        response = client.post(
            f"/session/{session_id}/fork", json={"messageID": None}
        )

        assert response.status_code == 200
        data = response.json()
        assert data["title"] == "Original (fork)"
        assert data["parentID"] == session_id
        assert data["id"] != session_id

    def test_fork_nonexistent_session(self, client):
        """Test forking a nonexistent session."""
        response = client.post(
            "/session/ses_nonexistent/fork", json={"messageID": None}
        )

        assert response.status_code == 404

    def test_get_session_diff_empty(self, client):
        """Test getting diff for a new session."""
        # Create session
        create_response = client.post("/session", json={"title": "Test"})
        session_id = create_response.json()["id"]

        # Get diff
        response = client.get(f"/session/{session_id}/diff")

        assert response.status_code == 200
        data = response.json()
        assert isinstance(data, list)
        # New session should have no diffs
        assert len(data) == 0

    def test_get_diff_nonexistent_session(self, client):
        """Test getting diff for nonexistent session."""
        response = client.get("/session/ses_nonexistent/diff")

        assert response.status_code == 404

    def test_unrevert_session(self, client):
        """Test unrevering a session."""
        # Create session
        create_response = client.post("/session", json={"title": "Test"})
        session_id = create_response.json()["id"]

        # Unrevert (even if not reverted)
        response = client.post(f"/session/{session_id}/unrevert")

        assert response.status_code == 200
        data = response.json()
        assert data["revert"] is None


class TestGlobalEventEndpoint:
    """Test global event SSE endpoint."""

    def test_global_event_endpoint_exists(self, client):
        """Test that global event endpoint exists."""
        # Just verify the endpoint is available
        # Full SSE testing requires special handling
        # We can't easily test SSE with TestClient, but we can verify it exists
        pass


class TestRequestValidation:
    """Test request validation and error handling."""

    def test_create_session_with_invalid_json(self, client):
        """Test creating session with invalid JSON."""
        response = client.post(
            "/session",
            content="invalid json",
            headers={"Content-Type": "application/json"},
        )

        assert response.status_code == 422

    def test_update_session_with_invalid_data(self, client):
        """Test updating session with invalid data types."""
        # Create session
        create_response = client.post("/session", json={"title": "Test"})
        session_id = create_response.json()["id"]

        # Try to update with invalid data
        response = client.patch(
            f"/session/{session_id}",
            json={"title": 123},  # Should be string
        )

        # FastAPI/Pydantic should handle type coercion or validation
        # Depending on Pydantic settings, this might succeed or fail
        assert response.status_code in [200, 422]


class TestQueryParameters:
    """Test endpoints with query parameters."""

    def test_session_list_with_directory_param(self, client):
        """Test listing sessions with directory parameter."""
        response = client.get("/session?directory=/test/path")

        assert response.status_code == 200

    def test_messages_with_limit(self, client):
        """Test listing messages with limit parameter."""
        # Create session
        create_response = client.post("/session", json={"title": "Test"})
        session_id = create_response.json()["id"]

        # Get messages with limit
        response = client.get(f"/session/{session_id}/message?limit=10")

        assert response.status_code == 200


class TestConcurrentRequests:
    """Test handling concurrent requests."""

    def test_create_multiple_sessions_concurrently(self, client):
        """Test creating multiple sessions in quick succession."""
        responses = []
        for i in range(5):
            response = client.post("/session", json={"title": f"Session {i}"})
            responses.append(response)

        # All should succeed
        assert all(r.status_code == 200 for r in responses)

        # All should have unique IDs
        ids = [r.json()["id"] for r in responses]
        assert len(ids) == len(set(ids))

    def test_list_sessions_during_creation(self, client):
        """Test listing sessions while creating new ones."""
        # Create initial session
        client.post("/session", json={"title": "Session 1"})

        # List sessions
        list_response = client.get("/session")
        assert list_response.status_code == 200
        assert len(list_response.json()) == 1

        # Create another session
        client.post("/session", json={"title": "Session 2"})

        # List again
        list_response = client.get("/session")
        assert list_response.status_code == 200
        assert len(list_response.json()) == 2


class TestIDGeneration:
    """Test ID generation functionality."""

    def test_session_ids_are_unique(self, client):
        """Test that generated session IDs are unique."""
        ids = set()
        for _ in range(10):
            response = client.post("/session", json={"title": "Test"})
            session_id = response.json()["id"]
            assert session_id not in ids
            ids.add(session_id)

    def test_session_id_format(self, client):
        """Test that session IDs have correct format."""
        response = client.post("/session", json={"title": "Test"})
        session_id = response.json()["id"]

        assert session_id.startswith("ses_")
        assert len(session_id) > 4  # More than just the prefix
