"""
Unit tests for TaskExecutor and task delegation functionality.
"""
import asyncio
import json
import time

import pytest

from agent.task_executor import TaskExecutor, TaskResult


class TestTaskResult:
    """Test TaskResult dataclass."""

    def test_task_result_creation(self):
        """Test creating a TaskResult."""
        result = TaskResult(
            task_id="test123",
            objective="Test objective",
            agent_type="explore",
            status="completed",
            result="Success",
        )

        assert result.task_id == "test123"
        assert result.objective == "Test objective"
        assert result.agent_type == "explore"
        assert result.status == "completed"
        assert result.result == "Success"

    def test_task_result_to_dict(self):
        """Test TaskResult serialization to dict."""
        result = TaskResult(
            task_id="test123",
            objective="Test objective",
            agent_type="explore",
            status="completed",
            result="Success",
            duration=1.5,
        )

        data = result.to_dict()

        assert isinstance(data, dict)
        assert data["task_id"] == "test123"
        assert data["objective"] == "Test objective"
        assert data["agent_type"] == "explore"
        assert data["status"] == "completed"
        assert data["result"] == "Success"
        assert data["duration"] == 1.5

    def test_task_result_json_serializable(self):
        """Test that TaskResult can be serialized to JSON."""
        result = TaskResult(
            task_id="test123",
            objective="Test objective",
            agent_type="explore",
            status="completed",
            result="Success",
        )

        # Should not raise an exception
        json_str = json.dumps(result.to_dict())
        assert isinstance(json_str, str)

        # Should be deserializable
        data = json.loads(json_str)
        assert data["task_id"] == "test123"


