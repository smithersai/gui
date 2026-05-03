"""Permission system models."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Mapping


class Level(str, Enum):
    """Permission level for operations."""

    ASK = "ask"
    ALLOW = "allow"
    DENY = "deny"


class Action(str, Enum):
    """User action in response to permission request."""

    APPROVE_ONCE = "once"
    APPROVE_ALWAYS = "always"
    DENY = "deny"
    APPROVE_PATTERN = "pattern"


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
class BashPermission:
    """Bash permission configuration with pattern-based rules."""

    default: Level = Level.ASK
    patterns: dict[str, Level] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.default = Level(self.default)
        self.patterns = {
            pattern: Level(level)
            for pattern, level in self.patterns.items()
        }

    def model_dump(self) -> dict[str, Any]:
        """Return a JSON-ready permission payload."""
        return _dump_value({
            "default": self.default,
            "patterns": self.patterns,
        })


@dataclass
class PermissionsConfig:
    """Permission configuration for all tool types."""

    edit: Level = Level.ASK
    bash: BashPermission | Mapping[str, Any] = field(default_factory=BashPermission)
    webfetch: Level = Level.ALLOW

    def __post_init__(self) -> None:
        self.edit = Level(self.edit)
        if not isinstance(self.bash, BashPermission):
            self.bash = BashPermission(**dict(self.bash))
        self.webfetch = Level(self.webfetch)

    def model_dump(self) -> dict[str, Any]:
        """Return a JSON-ready permission config."""
        return _dump_value({
            "edit": self.edit,
            "bash": self.bash,
            "webfetch": self.webfetch,
        })


@dataclass
class Request:
    """Permission request for a sensitive operation."""

    id: str
    session_id: str
    message_id: str
    operation: str  # "bash", "edit", "webfetch"
    details: dict[str, Any]
    call_id: str | None = None
    is_dangerous: bool = False
    warning: str | None = None
    requested_at: float = field(default_factory=time.time)

    def model_dump(self) -> dict[str, Any]:
        """Return a JSON-ready permission request."""
        return _dump_value({
            "id": self.id,
            "session_id": self.session_id,
            "message_id": self.message_id,
            "call_id": self.call_id,
            "operation": self.operation,
            "details": self.details,
            "is_dangerous": self.is_dangerous,
            "warning": self.warning,
            "requested_at": self.requested_at,
        })


@dataclass
class Response:
    """User response to a permission request."""

    request_id: str
    action: Action
    pattern: str | None = None  # For "pattern" action
    created_at: float = field(default_factory=time.time)

    def __post_init__(self) -> None:
        self.action = Action(self.action)

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "Response":
        """Create a response from an untrusted API payload."""
        return cls(
            request_id=str(data["request_id"]),
            action=Action(data["action"]),
            pattern=data.get("pattern"),
            created_at=float(data.get("created_at", time.time())),
        )

    def model_dump(self) -> dict[str, Any]:
        """Return a JSON-ready permission response."""
        return _dump_value({
            "request_id": self.request_id,
            "action": self.action,
            "pattern": self.pattern,
            "created_at": self.created_at,
        })
