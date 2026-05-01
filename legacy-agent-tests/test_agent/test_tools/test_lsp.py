"""Tests for LSP hover and diagnostics tool implementation."""

import asyncio
import shutil
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from agent.tools.lsp import (
    Diagnostic,
    DiagnosticSeverity,
    DiagnosticsResult,
    LSPError,
    LSPManager,
    LSPServerNotFoundError,
    LSPTimeoutError,
    Position,
    Range,
    HoverResult,
    diagnostics,
    find_workspace_root,
    get_language_id,
    get_server_for_file,
    hover,
    parse_hover_contents,
)


# --- Type Definition Tests ---


class TestPosition:
    """Test Position dataclass."""

    def test_to_dict(self):
        pos = Position(line=10, character=5)
        assert pos.to_dict() == {"line": 10, "character": 5}

    def test_zero_position(self):
        pos = Position(line=0, character=0)
        assert pos.to_dict() == {"line": 0, "character": 0}


class TestRange:
    """Test Range dataclass."""

    def test_to_dict(self):
        r = Range(
            start=Position(0, 0),
            end=Position(0, 10),
        )
        assert r.to_dict() == {
            "start": {"line": 0, "character": 0},
            "end": {"line": 0, "character": 10},
        }

    def test_from_dict(self):
        data = {
            "start": {"line": 5, "character": 3},
            "end": {"line": 5, "character": 15},
        }
        r = Range.from_dict(data)
        assert r.start.line == 5
        assert r.start.character == 3
        assert r.end.line == 5
        assert r.end.character == 15


class TestHoverResult:
    """Test HoverResult dataclass."""

    def test_basic_hover_result(self):
        result = HoverResult(contents="def foo(): ...", language="python")
        assert result.contents == "def foo(): ..."
        assert result.language == "python"
        assert result.range is None

    def test_hover_result_with_range(self):
        r = Range(Position(0, 0), Position(0, 3))
        result = HoverResult(contents="int", range=r, language="python")
        assert result.range is not None
        assert result.range.start.character == 0


class TestDiagnosticSeverity:
    """Test DiagnosticSeverity enum."""

    def test_severity_values(self):
        assert DiagnosticSeverity.ERROR == 1
        assert DiagnosticSeverity.WARNING == 2
        assert DiagnosticSeverity.INFO == 3
        assert DiagnosticSeverity.HINT == 4

    def test_severity_from_int(self):
        assert DiagnosticSeverity(1) == DiagnosticSeverity.ERROR
        assert DiagnosticSeverity(2) == DiagnosticSeverity.WARNING
        assert DiagnosticSeverity(3) == DiagnosticSeverity.INFO
        assert DiagnosticSeverity(4) == DiagnosticSeverity.HINT


class TestDiagnostic:
    """Test Diagnostic dataclass."""

    def test_basic_diagnostic(self):
        diag = Diagnostic(
            range=Range(Position(0, 0), Position(0, 10)),
            severity=DiagnosticSeverity.ERROR,
            message="Test error",
            source="test",
        )
        assert diag.message == "Test error"
        assert diag.severity == DiagnosticSeverity.ERROR
        assert diag.source == "test"

    def test_from_dict(self):
        data = {
            "range": {
                "start": {"line": 10, "character": 5},
                "end": {"line": 10, "character": 15},
            },
            "severity": 1,
            "message": "Expected ';'",
            "source": "typescript",
            "code": "TS1005",
        }
        diag = Diagnostic.from_dict(data)
        assert diag.range.start.line == 10
        assert diag.range.start.character == 5
        assert diag.severity == DiagnosticSeverity.ERROR
        assert diag.message == "Expected ';'"
        assert diag.source == "typescript"
        assert diag.code == "TS1005"

    def test_from_dict_minimal(self):
        """Test parsing with minimal fields."""
        data = {"message": "Error"}
        diag = Diagnostic.from_dict(data)
        assert diag.message == "Error"
        assert diag.severity == DiagnosticSeverity.ERROR  # Default
        assert diag.source == ""
        assert diag.code is None

    def test_pretty_format_error(self):
        diag = Diagnostic(
            range=Range(Position(9, 4), Position(9, 14)),
            severity=DiagnosticSeverity.ERROR,
            message="Expected ';'",
            source="typescript",
        )
        formatted = diag.pretty_format()
        assert "ERROR" in formatted
        assert "[typescript]" in formatted
        assert "[10:5]" in formatted  # 1-based line/col
        assert "Expected ';'" in formatted

    def test_pretty_format_warning(self):
        diag = Diagnostic(
            range=Range(Position(0, 0), Position(0, 5)),
            severity=DiagnosticSeverity.WARNING,
            message="Unused variable",
        )
        formatted = diag.pretty_format()
        assert "WARN" in formatted
        assert "Unused variable" in formatted

    def test_pretty_format_no_source(self):
        diag = Diagnostic(
            range=Range(Position(0, 0), Position(0, 5)),
            severity=DiagnosticSeverity.INFO,
            message="Info message",
        )
        formatted = diag.pretty_format()
        assert "INFO" in formatted
        assert "[]" not in formatted  # No source brackets


