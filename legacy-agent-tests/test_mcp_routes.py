"""Tests for MCP route manifests."""

from server.mcp_manifest import get_builtin_mcp_servers


def test_builtin_mcp_servers_include_shell_and_filesystem(tmp_path):
    """The MCP manifest describes built-in servers without starting them."""
    servers = get_builtin_mcp_servers(str(tmp_path))
    by_name = {server["name"]: server for server in servers}

    assert set(by_name) == {"shell", "filesystem"}
    assert by_name["shell"]["status"] == "configured"
    assert by_name["shell"]["tools"][0]["name"] == "execute_command"
    assert by_name["filesystem"]["args"][-1] == str(tmp_path)
    assert by_name["filesystem"]["tools"]


def test_builtin_mcp_servers_use_working_dir(tmp_path):
    """The manifest includes the active working directory in filesystem args."""
    payload = {"servers": get_builtin_mcp_servers(str(tmp_path))}
    filesystem = next(
        server for server in payload["servers"] if server["name"] == "filesystem"
    )

    assert filesystem["args"][-1] == str(tmp_path)
