"""
E2E tests for todowrite and todoread tools.
"""
import pytest

from .conftest import collect_sse_response


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestTodoWrite:
    """Test todowrite functionality."""

    @pytest.mark.asyncio
    async def test_create_todo_list(self, e2e_client, e2e_temp_dir):
        """Agent creates a todo list with specific items."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Todo Test",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = """Create a todo list with exactly these 3 items:
1. 'Write tests' with status 'pending'
2. 'Review code' with status 'in_progress'
3. 'Deploy' with status 'completed'

Use the todowrite tool to save this list."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        assert len(collector.errors) == 0

        # Verify todowrite was called
        tool_names = [tc["tool"] for tc in collector.tool_calls]
        assert "todowrite" in tool_names

    @pytest.mark.asyncio
    async def test_create_single_todo(self, e2e_client, e2e_temp_dir):
        """Agent creates a single todo item."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Single Todo Test",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = """Create a todo list with exactly one item:
- content: 'Test item'
- status: 'pending'
- activeForm: 'Testing item'

Use the todowrite tool."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        tool_names = [tc["tool"] for tc in collector.tool_calls]
        assert "todowrite" in tool_names


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestTodoRead:
    """Test todoread functionality."""

    @pytest.mark.asyncio
    async def test_read_todo_list(self, e2e_client, e2e_temp_dir):
        """Agent reads back the todo list it created."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Todo Read Test",
            },
        )
        session_id = session_resp.json()["id"]

        # First create todos
        create_prompt = """Create a todo list with one item:
- content: 'Read me back'
- status: 'pending'

Use the todowrite tool."""
        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": create_prompt}]},
        ) as response:
            await collect_sse_response(response)

        # Then read them back
        read_prompt = """Read the current todo list using the todoread tool.
Tell me what items are in it."""
        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": read_prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        tool_names = [tc["tool"] for tc in collector.tool_calls]
        assert "todoread" in tool_names

    @pytest.mark.asyncio
    async def test_read_empty_todo_list(self, e2e_client, e2e_temp_dir):
        """Agent reads an empty todo list."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Empty Todo Test",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = """Read the current todo list using the todoread tool.
Tell me if there are any items."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        # Should call todoread even for empty list
        tool_names = [tc["tool"] for tc in collector.tool_calls]
        assert "todoread" in tool_names