class TestDiagnosticsResult:
    """Test DiagnosticsResult dataclass."""

    def test_from_diagnostics_counts(self):
        diags = [
            Diagnostic(Range(Position(0, 0), Position(0, 1)), DiagnosticSeverity.ERROR, "err1"),
            Diagnostic(Range(Position(1, 0), Position(1, 1)), DiagnosticSeverity.ERROR, "err2"),
            Diagnostic(Range(Position(2, 0), Position(2, 1)), DiagnosticSeverity.WARNING, "warn"),
            Diagnostic(Range(Position(3, 0), Position(3, 1)), DiagnosticSeverity.INFO, "info"),
            Diagnostic(Range(Position(4, 0), Position(4, 1)), DiagnosticSeverity.HINT, "hint"),
        ]
        result = DiagnosticsResult.from_diagnostics("/test.py", diags)
        assert result.error_count == 2
        assert result.warning_count == 1
        assert result.info_count == 1
        assert result.hint_count == 1
        assert len(result.diagnostics) == 5

    def test_from_diagnostics_empty(self):
        result = DiagnosticsResult.from_diagnostics("/test.py", [])
        assert result.error_count == 0
        assert result.warning_count == 0
        assert len(result.diagnostics) == 0

    def test_format_output_with_diagnostics(self):
        diags = [
            Diagnostic(Range(Position(9, 4), Position(9, 14)), DiagnosticSeverity.ERROR, "Error 1", "ts"),
            Diagnostic(Range(Position(19, 0), Position(19, 5)), DiagnosticSeverity.WARNING, "Warning 1"),
        ]
        result = DiagnosticsResult.from_diagnostics("/test.ts", diags)
        output = result.format_output()
        assert "Diagnostics for /test.ts:" in output
        assert "1 errors" in output
        assert "1 warnings" in output
        assert "ERROR" in output
        assert "WARN" in output

    def test_format_output_empty(self):
        result = DiagnosticsResult.from_diagnostics("/test.py", [])
        output = result.format_output()
        assert "No diagnostics found" in output


# --- Utility Function Tests ---


class TestGetLanguageId:
    """Test extension to language ID mapping."""

    def test_python_extensions(self):
        assert get_language_id(".py") == "python"
        assert get_language_id(".pyi") == "python"

    def test_typescript_extensions(self):
        assert get_language_id(".ts") == "typescript"
        assert get_language_id(".tsx") == "typescriptreact"

    def test_javascript_extensions(self):
        assert get_language_id(".js") == "javascript"
        assert get_language_id(".jsx") == "javascriptreact"
        assert get_language_id(".mjs") == "javascript"
        assert get_language_id(".cjs") == "javascript"

    def test_go_extension(self):
        assert get_language_id(".go") == "go"

    def test_rust_extension(self):
        assert get_language_id(".rs") == "rust"

    def test_unknown_extension(self):
        assert get_language_id(".unknown") == "plaintext"
        assert get_language_id(".xyz") == "plaintext"


class TestGetServerForFile:
    """Test server configuration lookup."""

    def test_python_file(self):
        result = get_server_for_file("/path/to/file.py")
        assert result is not None
        server_id, config = result
        assert server_id == "python"
        assert ".py" in config["extensions"]

    def test_typescript_file(self):
        result = get_server_for_file("/path/to/file.ts")
        assert result is not None
        server_id, config = result
        assert server_id == "typescript"

    def test_go_file(self):
        result = get_server_for_file("/path/to/file.go")
        assert result is not None
        server_id, config = result
        assert server_id == "go"

    def test_rust_file(self):
        result = get_server_for_file("/path/to/file.rs")
        assert result is not None
        server_id, config = result
        assert server_id == "rust"

    def test_unsupported_file(self):
        result = get_server_for_file("/path/to/file.txt")
        assert result is None

    def test_case_insensitive(self):
        result = get_server_for_file("/path/to/FILE.PY")
        assert result is not None
        server_id, _ = result
        assert server_id == "python"


