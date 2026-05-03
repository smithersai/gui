"""
Built-in MCP server manifest helpers.
"""

import shutil
import sys


def get_builtin_mcp_servers(working_dir: str) -> list[dict]:
    """Return the built-in MCP server manifest without starting subprocesses."""
    filesystem_available = shutil.which("npx") is not None
    return [
        {
            "name": "shell",
            "description": "Execute shell commands and scripts",
            "status": "configured",
            "command": sys.executable,
            "args": ["-m", "mcp_server_shell"],
            "url": "",
            "tools": get_server_tools("shell"),
            "lastError": "",
            "connectedAt": None,
        },
        {
            "name": "filesystem",
            "description": "Read, write, and manage files",
            "status": "configured" if filesystem_available else "unavailable",
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem", working_dir],
            "url": "",
            "tools": get_server_tools("filesystem"),
            "lastError": "" if filesystem_available else "npx not found on PATH",
            "connectedAt": None,
        },
    ]


def get_server_tools(server_name: str) -> list[dict]:
    """Get the tools provided by a specific MCP server."""
    if server_name == "shell":
        return [
            {
                "name": "execute_command",
                "description": "Execute a shell command and return the output",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "command": {
                            "type": "string",
                            "description": "The shell command to execute",
                        },
                        "timeout": {
                            "type": "number",
                            "description": "Timeout in seconds (default: 60)",
                        },
                    },
                    "required": ["command"],
                },
                "examples": ["ls -la", "git status", "npm install"],
            }
        ]
    if server_name == "filesystem":
        return [
            {
                "name": "read_file",
                "description": "Read the contents of a file",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "path": {
                            "type": "string",
                            "description": "Path to the file to read",
                        },
                    },
                    "required": ["path"],
                },
                "examples": ["/path/to/file.txt"],
            },
            {
                "name": "write_file",
                "description": "Write contents to a file",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "path": {
                            "type": "string",
                            "description": "Path to the file to write",
                        },
                        "content": {
                            "type": "string",
                            "description": "Content to write to the file",
                        },
                    },
                    "required": ["path", "content"],
                },
                "examples": [],
            },
            {
                "name": "list_directory",
                "description": "List contents of a directory",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "path": {
                            "type": "string",
                            "description": "Path to the directory to list",
                        },
                    },
                    "required": ["path"],
                },
                "examples": ["/path/to/directory"],
            },
            {
                "name": "search_files",
                "description": "Search for files matching a pattern",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "pattern": {
                            "type": "string",
                            "description": "Search pattern (glob or regex)",
                        },
                        "path": {
                            "type": "string",
                            "description": "Directory to search in",
                        },
                    },
                    "required": ["pattern"],
                },
                "examples": ["*.py", "**/*.js"],
            },
        ]

    return []
