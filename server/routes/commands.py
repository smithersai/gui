"""
Commands endpoint for listing available slash commands.

Provides the list of built-in commands for TUI command palette functionality.
"""

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from config.commands import command_registry
from server.command_manifest import BUILTIN_COMMANDS as BUILTIN_COMMAND_MANIFEST


router = APIRouter()


class Command(BaseModel):
    """A slash command definition."""

    name: str
    description: str
    custom: bool = False


class CommandArg(BaseModel):
    """Argument definition for a command."""

    name: str
    required: bool = False
    description: str = ""
    default: str | None = None


class CommandDetail(BaseModel):
    """Detailed command information including arguments."""

    name: str
    description: str
    template: str
    args: list[CommandArg]
    file_path: str | None = None
    custom: bool = True


class ExpandRequest(BaseModel):
    """Request to expand a command template."""

    name: str
    args: list[str] = []
    kwargs: dict[str, str] = {}


# =============================================================================
# Built-in Commands
# =============================================================================

BUILTIN_COMMANDS = [
    Command(name=command.name, description=command.description)
    for command in BUILTIN_COMMAND_MANIFEST
]


# =============================================================================
# Endpoints
# =============================================================================


@router.get("/command")
async def list_commands(directory: str | None = Query(None)) -> list[Command]:
    """
    List available slash commands (both built-in and custom).

    Args:
        directory: Optional directory path for loading custom commands

    Returns:
        List of available commands
    """
    commands = [
        Command(name=cmd.name, description=cmd.description, custom=False)
        for cmd in BUILTIN_COMMANDS
    ]

    # Load custom commands
    # Note: command_registry loads lazily on first access
    custom_commands = command_registry.list_commands()
    for cmd in custom_commands:
        commands.append(
            Command(name=cmd.name, description=cmd.description, custom=True)
        )

    return commands


@router.get("/command/{command_name}")
async def get_command(command_name: str) -> CommandDetail:
    """
    Get detailed information about a custom command.

    Args:
        command_name: Name of the command to retrieve

    Returns:
        Detailed command information

    Raises:
        HTTPException: If command not found
    """
    command = command_registry.get_command(command_name)
    if command is None:
        raise HTTPException(status_code=404, detail=f"Command not found: {command_name}")

    return CommandDetail(
        name=command.name,
        description=command.description,
        template=command.template,
        args=[
            CommandArg(
                name=arg.name,
                required=arg.required,
                description=arg.description,
                default=arg.default,
            )
            for arg in command.args
        ],
        file_path=str(command.file_path) if command.file_path else None,
        custom=True,
    )


@router.post("/command/expand")
async def expand_command(request: ExpandRequest) -> dict[str, str]:
    """
    Expand a command template with provided arguments.

    Args:
        request: Command expansion request with name and arguments

    Returns:
        Dictionary with expanded template

    Raises:
        HTTPException: If command not found or required arguments missing
    """
    # Handle special built-in commands
    if request.name in ("plugin", "script"):
        from plugins.script_mode import get_plugin_author_prompt

        return {"expanded": get_plugin_author_prompt()}

    try:
        expanded = command_registry.expand_command(
            name=request.name,
            args=request.args,
            kwargs=request.kwargs,
        )
        if expanded is None:
            raise HTTPException(
                status_code=404, detail=f"Command not found: {request.name}"
            )
        return {"expanded": expanded}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/command/reload")
async def reload_commands() -> dict[str, int]:
    """
    Reload all custom commands from disk.

    Returns:
        Dictionary with count of loaded commands
    """
    command_registry.load_commands()
    commands = command_registry.list_commands()
    return {"count": len(commands)}