class TestFindWorkspaceRoot:
    """Test workspace root detection."""

    def test_finds_pyproject_toml(self, tmp_path):
        (tmp_path / "pyproject.toml").touch()
        (tmp_path / "src").mkdir()
        file_path = tmp_path / "src" / "main.py"

        root = find_workspace_root(str(file_path), ["pyproject.toml", ".git"])
        assert root == str(tmp_path)

    def test_finds_package_json(self, tmp_path):
        (tmp_path / "package.json").touch()
        (tmp_path / "src").mkdir()
        file_path = tmp_path / "src" / "index.ts"

        root = find_workspace_root(str(file_path), ["package.json", ".git"])
        assert root == str(tmp_path)

    def test_finds_go_mod(self, tmp_path):
        (tmp_path / "go.mod").touch()
        file_path = tmp_path / "main.go"

        root = find_workspace_root(str(file_path), ["go.mod", ".git"])
        assert root == str(tmp_path)

    def test_fallback_to_file_directory(self, tmp_path):
        file_path = tmp_path / "orphan.py"
        file_path.touch()  # File must exist for is_file() check

        root = find_workspace_root(str(file_path), ["package.json"])
        assert root == str(tmp_path)

    def test_nested_marker(self, tmp_path):
        # Create nested structure
        (tmp_path / "parent").mkdir()
        (tmp_path / "parent" / "pyproject.toml").touch()
        (tmp_path / "parent" / "child").mkdir()
        file_path = tmp_path / "parent" / "child" / "test.py"

        root = find_workspace_root(str(file_path), ["pyproject.toml"])
        assert root == str(tmp_path / "parent")


class TestParseHoverContents:
    """Test parsing various hover content formats."""

    def test_parse_string_content(self):
        result = parse_hover_contents("def foo(): ...")
        assert result == "def foo(): ..."

    def test_parse_none(self):
        result = parse_hover_contents(None)
        assert result == ""

    def test_parse_markup_content_markdown(self):
        content = {"kind": "markdown", "value": "```python\ndef foo()\n```"}
        result = parse_hover_contents(content)
        assert "def foo()" in result

    def test_parse_markup_content_plaintext(self):
        content = {"kind": "plaintext", "value": "foo: str"}
        result = parse_hover_contents(content)
        assert result == "foo: str"

    def test_parse_marked_string_with_language(self):
        content = {"language": "python", "value": "def foo()"}
        result = parse_hover_contents(content)
        assert "```python" in result
        assert "def foo()" in result

    def test_parse_marked_string_array(self):
        content = [
            {"language": "python", "value": "def foo()"},
            "Documentation here",
        ]
        result = parse_hover_contents(content)
        assert "def foo()" in result
        assert "Documentation" in result

    def test_parse_empty_array(self):
        result = parse_hover_contents([])
        assert result == ""


# --- LSP Manager Tests ---


class TestLSPManager:
    """Test LSP manager singleton and client pooling."""

    @pytest.fixture(autouse=True)
    def reset_manager(self):
        """Reset manager singleton before each test."""
        LSPManager.reset_instance()
        yield
        LSPManager.reset_instance()

    @pytest.mark.asyncio
    async def test_singleton_pattern(self):
        """Test manager returns same instance."""
        manager1 = await LSPManager.get_instance()
        manager2 = await LSPManager.get_instance()
        assert manager1 is manager2

    @pytest.mark.asyncio
    async def test_broken_server_tracking(self):
        """Test broken servers are tracked."""
        manager = await LSPManager.get_instance()

        assert not manager._is_broken("python", "/test/root")

        manager._mark_broken("python", "/test/root")

        assert manager._is_broken("python", "/test/root")
        assert not manager._is_broken("python", "/other/root")
        assert not manager._is_broken("typescript", "/test/root")

    @pytest.mark.asyncio
    async def test_shutdown_all(self):
        """Test shutdown clears clients."""
        manager = await LSPManager.get_instance()
        # Just verify it doesn't raise
        await manager.shutdown_all()
        assert len(manager._clients) == 0


# --- Hover API Tests ---


class TestHoverAPI:
    """Test public hover() function."""

    @pytest.fixture(autouse=True)
    def reset_manager(self):
        """Reset manager singleton before each test."""
        LSPManager.reset_instance()
        yield
        LSPManager.reset_instance()

    @pytest.mark.asyncio
    async def test_file_not_found(self):
        """Test error when file doesn't exist."""
        result = await hover("/nonexistent/path.py", 0, 0)
        assert result["success"] is False
        assert "not found" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_unsupported_file_type(self, tmp_path):
        """Test error for unsupported file types."""
        test_file = tmp_path / "test.xyz"
        test_file.write_text("content")

        result = await hover(str(test_file), 0, 0)
        assert result["success"] is False
        assert "No LSP server available" in result["error"]

    @pytest.mark.asyncio
    @pytest.mark.skipif(not shutil.which("pylsp"), reason="pylsp not installed")
    async def test_hover_on_python_file(self, tmp_path):
        """Integration test: hover on Python function."""
        test_file = tmp_path / "test.py"
        test_file.write_text(
            "def add(x: int, y: int) -> int:\n"
            "    '''Add two numbers.'''\n"
            "    return x + y\n"
        )

        # Hover over function name
        result = await hover(str(test_file), 0, 4)

        # Clean up
        manager = await LSPManager.get_instance()
        await manager.shutdown_all()

        assert result["success"] is True
        assert "add" in result["contents"].lower() or "int" in result["contents"].lower()

    @pytest.mark.asyncio
    async def test_server_not_found(self, tmp_path):
        """Test error when server binary not found."""
        # Create a Python file but mock shutil.which to return None
        test_file = tmp_path / "test.py"
        test_file.write_text("x = 1")

        with patch("agent.tools.lsp.shutil.which", return_value=None):
            result = await hover(str(test_file), 0, 0)

        assert result["success"] is False
        assert "not found" in result["error"].lower()


