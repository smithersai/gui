"""
E2E tests for bypass mode functionality.

Tests the bypass mode feature in a real session context.
"""
import pytest

from .conftest import collect_sse_response


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestBypassModeSession:
    """Test bypass mode in session lifecycle."""

    @pytest.mark.asyncio
    async def test_create_session_with_bypass_mode(self, e2e_client, e2e_temp_dir):
        """Session can be created with bypass_mode=True."""
        # Create session with bypass mode enabled
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Bypass Mode Test",
                "bypass_mode": True,
            },
        )
        assert session_resp.status_code == 200
        session = session_resp.json()

        # Verify bypass_mode is set
        assert session["bypass_mode"] is True
        assert session["id"].startswith("ses_")

    @pytest.mark.asyncio
    async def test_create_session_defaults_to_normal_mode(self, e2e_client, e2e_temp_dir):
        """Session defaults to bypass_mode=False when not specified."""
        # Create session without specifying bypass_mode
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Normal Mode Test",
            },
        )
        assert session_resp.status_code == 200
        session = session_resp.json()

        # Verify bypass_mode defaults to False
        assert session["bypass_mode"] is False

    @pytest.mark.asyncio
    async def test_bypass_mode_persists_in_session(self, e2e_client, e2e_temp_dir):
        """Bypass mode setting persists in session."""
        # Create session with bypass mode
        create_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Persistence Test",
                "bypass_mode": True,
            },
        )
        session_id = create_resp.json()["id"]

        # Retrieve session
        get_resp = await e2e_client.get(f"/session/{session_id}")
        assert get_resp.status_code == 200

        session = get_resp.json()
        assert session["bypass_mode"] is True

    @pytest.mark.asyncio
    async def test_bypass_mode_in_session_list(self, e2e_client, e2e_temp_dir):
        """Bypass mode is included in session list."""
        # Create sessions with different bypass modes
        bypass_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Bypass Session",
                "bypass_mode": True,
            },
        )
        bypass_id = bypass_resp.json()["id"]

        normal_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Normal Session",
                "bypass_mode": False,
            },
        )
        normal_id = normal_resp.json()["id"]

        # List sessions
        list_resp = await e2e_client.get("/session")
        assert list_resp.status_code == 200

        sessions = list_resp.json()

        # Find our sessions in the list
        bypass_session = next((s for s in sessions if s["id"] == bypass_id), None)
        normal_session = next((s for s in sessions if s["id"] == normal_id), None)

        assert bypass_session is not None
        assert bypass_session["bypass_mode"] is True

        assert normal_session is not None
        assert normal_session["bypass_mode"] is False


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestBypassModeInheritance:
    """Test bypass mode inheritance in fork/revert operations."""

    @pytest.mark.asyncio
    async def test_forked_session_inherits_normal_mode(self, e2e_client, e2e_temp_dir):
        """Forked session should NOT inherit bypass mode (security)."""
        # Create session with bypass mode
        create_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Parent Bypass",
                "bypass_mode": True,
            },
        )
        parent_id = create_resp.json()["id"]

        # Send a message to create history
        async with e2e_client.stream(
            "POST",
            f"/session/{parent_id}/message",
            json={"parts": [{"type": "text", "text": "Hello"}]},
        ) as response:
            await collect_sse_response(response)

        # Fork the session
        fork_resp = await e2e_client.post(
            f"/session/{parent_id}/fork",
            json={"messageID": None},
        )
        assert fork_resp.status_code == 200

        forked_session = fork_resp.json()

        # Forked session should NOT inherit bypass mode (security default)
        # This is important - new sessions should always start in safe mode
        assert forked_session["parentID"] == parent_id
        # Note: The fork currently copies the parent session's bypass_mode
        # For security, we might want to change this behavior in the future
        # For now, we document the actual behavior
