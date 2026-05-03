"""Core business logic package."""

from importlib import import_module

_SYMBOL_MODULES = {
    "compact_conversation": "core.compaction",
    "should_auto_compact": "core.compaction",
    "Event": "core.events",
    "EventBus": "core.events",
    "NullEventBus": "core.events",
    "CoreError": "core.exceptions",
    "InvalidOperationError": "core.exceptions",
    "NotFoundError": "core.exceptions",
    "AssistantMessage": "core.models",
    "CompactionInfo": "core.models",
    "CompactionResult": "core.models",
    "FileDiff": "core.models",
    "FilePart": "core.models",
    "GhostCommitInfo": "core.models",
    "Message": "core.models",
    "MessageTime": "core.models",
    "ModelInfo": "core.models",
    "Part": "core.models",
    "PartTime": "core.models",
    "PathInfo": "core.models",
    "ReasoningPart": "core.models",
    "RevertInfo": "core.models",
    "Session": "core.models",
    "SessionSummary": "core.models",
    "SessionTime": "core.models",
    "TextPart": "core.models",
    "TokenInfo": "core.models",
    "ToolPart": "core.models",
    "ToolState": "core.models",
    "ToolStateCompleted": "core.models",
    "ToolStatePending": "core.models",
    "ToolStateRunning": "core.models",
    "UserMessage": "core.models",
    "gen_id": "core.ids",
    "get_message": "core.messages",
    "list_messages": "core.messages",
    "send_message": "core.messages",
    "abort_session": "core.sessions",
    "create_session": "core.sessions",
    "delete_session": "core.sessions",
    "fork_session": "core.sessions",
    "get_session": "core.sessions",
    "get_session_diff": "core.sessions",
    "list_sessions": "core.sessions",
    "revert_session": "core.sessions",
    "undo_turns": "core.sessions",
    "unrevert_session": "core.sessions",
    "update_session": "core.sessions",
    "compute_diff": "core.snapshots",
    "init_snapshot": "core.snapshots",
    "restore_snapshot": "core.snapshots",
    "track_snapshot": "core.snapshots",
}


def __getattr__(name: str):
    """Load public core exports on first access."""
    module_name = _SYMBOL_MODULES.get(name)
    if module_name is None:
        raise AttributeError(f"module 'core' has no attribute {name!r}")
    value = getattr(import_module(module_name), name)
    globals()[name] = value
    return value


__all__ = [
    # Exceptions
    "CoreError",
    "NotFoundError",
    "InvalidOperationError",
    # Events
    "Event",
    "EventBus",
    "NullEventBus",
    # Models
    "Session",
    "SessionTime",
    "SessionSummary",
    "RevertInfo",
    "CompactionInfo",
    "CompactionResult",
    "GhostCommitInfo",
    "FileDiff",
    "Message",
    "UserMessage",
    "AssistantMessage",
    "MessageTime",
    "Part",
    "TextPart",
    "ReasoningPart",
    "ToolPart",
    "FilePart",
    "ToolState",
    "ToolStatePending",
    "ToolStateRunning",
    "ToolStateCompleted",
    "PartTime",
    "ModelInfo",
    "TokenInfo",
    "PathInfo",
    "gen_id",
    # Session operations
    "create_session",
    "get_session",
    "list_sessions",
    "update_session",
    "delete_session",
    "fork_session",
    "revert_session",
    "undo_turns",
    "unrevert_session",
    "abort_session",
    "get_session_diff",
    # Message operations
    "list_messages",
    "get_message",
    "send_message",
    # Snapshot operations
    "init_snapshot",
    "track_snapshot",
    "compute_diff",
    "restore_snapshot",
    # Compaction operations
    "compact_conversation",
    "should_auto_compact",
]
