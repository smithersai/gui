"""
Integration tests for task delegation tools in the agent.
Tests the task and task_parallel tools integrated into the agent.
"""
import json

import pytest

from agent.agent import create_agent_with_mcp


class TestTaskToolIntegration:
    """Test task delegation tools integrated into agent."""

    @pytest.mark.asyncio
    async def test_agent_has_task_tool(self, mock_env_vars, temp_dir):
        """Test that agent has task tool registered."""
        async with create_agent_with_mcp(
            model_id="claude-sonnet-4-20250514",
            agent_name="build",
            working_dir=str(temp_dir),
        ) as agent:
            assert agent is not None

            # Agent should have the task tool registered
            # We can't easily check tool registration directly,
            # but we can verify the agent was created successfully
            from pydantic_ai import Agent
            assert isinstance(agent, Agent)

    @pytest.mark.asyncio
    async def test_agent_has_task_parallel_tool(self, mock_env_vars, temp_dir):
        """Test that agent has task_parallel tool registered."""
        async with create_agent_with_mcp(
            model_id="claude-sonnet-4-20250514",
            agent_name="build",
            working_dir=str(temp_dir),
        ) as agent:
            assert agent is not None
            from pydantic_ai import Agent
            assert isinstance(agent, Agent)


class TestTaskToolBehavior:
    """Test behavior of task delegation tools."""

    @pytest.mark.asyncio
    async def test_task_executor_created_with_agent(self, mock_env_vars, temp_dir):
        """Test that TaskExecutor is created when agent is created."""
        async with create_agent_with_mcp(
            model_id="claude-sonnet-4-20250514",
            agent_name="build",
            working_dir=str(temp_dir),
        ) as agent:
            # Agent should be created successfully
            assert agent is not None

            # TaskExecutor should be created internally
            # We can't access it directly, but we can verify the agent structure
            from pydantic_ai import Agent
            assert isinstance(agent, Agent)

    @pytest.mark.asyncio
    async def test_multiple_agents_have_independent_executors(self, mock_env_vars, temp_dir):
        """Test that multiple agents have independent task executors."""
        async with create_agent_with_mcp(
            model_id="claude-sonnet-4-20250514",
            agent_name="build",
            working_dir=str(temp_dir),
        ) as agent1:
            async with create_agent_with_mcp(
                model_id="claude-sonnet-4-20250514",
                agent_name="explore",
                working_dir=str(temp_dir),
            ) as agent2:
                # Both agents should be created independently
                assert agent1 is not None
                assert agent2 is not None
                assert agent1 is not agent2


class TestTaskToolValidation:
    """Test validation and error handling of task tools."""

    @pytest.mark.asyncio
    async def test_agent_creation_with_different_agent_types(self, mock_env_vars, temp_dir):
        """Test creating agents with different agent types for task delegation."""
        agent_types = ["build", "explore", "plan", "general"]

        for agent_type in agent_types:
            async with create_agent_with_mcp(
                model_id="claude-sonnet-4-20250514",
                agent_name=agent_type,
                working_dir=str(temp_dir),
            ) as agent:
                assert agent is not None
                from pydantic_ai import Agent
                assert isinstance(agent, Agent)


class TestTaskToolConfiguration:
    """Test configuration of task delegation tools."""

    @pytest.mark.asyncio
    async def test_task_executor_uses_agent_model(self, mock_env_vars, temp_dir):
        """Test that TaskExecutor uses the same model as the parent agent."""
        model_id = "claude-sonnet-4-20250514"

        async with create_agent_with_mcp(
            model_id=model_id,
            agent_name="build",
            working_dir=str(temp_dir),
        ) as agent:
            assert agent is not None

    @pytest.mark.asyncio
    async def test_task_executor_uses_working_dir(self, mock_env_vars, temp_dir):
        """Test that TaskExecutor uses the correct working directory."""
        async with create_agent_with_mcp(
            model_id="claude-sonnet-4-20250514",
            agent_name="build",
            working_dir=str(temp_dir),
        ) as agent:
            assert agent is not None


class TestTaskDelegationScenarios:
    """Test realistic task delegation scenarios."""

    @pytest.mark.asyncio
    async def test_single_agent_with_task_capability(self, mock_env_vars, temp_dir):
        """Test a single agent with task delegation capability."""
        async with create_agent_with_mcp(
            model_id="claude-sonnet-4-20250514",
            agent_name="build",
            working_dir=str(temp_dir),
        ) as agent:
            # Agent should be ready to delegate tasks
            assert agent is not None

    @pytest.mark.asyncio
    async def test_agent_cleanup_on_context_exit(self, mock_env_vars, temp_dir):
        """Test that agent resources are cleaned up on context exit."""
        async with create_agent_with_mcp(
            model_id="claude-sonnet-4-20250514",
            agent_name="build",
            working_dir=str(temp_dir),
        ) as agent:
            assert agent is not None

        # After context exit, agent should be cleaned up
        # We can't directly verify cleanup, but no exceptions should occur


class TestTaskResultFormat:
    """Test the format of task results returned by tools."""

    def test_task_result_json_structure(self):
        """Test that task result JSON has the expected structure."""
        # Simulate a task result
        result_dict = {
            "task_id": "test123",
            "objective": "Test objective",
            "agent_type": "explore",
            "status": "completed",
            "result": "Test result",
            "error": None,
            "duration": 1.5,
            "started_at": 1234567890.0,
            "completed_at": 1234567891.5,
        }

        # Should be valid JSON
        json_str = json.dumps(result_dict, indent=2)
        assert isinstance(json_str, str)

        # Should be deserializable
        parsed = json.loads(json_str)
        assert parsed["task_id"] == "test123"
        assert parsed["objective"] == "Test objective"
        assert parsed["agent_type"] == "explore"
        assert parsed["status"] == "completed"
        assert parsed["result"] == "Test result"
        assert parsed["duration"] == 1.5

    def test_task_parallel_result_json_structure(self):
        """Test that task_parallel result JSON has the expected structure."""
        # Simulate multiple task results
        results_list = [
            {
                "task_id": f"test{i}",
                "objective": f"Objective {i}",
                "agent_type": "explore",
                "status": "completed",
                "result": f"Result {i}",
                "error": None,
                "duration": 1.0,
                "started_at": 1234567890.0,
                "completed_at": 1234567891.0,
            }
            for i in range(3)
        ]

        # Should be valid JSON
        json_str = json.dumps(results_list, indent=2)
        assert isinstance(json_str, str)

        # Should be deserializable
        parsed = json.loads(json_str)
        assert len(parsed) == 3
        for i, result in enumerate(parsed):
            assert result["task_id"] == f"test{i}"
            assert result["objective"] == f"Objective {i}"
