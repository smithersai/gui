"""
E2E tests for session management: create, fork, revert, delete.
"""
import pytest

from .conftest import collect_sse_response


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestSessionCreate:
    """Test session creation."""

    @pytest.mark.asyncio
    async def test_create_session_and_send_message(
        self, e2e_client, fixture_file, e2e_temp_dir
    ):
        """Create session and send a message successfully."""
        # Create session
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "E2E Session",
            },
        )
        assert session_resp.status_code == 200
        session = session_resp.json()
        assert session["id"].startswith("ses_")

        # Send a simple message
        prompt = f"Read {fixture_file} and tell me what it contains."
        async with e2e_client.stream(
            "POST",
            f"/session/{session['id']}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        assert len(collector.errors) == 0
        # Should have some response
        assert len(collector.events) > 0


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestSessionFork:
    """Test session forking functionality."""

    @pytest.mark.asyncio
    async def test_fork_preserves_history(self, e2e_client, fixture_file, e2e_temp_dir):
        """Forked session preserves message history."""
        # Create original session
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Original",
            },
        )
        session_id = session_resp.json()["id"]

        # Send a message
        prompt = f"Read the file {fixture_file} and tell me its content."
        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            await collect_sse_response(response)

        # Fork the session
        fork_resp = await e2e_client.post(
            f"/session/{session_id}/fork",
            json={"messageID": None},
        )
        assert fork_resp.status_code == 200
        forked_session = fork_resp.json()

        assert forked_session["parentID"] == session_id
        assert "(fork)" in forked_session["title"]

        # Verify forked session has messages
        messages_resp = await e2e_client.get(f"/session/{forked_session['id']}/message")
        assert len(messages_resp.json()) > 0


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestSessionRevert:
    """Test session revert functionality."""

    @pytest.mark.asyncio
    async def test_revert_sets_revert_info(self, e2e_client, fixture_file, e2e_temp_dir):
        """Reverting session sets revert metadata."""
        # Create session
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Revert Test",
            },
        )
        session_id = session_resp.json()["id"]

        # Send first message
        prompt1 = f"Read {fixture_file}"
        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt1}]},
        ) as response:
            await collect_sse_response(response)

        # Get the first message ID for revert
        messages_resp = await e2e_client.get(f"/session/{session_id}/message")
        messages = messages_resp.json()
        assert len(messages) >= 1
        first_msg_id = messages[0]["info"]["id"]

        # Send second message
        prompt2 = "What is 2 + 2?"
        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt2}]},
        ) as response:
            await collect_sse_response(response)

        # Revert to first message
        revert_resp = await e2e_client.post(
            f"/session/{session_id}/revert",
            json={"messageID": first_msg_id},
        )
        assert revert_resp.status_code == 200

        # Session should have revert info
        session = revert_resp.json()
        assert session["revert"] is not None
        assert session["revert"]["messageID"] == first_msg_id


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestSessionDelete:
    """Test session deletion."""

    @pytest.mark.asyncio
    async def test_delete_session(self, e2e_client, e2e_temp_dir):
        """Deleting session removes it completely."""
        # Create session
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Delete Test",
            },
        )
        session_id = session_resp.json()["id"]

        # Send a message to make it non-empty
        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": "Hello"}]},
        ) as response:
            await collect_sse_response(response)

        # Delete it
        delete_resp = await e2e_client.delete(f"/session/{session_id}")
        assert delete_resp.status_code == 200

        # Verify it's gone
        get_resp = await e2e_client.get(f"/session/{session_id}")
        assert get_resp.status_code == 404


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestSessionUnrevert:
    """Test session unrevert functionality."""

    @pytest.mark.asyncio
    async def test_unrevert_clears_revert_info(self, e2e_client, fixture_file, e2e_temp_dir):
        """Unreverting session clears revert metadata."""
        # Create session
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Unrevert Test",
            },
        )
        session_id = session_resp.json()["id"]

        # Send message
        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": f"Read {fixture_file}"}]},
        ) as response:
            await collect_sse_response(response)

        # Get message ID
        messages_resp = await e2e_client.get(f"/session/{session_id}/message")
        first_msg_id = messages_resp.json()[0]["info"]["id"]

        # Revert
        await e2e_client.post(
            f"/session/{session_id}/revert",
            json={"messageID": first_msg_id},
        )

        # Unrevert
        unrevert_resp = await e2e_client.post(f"/session/{session_id}/unrevert")
        assert unrevert_resp.status_code == 200

        session = unrevert_resp.json()
        assert session["revert"] is None
