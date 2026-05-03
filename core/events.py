"""Event types and EventBus protocol."""

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Protocol


def _dump_value(value: Any) -> Any:
    if isinstance(value, Enum):
        return value.value
    if hasattr(value, "model_dump"):
        return value.model_dump()
    if isinstance(value, dict):
        return {key: _dump_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_dump_value(item) for item in value]
    if isinstance(value, tuple):
        return [_dump_value(item) for item in value]
    return value


@dataclass
class Event:
    """Domain event that can be published to subscribers."""

    type: str
    properties: dict[str, Any] = field(default_factory=dict)

    def model_dump(self) -> dict[str, Any]:
        """Return a JSON-ready event payload."""
        return {
            "type": self.type,
            "properties": _dump_value(self.properties),
        }


# Event type constants for task delegation
TASK_STARTED = "task.started"
TASK_COMPLETED = "task.completed"
TASK_FAILED = "task.failed"
TASK_TIMEOUT = "task.timeout"
TASK_CANCELLED = "task.cancelled"


class EventBus(Protocol):
    """Abstract interface for publishing events."""

    async def publish(self, event: Event) -> None:
        """Publish an event to all subscribers."""
        ...


class NullEventBus:
    """No-op EventBus implementation for testing."""

    async def publish(self, event: Event) -> None:
        """Discard the event."""
        return None