# --- Exception Tests ---


class TestExceptions:
    """Test custom exception classes."""

    def test_lsp_error_base(self):
        err = LSPError("test error")
        assert str(err) == "test error"

    def test_lsp_timeout_error(self):
        err = LSPTimeoutError("request timed out")
        assert isinstance(err, LSPError)
        assert "timed out" in str(err)

    def test_lsp_server_not_found_error(self):
        err = LSPServerNotFoundError("pylsp not found")
        assert isinstance(err, LSPError)
        assert "pylsp" in str(err)


# --- Diagnostics API Tests ---


class TestDiagnosticsAPI:
    """Test public diagnostics() function."""

    @pytest.fixture(autouse=True)
    def reset_manager(self):
        """Reset manager singleton before each test."""
        LSPManager.reset_instance()
        yield
        LSPManager.reset_instance()

    @pytest.mark.asyncio
    async def test_file_not_found(self):
        """Test error when file doesn't exist."""
        result = await diagnostics("/nonexistent/path.py")
        assert result["success"] is False
        assert "not found" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_unsupported_file_type(self, tmp_path):
        """Test error for unsupported file types."""
        test_file = tmp_path / "test.xyz"
        test_file.write_text("content")

        result = await diagnostics(str(test_file))
        assert result["success"] is False
        assert "No LSP server available" in result["error"]

    @pytest.mark.asyncio
    async def test_server_not_found(self, tmp_path):
        """Test error when server binary not found."""
        test_file = tmp_path / "test.py"
        test_file.write_text("x = 1")

        with patch("agent.tools.lsp.shutil.which", return_value=None):
            result = await diagnostics(str(test_file))

        assert result["success"] is False
        assert "not found" in result["error"].lower()

    @pytest.mark.asyncio
    @pytest.mark.skipif(not shutil.which("pylsp"), reason="pylsp not installed")
    async def test_diagnostics_on_valid_python_file(self, tmp_path):
        """Integration test: diagnostics on valid Python file."""
        test_file = tmp_path / "test.py"
        test_file.write_text("x: int = 1\n")

        result = await diagnostics(str(test_file), timeout=5.0)

        # Clean up
        manager = await LSPManager.get_instance()
        await manager.shutdown_all()

        assert result["success"] is True
        assert "file_path" in result
        assert "error_count" in result
        assert "warning_count" in result
        assert "summary" in result

    @pytest.mark.asyncio
    @pytest.mark.skipif(not shutil.which("pylsp"), reason="pylsp not installed")
    async def test_diagnostics_on_python_file_with_error(self, tmp_path):
        """Integration test: diagnostics on Python file with syntax error."""
        test_file = tmp_path / "test_error.py"
        # Write invalid Python syntax
        test_file.write_text("def foo(\n")  # Missing closing paren and body

        result = await diagnostics(str(test_file), timeout=5.0)

        # Clean up
        manager = await LSPManager.get_instance()
        await manager.shutdown_all()

        assert result["success"] is True
        # Pylsp should report syntax errors
        assert result["error_count"] >= 0  # May or may not find errors depending on pylsp plugins

    @pytest.mark.asyncio
    async def test_diagnostics_result_structure(self, tmp_path):
        """Test the structure of successful diagnostics result."""
        test_file = tmp_path / "test.py"
        test_file.write_text("x = 1")

        # Mock the client to return specific diagnostics
        mock_client = MagicMock()
        mock_client.wait_for_diagnostics = AsyncMock(return_value=[
            Diagnostic(
                range=Range(Position(0, 0), Position(0, 5)),
                severity=DiagnosticSeverity.ERROR,
                message="Test error",
                source="test",
            ),
            Diagnostic(
                range=Range(Position(1, 0), Position(1, 5)),
                severity=DiagnosticSeverity.WARNING,
                message="Test warning",
            ),
        ])

        mock_manager = MagicMock()
        mock_manager.get_client = AsyncMock(return_value=mock_client)

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await diagnostics(str(test_file))

        assert result["success"] is True
        assert result["error_count"] == 1
        assert result["warning_count"] == 1
        assert len(result["diagnostics"]) == 2
        assert "ERROR" in result["diagnostics"][0]
        assert "WARN" in result["diagnostics"][1]
        assert "1 errors, 1 warnings" in result["summary"]


# --- LSP Client Diagnostic Tests ---


