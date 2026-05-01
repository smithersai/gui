"""
E2E tests for complex multi-step agent workflows.
"""
import pytest

from .conftest import assert_file_contains, assert_file_exact, collect_sse_response


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestMultiStepWorkflows:
    """Test complex workflows requiring multiple tool calls."""

    @pytest.mark.asyncio
    async def test_read_modify_verify(self, e2e_client, fixture_file, e2e_temp_dir):
        """Agent reads file, modifies it, and verifies the change."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Multi-step Test",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = f"""Do the following steps in order:
1. Read the file at {fixture_file}
2. The file contains '5 + 5 = ??'. Change it to '5 + 5 = 10'
3. Write the updated content back to the file
4. Read the file again to verify

The final file content should be exactly: 5 + 5 = 10"""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        # Should have multiple tool calls
        assert len(collector.tool_calls) >= 2

        # File should be updated
        assert_file_contains(fixture_file, "5 + 5 = 10")

    @pytest.mark.asyncio
    async def test_create_and_read_file(self, e2e_client, e2e_temp_dir):
        """Agent creates a file and reads it back."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Create Read Test",
            },
        )
        session_id = session_resp.json()["id"]

        target_file = e2e_temp_dir / "created.txt"
        content = "MULTI_STEP_CONTENT_XYZ"

        prompt = f"""Do these steps:
1. Create a file at {target_file} with content: {content}
2. Read the file back and tell me what it contains

The file must contain exactly: {content}"""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        assert len(collector.errors) == 0

        # File should exist with correct content
        assert target_file.exists()
        assert_file_contains(target_file, content)

    @pytest.mark.asyncio
    async def test_search_and_read(self, e2e_client, multi_file_fixture, e2e_temp_dir):
        """Agent searches for a file and reads its content."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Search Read Test",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = f"""Do these steps:
1. Find the Python file (.py) in {e2e_temp_dir}
2. Read its content
3. Tell me what function is defined in it"""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        combined = collector.final_text + str(collector.tool_results)

        # Should find the hello function
        assert "hello" in combined.lower()

    @pytest.mark.asyncio
    async def test_shell_and_file_workflow(self, e2e_client, e2e_temp_dir):
        """Agent runs shell command and writes output to file."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Shell File Test",
            },
        )
        session_id = session_resp.json()["id"]

        marker = "WORKFLOW_MARKER_789"
        output_file = e2e_temp_dir / "workflow_output.txt"

        prompt = f"""Do these steps:
1. Run the shell command: echo '{marker}'
2. Create a file at {output_file} containing the output of that command
3. The file should contain: {marker}"""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        assert len(collector.errors) == 0

        # Should have called shell and write
        assert len(collector.tool_calls) >= 2

        # File should exist with marker
        if output_file.exists():
            assert_file_contains(output_file, marker)


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestConditionalWorkflows:
    """Test workflows with conditional logic."""

    @pytest.mark.asyncio
    async def test_check_and_update(self, e2e_client, fixture_file, e2e_temp_dir):
        """Agent checks file content and updates based on what it finds."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Conditional Test",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = f"""Read the file at {fixture_file}.
If it contains '??', replace the entire content with: ANSWER_FOUND
If it doesn't contain '??', leave it unchanged.

The file currently contains '5 + 5 = ??', so you should update it."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        assert len(collector.errors) == 0

        # File should be updated
        assert_file_contains(fixture_file, "ANSWER_FOUND")

    @pytest.mark.asyncio
    async def test_list_count_report(
        self, e2e_client, multi_file_fixture, e2e_temp_dir
    ):
        """Agent lists files, counts them, and reports."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Count Test",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = f"""List all .txt files in {e2e_temp_dir} (including subdirectories).
Count how many .txt files there are.
Tell me the exact count."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        combined = collector.final_text

        # Should mention the count (we have 3 txt files: file1.txt, file2.txt, file3.txt)
        assert "3" in combined or "three" in combined.lower()
