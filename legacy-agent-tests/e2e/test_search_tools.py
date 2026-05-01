"""
E2E tests for search capabilities (grep, glob patterns).
"""
import pytest

from .conftest import collect_sse_response


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestGrepSearch:
    """Test grep/content search capabilities."""

    @pytest.mark.asyncio
    async def test_grep_finds_pattern(self, e2e_client, multi_file_fixture, e2e_temp_dir):
        """Agent finds files containing specific pattern."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test Grep",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = f"""Search for files containing the word 'Hello' in {e2e_temp_dir}.
Tell me which files contain this word."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        combined = collector.final_text + str(collector.tool_results)

        # Should find file1.txt (contains "Hello World")
        assert "file1" in combined.lower() or "file1.txt" in combined

    @pytest.mark.asyncio
    async def test_grep_finds_goodbye(self, e2e_client, multi_file_fixture, e2e_temp_dir):
        """Agent finds file containing 'Goodbye'."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test Grep Goodbye",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = f"""Search for files containing 'Goodbye' in {e2e_temp_dir}.
Which file contains this word?"""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        combined = collector.final_text + str(collector.tool_results)
        # Should find file2.txt
        assert "file2" in combined.lower()


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestGlobPatterns:
    """Test glob pattern file matching."""

    @pytest.mark.asyncio
    async def test_find_python_files(self, e2e_client, multi_file_fixture, e2e_temp_dir):
        """Agent finds files matching *.py pattern."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test Glob",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = f"""Find all Python files (*.py) in {e2e_temp_dir}.
List the names of the Python files you find."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        combined = collector.final_text + str(collector.tool_results)
        assert "code.py" in combined

    @pytest.mark.asyncio
    async def test_find_txt_files(self, e2e_client, multi_file_fixture, e2e_temp_dir):
        """Agent finds all .txt files."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test Glob TXT",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = f"""Find all .txt files in {e2e_temp_dir} and subdirectories.
List each file name you find."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        combined = collector.final_text + str(collector.tool_results)
        # Should find at least file1.txt and file2.txt
        txt_count = combined.count(".txt")
        assert txt_count >= 2, f"Expected at least 2 .txt files, got {txt_count}"

    @pytest.mark.asyncio
    async def test_search_in_subdirectory(
        self, e2e_client, multi_file_fixture, e2e_temp_dir
    ):
        """Agent finds files in subdirectories."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test Subdir Search",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = f"""Find all files in the 'subdir' folder within {e2e_temp_dir}.
List what you find."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        combined = collector.final_text + str(collector.tool_results)
        # Should find file3.txt in subdir
        assert "file3" in combined or "subdir" in combined
