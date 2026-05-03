"""
Task executor for managing sub-agent delegation and parallel execution.
"""
from __future__ import annotations

import asyncio
import json
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, TYPE_CHECKING

from .registry import get_agent_config

if TYPE_CHECKING:
    from .agent import create_agent_with_mcp

# Constants
DEFAULT_TIMEOUT_SECONDS = 120
MAX_CONCURRENT_TASKS = 10


@dataclass
class TaskResult:
    """Result from a sub-agent task execution."""

    task_id: str
    objective: str
    agent_type: str
    status: str  # "completed", "failed", "timeout", "cancelled"
    result: str | None = None
    error: str | None = None
    duration: float = 0.0
    started_at: float = field(default_factory=time.time)
    completed_at: float | None = None

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "task_id": self.task_id,
            "objective": self.objective,
            "agent_type": self.agent_type,
            "status": self.status,
            "result": self.result,
            "error": self.error,
            "duration": self.duration,
            "started_at": self.started_at,
            "completed_at": self.completed_at,
        }


class TaskExecutor:
    """Manages sub-agent task execution and lifecycle."""

    def __init__(self, model_id: str, working_dir: str | None = None):
        """
        Initialize task executor.

        Args:
            model_id: Model identifier for sub-agents
            working_dir: Working directory for file operations
        """
        self.model_id = model_id
        self.working_dir = working_dir
        self._active_tasks: dict[str, asyncio.Task] = {}

    async def execute_task(
        self,
        objective: str,
        subagent_type: str = "general",
        context: dict[str, Any] | None = None,
        timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
    ) -> TaskResult:
        """
        Execute a task with a sub-agent.

        Args:
            objective: Task objective/prompt
            subagent_type: Type of sub-agent to spawn
            context: Optional context dictionary
            timeout_seconds: Execution timeout

        Returns:
            TaskResult with execution details
        """
        # Import at runtime to avoid circular import
        from .agent import create_agent_with_mcp

        task_id = str(uuid.uuid4())[:8]
        task_result = TaskResult(
            task_id=task_id,
            objective=objective,
            agent_type=subagent_type,
            status="running",
        )

        try:
            # Validate agent type exists
            agent_config = get_agent_config(subagent_type)
            if agent_config is None:
                task_result.status = "failed"
                task_result.error = f"Unknown agent type: {subagent_type}"
                task_result.completed_at = time.time()
                task_result.duration = task_result.completed_at - task_result.started_at
                return task_result

            # Execute with timeout
            async with asyncio.timeout(timeout_seconds):
                async with create_agent_with_mcp(
                    model_id=self.model_id,
                    agent_name=subagent_type,
                    working_dir=self.working_dir,
                ) as agent:
                    # Build prompt with context
                    prompt = objective
                    if context:
                        context_str = json.dumps(context, indent=2)
                        prompt = f"{objective}\n\nContext:\n{context_str}"

                    # Run agent
                    result = await agent.run(prompt)

                    task_result.status = "completed"
                    task_result.result = result.data
                    task_result.completed_at = time.time()
                    task_result.duration = task_result.completed_at - task_result.started_at

        except asyncio.TimeoutError:
            task_result.status = "timeout"
            task_result.error = f"Task exceeded timeout of {timeout_seconds}s"
            task_result.completed_at = time.time()
            task_result.duration = task_result.completed_at - task_result.started_at

        except asyncio.CancelledError:
            task_result.status = "cancelled"
            task_result.error = "Task was cancelled"
            task_result.completed_at = time.time()
            task_result.duration = task_result.completed_at - task_result.started_at
            raise  # Re-raise to allow proper cleanup

        except Exception as e:
            task_result.status = "failed"
            task_result.error = str(e)
            task_result.completed_at = time.time()
            task_result.duration = task_result.completed_at - task_result.started_at

        return task_result

    async def execute_parallel(
        self,
        tasks: list[dict[str, Any]],
        timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS,
    ) -> list[TaskResult]:
        """
        Execute multiple tasks in parallel.

        Args:
            tasks: List of task specifications (objective, subagent_type, context)
            timeout_seconds: Timeout for each individual task

        Returns:
            List of TaskResults in same order as input tasks
        """
        # Limit concurrent tasks to prevent resource exhaustion
        if len(tasks) > MAX_CONCURRENT_TASKS:
            # Process in batches
            results = []
            for i in range(0, len(tasks), MAX_CONCURRENT_TASKS):
                batch = tasks[i:i + MAX_CONCURRENT_TASKS]
                batch_results = await self._execute_batch(batch, timeout_seconds)
                results.extend(batch_results)
            return results
        else:
            return await self._execute_batch(tasks, timeout_seconds)

    async def _execute_batch(
        self,
        tasks: list[dict[str, Any]],
        timeout_seconds: int,
    ) -> list[TaskResult]:
        """Execute a batch of tasks in parallel."""
        async_tasks = [
            self.execute_task(
                objective=task["objective"],
                subagent_type=task.get("subagent_type", "general"),
                context=task.get("context"),
                timeout_seconds=timeout_seconds,
            )
            for task in tasks
        ]

        results = await asyncio.gather(*async_tasks, return_exceptions=True)

        # Convert exceptions to failed TaskResults
        final_results = []
        for i, result in enumerate(results):
            if isinstance(result, Exception):
                final_results.append(TaskResult(
                    task_id=str(uuid.uuid4())[:8],
                    objective=tasks[i]["objective"],
                    agent_type=tasks[i].get("subagent_type", "general"),
                    status="failed",
                    error=str(result),
                    completed_at=time.time(),
                ))
            else:
                final_results.append(result)

        return final_results

    def get_active_task_count(self) -> int:
        """Get number of currently active tasks."""
        return len(self._active_tasks)

    async def cancel_all_tasks(self) -> None:
        """Cancel all active tasks."""
        for task in self._active_tasks.values():
            task.cancel()

        # Wait for cancellation to complete
        if self._active_tasks:
            await asyncio.gather(*self._active_tasks.values(), return_exceptions=True)

        self._active_tasks.clear()