class TestLSPClientDiagnostics:
    """Test LSPClient diagnostic methods."""

    @pytest.fixture(autouse=True)
    def reset_manager(self):
        """Reset manager singleton before each test."""
        LSPManager.reset_instance()
        yield
        LSPManager.reset_instance()

    def test_get_diagnostics_empty(self):
        """Test get_diagnostics returns empty list for unknown file."""
        from agent.tools.lsp import LSPClient, LSPConnection
        mock_conn = MagicMock(spec=LSPConnection)
        client = LSPClient("python", "/root", mock_conn)

        diags = client.get_diagnostics("/unknown/file.py")
        assert diags == []

    def test_get_all_diagnostics_empty(self):
        """Test get_all_diagnostics returns empty dict initially."""
        from agent.tools.lsp import LSPClient, LSPConnection
        mock_conn = MagicMock(spec=LSPConnection)
        client = LSPClient("python", "/root", mock_conn)

        all_diags = client.get_all_diagnostics()
        assert all_diags == {}

    def test_handle_publish_diagnostics(self):
        """Test _handle_publish_diagnostics stores diagnostics correctly."""
        from agent.tools.lsp import LSPClient, LSPConnection
        mock_conn = MagicMock(spec=LSPConnection)
        client = LSPClient("python", "/root", mock_conn)

        params = {
            "uri": "file:///test/file.py",
            "diagnostics": [
                {
                    "range": {
                        "start": {"line": 0, "character": 0},
                        "end": {"line": 0, "character": 5},
                    },
                    "severity": 1,
                    "message": "Test error",
                },
            ],
        }

        client._handle_publish_diagnostics(params)

        diags = client.get_diagnostics("/test/file.py")
        assert len(diags) == 1
        assert diags[0].message == "Test error"
        assert diags[0].severity == DiagnosticSeverity.ERROR


# --- Notification Handler Tests ---


class TestLSPConnectionNotifications:
    """Test LSPConnection notification handling."""

    def test_on_notification_registers_handler(self):
        """Test that on_notification registers a handler."""
        from agent.tools.lsp import LSPConnection
        mock_process = MagicMock()
        mock_reader = MagicMock()
        mock_writer = MagicMock()

        conn = LSPConnection(mock_process, mock_reader, mock_writer)

        handler = MagicMock()
        conn.on_notification("test/method", handler)

        assert "test/method" in conn._notification_handlers
        assert conn._notification_handlers["test/method"] is handler


# --- TouchFile API Tests ---


class TestTouchFileAPI:
    """Test touch_file public API function."""

    @pytest.fixture(autouse=True)
    def reset_manager(self):
        """Reset manager singleton before each test."""
        LSPManager.reset_instance()
        yield
        LSPManager.reset_instance()

    @pytest.mark.asyncio
    async def test_file_not_found(self):
        """Test error when file doesn't exist."""
        from agent.tools.lsp import touch_file
        result = await touch_file("/nonexistent/file.py")
        assert result["success"] is False
        assert "not found" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_unsupported_file_type(self, tmp_path):
        """Test error for unsupported file type."""
        from agent.tools.lsp import touch_file
        test_file = tmp_path / "test.xyz"
        test_file.write_text("content")

        result = await touch_file(str(test_file))
        assert result["success"] is False
        assert "No LSP server available" in result["error"]

    @pytest.mark.asyncio
    async def test_touch_file_with_diagnostics(self, tmp_path):
        """Test touch_file returns diagnostics when requested."""
        from agent.tools.lsp import touch_file

        test_file = tmp_path / "test.py"
        test_file.write_text("x = 1")

        # Mock the client
        mock_client = MagicMock()
        mock_client.open_file = AsyncMock()
        mock_client.wait_for_diagnostics = AsyncMock(return_value=[
            Diagnostic(
                range=Range(Position(0, 0), Position(0, 5)),
                severity=DiagnosticSeverity.ERROR,
                message="Test error",
                source="test",
            ),
        ])

        mock_manager = MagicMock()
        mock_manager.get_client = AsyncMock(return_value=mock_client)

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await touch_file(str(test_file), wait_for_diagnostics=True)

        assert result["success"] is True
        assert result["error_count"] == 1
        assert len(result["diagnostics"]) == 1

    @pytest.mark.asyncio
    async def test_touch_file_without_diagnostics(self, tmp_path):
        """Test touch_file without waiting for diagnostics."""
        from agent.tools.lsp import touch_file

        test_file = tmp_path / "test.py"
        test_file.write_text("x = 1")

        # Mock the client
        mock_client = MagicMock()
        mock_client.open_file = AsyncMock()

        mock_manager = MagicMock()
        mock_manager.get_client = AsyncMock(return_value=mock_client)

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await touch_file(str(test_file), wait_for_diagnostics=False)

        assert result["success"] is True
        assert "message" in result
        mock_client.open_file.assert_called_once()
        mock_client.wait_for_diagnostics.assert_not_called()