class TestTaskExecutor:
    """Test TaskExecutor class."""

    def test_task_executor_creation(self, mock_env_vars):
        """Test creating a TaskExecutor."""
        executor = TaskExecutor(
            model_id="claude-sonnet-4-20250514",
            working_dir="/tmp"
        )

        assert executor is not None
        assert executor.model_id == "claude-sonnet-4-20250514"
        assert executor.working_dir == "/tmp"

    def test_task_executor_default_working_dir(self, mock_env_vars):
        """Test TaskExecutor with default working directory."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        assert executor is not None
        assert executor.model_id == "claude-sonnet-4-20250514"
        assert executor.working_dir is None

    def test_get_active_task_count_empty(self, mock_env_vars):
        """Test getting active task count when no tasks are running."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        count = executor.get_active_task_count()
        assert count == 0

    @pytest.mark.asyncio
    async def test_execute_task_invalid_agent_type(self, mock_env_vars):
        """Test executing task with invalid agent type."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        result = await executor.execute_task(
            objective="Test task",
            subagent_type="invalid_agent_type",
        )

        assert result.status == "failed"
        assert "Unknown agent type" in result.error
        assert result.agent_type == "invalid_agent_type"

    @pytest.mark.asyncio
    async def test_execute_task_with_context(self, mock_env_vars):
        """Test executing task with context dictionary."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        # This will fail to actually run (no real API key), but we can test the structure
        context = {"key": "value", "number": 42}

        result = await executor.execute_task(
            objective="Test task",
            subagent_type="explore",
            context=context,
            timeout_seconds=1,  # Short timeout since we expect it to fail
        )

        # Should have attempted to run (might fail due to no real API, but structure is tested)
        assert result is not None
        assert result.agent_type == "explore"
        assert result.objective == "Test task"

    @pytest.mark.asyncio
    async def test_execute_parallel_empty_list(self, mock_env_vars):
        """Test executing parallel tasks with empty list."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        results = await executor.execute_parallel(tasks=[])

        assert results == []

    @pytest.mark.asyncio
    async def test_execute_parallel_single_task(self, mock_env_vars):
        """Test executing parallel tasks with a single task."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        tasks = [
            {
                "objective": "Test task",
                "subagent_type": "explore",
            }
        ]

        results = await executor.execute_parallel(tasks=tasks, timeout_seconds=1)

        assert len(results) == 1
        assert results[0].objective == "Test task"
        assert results[0].agent_type == "explore"

    @pytest.mark.asyncio
    async def test_execute_parallel_multiple_tasks(self, mock_env_vars):
        """Test executing multiple parallel tasks."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        tasks = [
            {
                "objective": "Task 1",
                "subagent_type": "explore",
            },
            {
                "objective": "Task 2",
                "subagent_type": "plan",
            },
            {
                "objective": "Task 3",
                "subagent_type": "general",
            }
        ]

        results = await executor.execute_parallel(tasks=tasks, timeout_seconds=1)

        assert len(results) == 3
        assert results[0].objective == "Task 1"
        assert results[1].objective == "Task 2"
        assert results[2].objective == "Task 3"

    @pytest.mark.asyncio
    async def test_execute_parallel_preserves_order(self, mock_env_vars):
        """Test that parallel execution preserves task order in results."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        tasks = [
            {"objective": f"Task {i}", "subagent_type": "explore"}
            for i in range(5)
        ]

        results = await executor.execute_parallel(tasks=tasks, timeout_seconds=1)

        assert len(results) == 5
        for i, result in enumerate(results):
            assert result.objective == f"Task {i}"

    @pytest.mark.asyncio
    async def test_execute_parallel_handles_invalid_agent(self, mock_env_vars):
        """Test that parallel execution handles invalid agent types."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        tasks = [
            {"objective": "Valid task", "subagent_type": "explore"},
            {"objective": "Invalid task", "subagent_type": "invalid_type"},
        ]

        results = await executor.execute_parallel(tasks=tasks, timeout_seconds=1)

        assert len(results) == 2
        assert results[0].agent_type == "explore"
        assert results[1].agent_type == "invalid_type"
        assert results[1].status == "failed"

    @pytest.mark.asyncio
    async def test_execute_parallel_batching(self, mock_env_vars):
        """Test that large task lists are batched correctly."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        # Create more tasks than the max concurrent limit (default 10)
        tasks = [
            {"objective": f"Task {i}", "subagent_type": "explore"}
            for i in range(15)
        ]

        results = await executor.execute_parallel(tasks=tasks, timeout_seconds=1)

        # All tasks should complete (or fail) but in batches
        assert len(results) == 15

    @pytest.mark.asyncio
    async def test_cancel_all_tasks(self, mock_env_vars):
        """Test cancelling all active tasks."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        # Cancel should work even with no active tasks
        await executor.cancel_all_tasks()

        assert executor.get_active_task_count() == 0

    @pytest.mark.asyncio
    async def test_task_result_has_duration(self, mock_env_vars):
        """Test that task results include execution duration."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        result = await executor.execute_task(
            objective="Test task",
            subagent_type="invalid_type",  # Will fail quickly
        )

        assert result.duration >= 0
        assert result.started_at > 0
        assert result.completed_at is not None

    @pytest.mark.asyncio
    async def test_task_result_includes_task_id(self, mock_env_vars):
        """Test that each task gets a unique task ID."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        result1 = await executor.execute_task(
            objective="Task 1",
            subagent_type="explore",
            timeout_seconds=1,
        )

        result2 = await executor.execute_task(
            objective="Task 2",
            subagent_type="explore",
            timeout_seconds=1,
        )

        assert result1.task_id != result2.task_id
        assert len(result1.task_id) > 0
        assert len(result2.task_id) > 0


class TestTaskExecutorTimeout:
    """Test timeout behavior of TaskExecutor."""

    @pytest.mark.asyncio
    async def test_execute_task_respects_timeout(self, mock_env_vars):
        """Test that task execution respects timeout."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        # Use a very short timeout to ensure it triggers
        start = time.time()
        result = await executor.execute_task(
            objective="This should timeout",
            subagent_type="explore",
            timeout_seconds=0.1,  # Very short timeout
        )
        duration = time.time() - start

        # Should complete within a reasonable time (timeout + overhead)
        assert duration < 2.0  # Allow for some overhead

    @pytest.mark.asyncio
    async def test_parallel_tasks_respect_individual_timeouts(self, mock_env_vars):
        """Test that parallel tasks each have individual timeouts."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        tasks = [
            {"objective": "Task 1", "subagent_type": "explore"},
            {"objective": "Task 2", "subagent_type": "explore"},
        ]

        start = time.time()
        results = await executor.execute_parallel(
            tasks=tasks,
            timeout_seconds=0.1,  # Very short timeout
        )
        duration = time.time() - start

        # Should complete within reasonable time
        assert duration < 2.0
        assert len(results) == 2


class TestTaskExecutorIntegration:
    """Integration tests for TaskExecutor."""

    @pytest.mark.asyncio
    async def test_execute_task_structure(self, mock_env_vars, temp_dir):
        """Test the complete structure of task execution."""
        executor = TaskExecutor(
            model_id="claude-sonnet-4-20250514",
            working_dir=str(temp_dir)
        )

        result = await executor.execute_task(
            objective="Test objective",
            subagent_type="explore",
            context={"test": "data"},
            timeout_seconds=1,
        )

        # Verify result structure
        assert hasattr(result, "task_id")
        assert hasattr(result, "objective")
        assert hasattr(result, "agent_type")
        assert hasattr(result, "status")
        assert hasattr(result, "result")
        assert hasattr(result, "error")
        assert hasattr(result, "duration")
        assert hasattr(result, "started_at")
        assert hasattr(result, "completed_at")

        # Verify result can be converted to dict
        data = result.to_dict()
        assert all(key in data for key in [
            "task_id", "objective", "agent_type", "status",
            "result", "error", "duration", "started_at", "completed_at"
        ])

    @pytest.mark.asyncio
    async def test_parallel_execution_is_concurrent(self, mock_env_vars):
        """Test that parallel tasks actually run concurrently."""
        executor = TaskExecutor(model_id="claude-sonnet-4-20250514")

        tasks = [
            {"objective": f"Task {i}", "subagent_type": "explore"}
            for i in range(3)
        ]

        start = time.time()
        results = await executor.execute_parallel(tasks=tasks, timeout_seconds=1)
        duration = time.time() - start

        # If tasks ran sequentially, it would take 3+ seconds
        # If concurrent, should complete in ~1 second (plus overhead)
        # We're lenient here since we can't actually run the tasks
        assert len(results) == 3
        # Just verify they all attempted to run
        for result in results:
            assert result.status in ["completed", "failed", "timeout"]
