"""
E2E tests for file operation tools.
Tests: read_file, write_file, list_directory
"""
import pytest

from .conftest import assert_file_contains, assert_file_exact, collect_sse_response


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestFileRead:
    """Test file reading capabilities."""

    @pytest.mark.asyncio
    async def test_read_known_file(self, e2e_client, fixture_file, e2e_temp_dir):
        """Agent reads a file and reports its exact content."""
        # Create session
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test Read",
            },
        )
        session_id = session_resp.json()["id"]

        # Send specific prompt
        prompt = f"""Read the file at {fixture_file}.
Reply with ONLY the exact file content, nothing else.
No explanations, no formatting, just the raw content."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        # Assert tool was called and content returned
        assert len(collector.errors) == 0
        # Either in final text or tool results
        combined = collector.final_text + str(collector.tool_results)
        assert "5 + 5 = ??" in combined


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestFileWrite:
    """Test file writing capabilities."""

    @pytest.mark.asyncio
    async def test_update_file_arithmetic(self, e2e_client, fixture_file, e2e_temp_dir):
        """Agent updates file: replace '5 + 5 = ??' with '5 + 5 = 10'."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test Write",
            },
        )
        session_id = session_resp.json()["id"]

        # Very specific, deterministic prompt
        prompt = f"""Update the file at {fixture_file}.
Replace the ENTIRE content with exactly: 5 + 5 = 10
Do not add any other content, newlines, or formatting.
The file should contain ONLY the text: 5 + 5 = 10"""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        assert len(collector.errors) == 0

        # Assert file was updated correctly
        assert_file_exact(fixture_file, "5 + 5 = 10")

    @pytest.mark.asyncio
    async def test_create_new_file(self, e2e_client, e2e_temp_dir):
        """Agent creates a new file with specific content."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test Create",
            },
        )
        session_id = session_resp.json()["id"]

        target_file = e2e_temp_dir / "new_file.txt"
        expected_content = "CREATED_BY_AGENT"

        prompt = f"""Create a new file at {target_file}.
The file content must be exactly: {expected_content}
No extra text, no newlines, no formatting.
Just the exact text: {expected_content}"""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        assert len(collector.errors) == 0

        assert target_file.exists()
        assert_file_contains(target_file, expected_content)


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestListDirectory:
    """Test directory listing capabilities."""

    @pytest.mark.asyncio
    async def test_list_files_in_directory(
        self, e2e_client, multi_file_fixture, e2e_temp_dir
    ):
        """Agent lists files and returns specific file names."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test List",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = f"""List all files in {e2e_temp_dir}.
Tell me the names of all files you find.
Include file1.txt, file2.txt, and code.py in your response if they exist."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        # Check that expected files are mentioned
        combined_output = collector.final_text + str(collector.tool_results)
        assert "file1.txt" in combined_output
        assert "file2.txt" in combined_output
        assert "code.py" in combined_output