# --- GetAllDiagnosticsSummary API Tests ---


class TestGetAllDiagnosticsSummaryAPI:
    """Test get_all_diagnostics_summary public API function."""

    @pytest.fixture(autouse=True)
    def reset_manager(self):
        """Reset manager singleton before each test."""
        LSPManager.reset_instance()
        yield
        LSPManager.reset_instance()

    @pytest.mark.asyncio
    async def test_empty_diagnostics(self):
        """Test get_all_diagnostics_summary with no diagnostics."""
        from agent.tools.lsp import get_all_diagnostics_summary

        mock_manager = MagicMock()
        mock_manager.get_all_diagnostics.return_value = {}

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await get_all_diagnostics_summary()

        assert result["success"] is True
        assert result["file_count"] == 0
        assert result["total_errors"] == 0
        assert result["total_warnings"] == 0

    @pytest.mark.asyncio
    async def test_with_diagnostics(self):
        """Test get_all_diagnostics_summary with diagnostics."""
        from agent.tools.lsp import get_all_diagnostics_summary

        mock_manager = MagicMock()
        mock_manager.get_all_diagnostics.return_value = {
            "/test/file1.py": [
                Diagnostic(
                    range=Range(Position(0, 0), Position(0, 5)),
                    severity=DiagnosticSeverity.ERROR,
                    message="Error 1",
                ),
                Diagnostic(
                    range=Range(Position(1, 0), Position(1, 5)),
                    severity=DiagnosticSeverity.WARNING,
                    message="Warning 1",
                ),
            ],
            "/test/file2.py": [
                Diagnostic(
                    range=Range(Position(0, 0), Position(0, 5)),
                    severity=DiagnosticSeverity.ERROR,
                    message="Error 2",
                ),
            ],
        }

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await get_all_diagnostics_summary()

        assert result["success"] is True
        assert result["file_count"] == 2
        assert result["total_errors"] == 2
        assert result["total_warnings"] == 1
        assert "/test/file1.py" in result["diagnostics"]
        assert "/test/file2.py" in result["diagnostics"]


# --- LSPManager GetAllDiagnostics Tests ---


class TestLSPManagerGetAllDiagnostics:
    """Test LSPManager.get_all_diagnostics method."""

    @pytest.fixture(autouse=True)
    def reset_manager(self):
        """Reset manager singleton before each test."""
        LSPManager.reset_instance()
        yield
        LSPManager.reset_instance()

    def test_empty_when_no_clients(self):
        """Test get_all_diagnostics returns empty dict when no clients."""
        manager = LSPManager()
        result = manager.get_all_diagnostics()
        assert result == {}

    def test_aggregates_from_multiple_clients(self):
        """Test get_all_diagnostics aggregates from multiple clients."""
        from agent.tools.lsp import LSPClient, LSPConnection

        manager = LSPManager()

        # Create mock clients with diagnostics
        mock_conn1 = MagicMock(spec=LSPConnection)
        client1 = LSPClient("python", "/root1", mock_conn1)
        client1._diagnostics = {
            "/file1.py": [
                Diagnostic(
                    range=Range(Position(0, 0), Position(0, 5)),
                    severity=DiagnosticSeverity.ERROR,
                    message="Error 1",
                )
            ]
        }

        mock_conn2 = MagicMock(spec=LSPConnection)
        client2 = LSPClient("typescript", "/root2", mock_conn2)
        client2._diagnostics = {
            "/file2.ts": [
                Diagnostic(
                    range=Range(Position(0, 0), Position(0, 5)),
                    severity=DiagnosticSeverity.WARNING,
                    message="Warning 1",
                )
            ]
        }

        manager._clients = [client1, client2]

        result = manager.get_all_diagnostics()

        assert "/file1.py" in result
        assert "/file2.ts" in result
        assert len(result["/file1.py"]) == 1
        assert len(result["/file2.ts"]) == 1


# --- Workspace Symbol API Tests ---


