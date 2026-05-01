"""
E2E tests for shell command execution.
"""
import pytest

from .conftest import assert_file_contains, collect_sse_response


@pytest.mark.slow
@pytest.mark.requires_api_key
class TestShellExecution:
    """Test shell command execution."""

    @pytest.mark.asyncio
    async def test_echo_command(self, e2e_client, e2e_temp_dir):
        """Agent executes echo and returns output."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test Shell",
            },
        )
        session_id = session_resp.json()["id"]

        # Unique marker to verify execution
        marker = "E2E_TEST_MARKER_12345"
        prompt = f"""Run this exact shell command: echo '{marker}'
Tell me what the command output was."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        combined = collector.final_text + str(collector.tool_results)
        assert marker in combined

    @pytest.mark.asyncio
    async def test_command_with_file_output(self, e2e_client, e2e_temp_dir):
        """Agent runs command that creates file."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test Shell File",
            },
        )
        session_id = session_resp.json()["id"]

        target_file = e2e_temp_dir / "shell_output.txt"
        content = "SHELL_CREATED_CONTENT"

        prompt = f"""Run this exact shell command:
echo '{content}' > {target_file}

Do not add any other commands."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        assert len(collector.errors) == 0

        # Verify file was created
        assert target_file.exists()
        assert_file_contains(target_file, content)

    @pytest.mark.asyncio
    async def test_pwd_command(self, e2e_client, e2e_temp_dir):
        """Agent reports working directory correctly."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test PWD",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = """Run the 'pwd' command and tell me the current directory path."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        # The output should contain some path
        combined = collector.final_text + str(collector.tool_results)
        # Should have a path-like output (contains /)
        assert "/" in combined

    @pytest.mark.asyncio
    async def test_ls_command(self, e2e_client, multi_file_fixture, e2e_temp_dir):
        """Agent runs ls and lists files."""
        session_resp = await e2e_client.post(
            "/session",
            json={
                "title": "Test LS",
            },
        )
        session_id = session_resp.json()["id"]

        prompt = f"""Run: ls {e2e_temp_dir}
Tell me what files you see."""

        async with e2e_client.stream(
            "POST",
            f"/session/{session_id}/message",
            json={"parts": [{"type": "text", "text": prompt}]},
        ) as response:
            collector = await collect_sse_response(response)

        combined = collector.final_text + str(collector.tool_results)
        # Should see at least one of the fixture files
        assert "file1.txt" in combined or "file2.txt" in combined or "code.py" in combined
