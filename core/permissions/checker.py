"""Permission checker implementation."""

from __future__ import annotations

import asyncio
import logging
from typing import Dict

from core.events import Event, EventBus
from core.ids import gen_id

from .dangerous import is_dangerous_bash_command
from .models import Action, Level, Request, Response
from .patterns import match_pattern
from .store import PermissionStore

logger = logging.getLogger(__name__)

# Timeout for permission requests (5 minutes)
PERMISSION_TIMEOUT_SECONDS = 300


class PermissionChecker:
    """
    Permission checker for tool operations.

    Checks permissions before tool execution and handles interactive
    approval prompts via SSE events.
    """

    def __init__(self, store: PermissionStore, event_bus: EventBus):
        """
        Initialize the permission checker.

        Args:
            store: Permission store for session configurations
            event_bus: Event bus for publishing permission events
        """
        self.store = store
        self.event_bus = event_bus
        # Response futures for pending requests
        self._response_futures: Dict[str, asyncio.Future] = {}

    def check_bash(self, command: str, session_id: str) -> Level:
        """
        Check permission level for a bash command.

        Args:
            command: The bash command to check
            session_id: The session ID

        Returns:
            Permission level (ask/allow/deny)
        """
        config = self.store.get_config(session_id)

        # Check exact match first
        if command in config.bash.patterns:
            return config.bash.patterns[command]

        # Check glob patterns
        for pattern, level in config.bash.patterns.items():
            if match_pattern(pattern, command):
                return level

        # Return default
        return config.bash.default

    def check_edit(self, file_path: str, session_id: str) -> Level:
        """
        Check permission level for a file edit operation.

        Args:
            file_path: The file path to edit
            session_id: The session ID

        Returns:
            Permission level (ask/allow/deny)
        """
        config = self.store.get_config(session_id)
        return config.edit

    def check_webfetch(self, url: str, session_id: str) -> Level:
        """
        Check permission level for a web fetch operation.

        Args:
            url: The URL to fetch
            session_id: The session ID

        Returns:
            Permission level (ask/allow/deny)
        """
        config = self.store.get_config(session_id)
        return config.webfetch

    async def request_permission(
        self,
        operation: str,
        details: dict,
        session_id: str,
        message_id: str,
        call_id: str | None = None,
    ) -> bool:
        """
        Request permission from user via SSE event.

        Args:
            operation: Operation type ("bash", "edit", "webfetch")
            details: Operation details (command, file_path, url, etc.)
            session_id: The session ID
            message_id: The message ID
            call_id: Optional call ID

        Returns:
            True if approved, False if denied

        Raises:
            TimeoutError: If no response within timeout period
        """
        # Create permission request
        request = Request(
            id=gen_id("perm_"),
            session_id=session_id,
            message_id=message_id,
            call_id=call_id,
            operation=operation,
            details=details,
        )

        # Check if dangerous
        if operation == "bash":
            command = details.get("command", "")
            is_dangerous, warning = is_dangerous_bash_command(command)
            request.is_dangerous = is_dangerous
            request.warning = warning

        # Store pending request
        self.store.add_pending_request(request)

        # Create future for response
        future: asyncio.Future = asyncio.Future()
        self._response_futures[request.id] = future

        # Publish permission request event
        await self.event_bus.publish(
            Event(
                type="permission.requested",
                properties={"request": request.model_dump()},
            )
        )

        try:
            # Wait for response with timeout
            response = await asyncio.wait_for(
                future,
                timeout=PERMISSION_TIMEOUT_SECONDS,
            )

            # Apply response to update patterns
            self.store.apply_response(request, response)

            # Publish permission responded event
            await self.event_bus.publish(
                Event(
                    type="permission.responded",
                    properties={
                        "request_id": request.id,
                        "action": response.action,
                    },
                )
            )

            # Return approval status
            approved = response.action in [Action.APPROVE_ONCE, Action.APPROVE_ALWAYS, Action.APPROVE_PATTERN]
            return approved

        except asyncio.TimeoutError:
            logger.warning("Permission request timed out: %s", request.id)
            raise TimeoutError(f"Permission request timed out after {PERMISSION_TIMEOUT_SECONDS}s")

        finally:
            # Cleanup
            self.store.remove_pending_request(request.id)
            if request.id in self._response_futures:
                del self._response_futures[request.id]

    def respond_to_request(self, response: Response) -> None:
        """
        Handle a user response to a permission request.

        Args:
            response: The user's response
        """
        if response.request_id in self._response_futures:
            future = self._response_futures[response.request_id]
            if not future.done():
                future.set_result(response)
                logger.debug("Permission response received: %s -> %s", response.request_id, response.action)
        else:
            logger.warning("Received response for unknown request: %s", response.request_id)