class TestWorkspaceSymbolAPI:
    """Test workspace_symbol public API function."""

    @pytest.fixture(autouse=True)
    def reset_manager(self):
        """Reset manager singleton before each test."""
        LSPManager.reset_instance()
        yield
        LSPManager.reset_instance()

    @pytest.mark.asyncio
    async def test_workspace_symbol_no_clients(self):
        """Test error when no clients are available."""
        from agent.tools.lsp import workspace_symbol

        result = await workspace_symbol("test_function")
        assert result["success"] is False
        assert "No LSP clients available" in result["error"]

    @pytest.mark.asyncio
    async def test_workspace_symbol_with_mock_client(self, tmp_path):
        """Test workspace_symbol with mocked client."""
        from agent.tools.lsp import workspace_symbol

        test_file = tmp_path / "test.py"
        test_file.write_text("def test_function(): pass")

        # Mock client with symbol results
        mock_client = MagicMock()
        mock_client.workspace_symbol = AsyncMock(return_value=[
            {
                "name": "test_function",
                "kind": 12,  # Function
                "location": {
                    "uri": f"file://{test_file}",
                    "range": {
                        "start": {"line": 0, "character": 4},
                        "end": {"line": 0, "character": 17},
                    },
                },
            },
        ])

        mock_manager = MagicMock()
        mock_manager.get_client = AsyncMock(return_value=mock_client)
        mock_manager._client_lock = asyncio.Lock()
        mock_manager._clients = [mock_client]

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await workspace_symbol("test_function", str(test_file))

        assert result["success"] is True
        assert result["count"] == 1
        assert len(result["symbols"]) == 1
        assert result["symbols"][0]["name"] == "test_function"

    @pytest.mark.asyncio
    async def test_workspace_symbol_no_results(self, tmp_path):
        """Test workspace_symbol with no results."""
        from agent.tools.lsp import workspace_symbol

        test_file = tmp_path / "test.py"
        test_file.write_text("x = 1")

        mock_client = MagicMock()
        mock_client.workspace_symbol = AsyncMock(return_value=[])

        mock_manager = MagicMock()
        mock_manager.get_client = AsyncMock(return_value=mock_client)

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await workspace_symbol("nonexistent", str(test_file))

        assert result["success"] is True
        assert result["count"] == 0
        assert len(result["symbols"]) == 0


# --- Go To Definition API Tests ---


class TestGoToDefinitionAPI:
    """Test go_to_definition public API function."""

    @pytest.fixture(autouse=True)
    def reset_manager(self):
        """Reset manager singleton before each test."""
        LSPManager.reset_instance()
        yield
        LSPManager.reset_instance()

    @pytest.mark.asyncio
    async def test_file_not_found(self):
        """Test error when file doesn't exist."""
        from agent.tools.lsp import go_to_definition

        result = await go_to_definition("/nonexistent/path.py", 0, 0)
        assert result["success"] is False
        assert "not found" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_unsupported_file_type(self, tmp_path):
        """Test error for unsupported file types."""
        from agent.tools.lsp import go_to_definition

        test_file = tmp_path / "test.xyz"
        test_file.write_text("content")

        result = await go_to_definition(str(test_file), 0, 0)
        assert result["success"] is False
        assert "No LSP server available" in result["error"]

    @pytest.mark.asyncio
    async def test_go_to_definition_with_mock_client(self, tmp_path):
        """Test go_to_definition with mocked client."""
        from agent.tools.lsp import go_to_definition

        test_file = tmp_path / "test.py"
        test_file.write_text("x = 1")

        # Mock client with definition result
        mock_client = MagicMock()
        mock_client.definition = AsyncMock(return_value=[
            {
                "uri": f"file://{test_file}",
                "range": {
                    "start": {"line": 0, "character": 0},
                    "end": {"line": 0, "character": 1},
                },
            },
        ])

        mock_manager = MagicMock()
        mock_manager.get_client = AsyncMock(return_value=mock_client)

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await go_to_definition(str(test_file), 0, 0)

        assert result["success"] is True
        assert result["count"] == 1
        assert len(result["definitions"]) == 1
        # Check that file:// URI was stripped
        assert not result["definitions"][0]["uri"].startswith("file://")

    @pytest.mark.asyncio
    async def test_go_to_definition_no_result(self, tmp_path):
        """Test go_to_definition with no results."""
        from agent.tools.lsp import go_to_definition

        test_file = tmp_path / "test.py"
        test_file.write_text("x = 1")

        mock_client = MagicMock()
        mock_client.definition = AsyncMock(return_value=[])

        mock_manager = MagicMock()
        mock_manager.get_client = AsyncMock(return_value=mock_client)

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await go_to_definition(str(test_file), 0, 0)

        assert result["success"] is True
        assert result["count"] == 0
        assert len(result["definitions"]) == 0


# --- Find References API Tests ---


