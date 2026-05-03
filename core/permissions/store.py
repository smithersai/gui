"""Permission storage for session-level permissions."""

from __future__ import annotations

import logging
from typing import Dict

from .models import Level, PermissionsConfig, Request, Response

logger = logging.getLogger(__name__)


class PermissionStore:
    """
    Storage for session-specific permission decisions.

    Tracks "always" decisions and custom patterns created during runtime.
    """

    def __init__(self):
        """Initialize the permission store."""
        # Session ID -> PermissionsConfig
        self._session_configs: Dict[str, PermissionsConfig] = {}
        # Request ID -> pending requests waiting for response
        self._pending_requests: Dict[str, Request] = {}

    def get_config(self, session_id: str) -> PermissionsConfig:
        """
        Get permission configuration for a session.

        Args:
            session_id: The session ID

        Returns:
            PermissionsConfig for the session (creates default if not exists)
        """
        if session_id not in self._session_configs:
            self._session_configs[session_id] = PermissionsConfig()
        return self._session_configs[session_id]

    def update_config(self, session_id: str, config: PermissionsConfig) -> None:
        """
        Update permission configuration for a session.

        Args:
            session_id: The session ID
            config: The new configuration
        """
        self._session_configs[session_id] = config

    def add_bash_pattern(self, session_id: str, pattern: str, level: Level) -> None:
        """
        Add a bash command pattern for a session.

        Args:
            session_id: The session ID
            pattern: The command pattern (e.g., "git *")
            level: The permission level for this pattern
        """
        config = self.get_config(session_id)
        config.bash.patterns[pattern] = level
        logger.info("Added bash pattern for session %s: %s -> %s", session_id, pattern, level)

    def add_pending_request(self, request: Request) -> None:
        """
        Track a pending permission request.

        Args:
            request: The permission request
        """
        self._pending_requests[request.id] = request
        logger.debug("Added pending request: %s", request.id)

    def get_pending_request(self, request_id: str) -> Request | None:
        """
        Get a pending permission request.

        Args:
            request_id: The request ID

        Returns:
            The request if found, None otherwise
        """
        return self._pending_requests.get(request_id)

    def remove_pending_request(self, request_id: str) -> None:
        """
        Remove a pending permission request.

        Args:
            request_id: The request ID
        """
        if request_id in self._pending_requests:
            del self._pending_requests[request_id]
            logger.debug("Removed pending request: %s", request_id)

    def clear_session(self, session_id: str) -> None:
        """
        Clear all permissions for a session.

        Args:
            session_id: The session ID
        """
        if session_id in self._session_configs:
            del self._session_configs[session_id]
            logger.info("Cleared permissions for session: %s", session_id)

    def apply_response(self, request: Request, response: Response) -> None:
        """
        Apply a user response to update permissions.

        Args:
            request: The original permission request
            response: The user's response
        """
        if response.action == "always":
            config = self.get_config(request.session_id)
            if request.operation == "bash":
                command = request.details.get("command", "")
                self.add_bash_pattern(request.session_id, command, Level.ALLOW)
            elif request.operation == "edit":
                config.edit = Level.ALLOW
                logger.info("Allowed edit operations for session %s", request.session_id)
            elif request.operation == "webfetch":
                config.webfetch = Level.ALLOW
                logger.info("Allowed webfetch operations for session %s", request.session_id)

        elif response.action == "pattern" and response.pattern:
            # Add custom pattern
            if request.operation == "bash":
                self.add_bash_pattern(request.session_id, response.pattern, Level.ALLOW)
            else:
                logger.warning("Pattern-based approval only supported for bash operations")
