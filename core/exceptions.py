"""
Core domain exceptions.

These exceptions are transport-agnostic and should be caught by the server
layer to convert into appropriate HTTP responses.
"""


class CoreError(Exception):
    """Base exception for all core errors."""


class NotFoundError(CoreError):
    """Raised when a requested resource is not found."""

    def __init__(self, resource: str, identifier: str):
        self.resource = resource
        self.identifier = identifier
        super().__init__(f"{resource} not found: {identifier}")


class InvalidOperationError(CoreError):
    """Raised when an operation cannot be performed in the current state."""