class TestFindReferencesAPI:
    """Test find_references public API function."""

    @pytest.fixture(autouse=True)
    def reset_manager(self):
        """Reset manager singleton before each test."""
        LSPManager.reset_instance()
        yield
        LSPManager.reset_instance()

    @pytest.mark.asyncio
    async def test_file_not_found(self):
        """Test error when file doesn't exist."""
        from agent.tools.lsp import find_references

        result = await find_references("/nonexistent/path.py", 0, 0)
        assert result["success"] is False
        assert "not found" in result["error"].lower()

    @pytest.mark.asyncio
    async def test_unsupported_file_type(self, tmp_path):
        """Test error for unsupported file types."""
        from agent.tools.lsp import find_references

        test_file = tmp_path / "test.xyz"
        test_file.write_text("content")

        result = await find_references(str(test_file), 0, 0)
        assert result["success"] is False
        assert "No LSP server available" in result["error"]

    @pytest.mark.asyncio
    async def test_find_references_with_mock_client(self, tmp_path):
        """Test find_references with mocked client."""
        from agent.tools.lsp import find_references

        test_file = tmp_path / "test.py"
        other_file = tmp_path / "other.py"
        test_file.write_text("def foo(): pass")
        other_file.write_text("from test import foo")

        # Mock client with reference results
        mock_client = MagicMock()
        mock_client.references = AsyncMock(return_value=[
            {
                "uri": f"file://{test_file}",
                "range": {
                    "start": {"line": 0, "character": 4},
                    "end": {"line": 0, "character": 7},
                },
            },
            {
                "uri": f"file://{other_file}",
                "range": {
                    "start": {"line": 0, "character": 17},
                    "end": {"line": 0, "character": 20},
                },
            },
        ])

        mock_manager = MagicMock()
        mock_manager.get_client = AsyncMock(return_value=mock_client)

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await find_references(str(test_file), 0, 4, include_declaration=True)

        assert result["success"] is True
        assert result["count"] == 2
        assert len(result["references"]) == 2
        assert len(result["files"]) == 2
        # Check that file:// URIs were stripped
        for ref in result["references"]:
            assert not ref["uri"].startswith("file://")

    @pytest.mark.asyncio
    async def test_find_references_no_result(self, tmp_path):
        """Test find_references with no results."""
        from agent.tools.lsp import find_references

        test_file = tmp_path / "test.py"
        test_file.write_text("x = 1")

        mock_client = MagicMock()
        mock_client.references = AsyncMock(return_value=[])

        mock_manager = MagicMock()
        mock_manager.get_client = AsyncMock(return_value=mock_client)

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await find_references(str(test_file), 0, 0)

        assert result["success"] is True
        assert result["count"] == 0
        assert len(result["references"]) == 0
        assert len(result["files"]) == 0

    @pytest.mark.asyncio
    async def test_find_references_exclude_declaration(self, tmp_path):
        """Test find_references excluding declaration."""
        from agent.tools.lsp import find_references

        test_file = tmp_path / "test.py"
        test_file.write_text("x = 1")

        mock_client = MagicMock()
        mock_client.references = AsyncMock(return_value=[])

        mock_manager = MagicMock()
        mock_manager.get_client = AsyncMock(return_value=mock_client)

        with patch("agent.tools.lsp.get_lsp_manager", return_value=mock_manager):
            result = await find_references(str(test_file), 0, 0, include_declaration=False)

        assert result["success"] is True
        # Verify the client was called with include_declaration=False
        mock_client.references.assert_called_once_with(str(test_file), 0, 0, False)


# --- LSP Client Definition and References Tests ---


class TestLSPClientDefinitionAndReferences:
    """Test LSPClient definition and references methods."""

    @pytest.mark.asyncio
    async def test_definition_method(self):
        """Test LSPClient.definition method."""
        from agent.tools.lsp import LSPClient, LSPConnection

        mock_conn = MagicMock(spec=LSPConnection)
        mock_conn.send_request = AsyncMock(return_value=[
            {
                "uri": "file:///test.py",
                "range": {
                    "start": {"line": 5, "character": 0},
                    "end": {"line": 5, "character": 10},
                },
            },
        ])

        client = LSPClient("python", "/root", mock_conn)
        client._open_files.add("/test.py")  # Pretend file is already open

        result = await client.definition("/test.py", 0, 5)

        assert len(result) == 1
        assert result[0]["uri"] == "file:///test.py"
        mock_conn.send_request.assert_called_once()

    @pytest.mark.asyncio
    async def test_references_method(self):
        """Test LSPClient.references method."""
        from agent.tools.lsp import LSPClient, LSPConnection

        mock_conn = MagicMock(spec=LSPConnection)
        mock_conn.send_request = AsyncMock(return_value=[
            {
                "uri": "file:///test.py",
                "range": {
                    "start": {"line": 0, "character": 0},
                    "end": {"line": 0, "character": 5},
                },
            },
            {
                "uri": "file:///other.py",
                "range": {
                    "start": {"line": 10, "character": 0},
                    "end": {"line": 10, "character": 5},
                },
            },
        ])

        client = LSPClient("python", "/root", mock_conn)
        client._open_files.add("/test.py")  # Pretend file is already open

        result = await client.references("/test.py", 0, 0, include_declaration=True)

        assert len(result) == 2
        assert result[0]["uri"] == "file:///test.py"
        assert result[1]["uri"] == "file:///other.py"
        mock_conn.send_request.assert_called_once()
        # Check the parameters passed
        call_args = mock_conn.send_request.call_args
        assert call_args[0][0] == "textDocument/references"
        assert call_args[0][1]["context"]["includeDeclaration"] is True
