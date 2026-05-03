"""
MCP server status endpoint.
"""

import os

from fastapi import APIRouter

from server.mcp_manifest import get_builtin_mcp_servers, get_server_tools

__all__ = ["router", "get_mcp_servers", "get_builtin_mcp_servers", "get_server_tools"]

router = APIRouter()


@router.get("/mcp/servers")
async def get_mcp_servers() -> dict:
    """Get MCP server status and available tools."""
    working_dir = os.environ.get("WORKING_DIR", os.getcwd())
    return {"servers": get_builtin_mcp_servers(working_dir)}
