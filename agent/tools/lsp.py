"""
LSP (Language Server Protocol) client implementation.

Provides hover functionality for type hints and documentation across
multiple programming languages (Python, TypeScript, Go, Rust).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
from dataclasses import dataclass, field
from enum import IntEnum
from pathlib import Path
from typing import Any, Callable, ClassVar

logger = logging.getLogger(__name__)

# Constants
LSP_INIT_TIMEOUT_SECONDS = 5.0
LSP_REQUEST_TIMEOUT_SECONDS = 2.0
LSP_DIAGNOSTICS_TIMEOUT_SECONDS = 5.0  # Longer timeout for diagnostics
LSP_MAX_CLIENTS = 10

# Language server configurations
LSP_SERVERS: dict[str, dict[str, Any]] = {
    "python": {
        "extensions": [".py", ".pyi"],
        "command": ["pylsp"],
        "root_markers": ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile", ".git"],
    },
    "typescript": {
        "extensions": [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"],
        "command": ["typescript-language-server", "--stdio"],
        "root_markers": ["package.json", "tsconfig.json", "jsconfig.json", ".git"],
    },
    "go": {
        "extensions": [".go"],
        "command": ["gopls"],
        "root_markers": ["go.mod", "go.work", ".git"],
    },
    "rust": {
        "extensions": [".rs"],
        "command": ["rust-analyzer"],
        "root_markers": ["Cargo.toml", ".git"],
    },
}

# Extension to language ID mapping for LSP
# Comprehensive mapping matching OpenCode's LANGUAGE_EXTENSIONS
EXTENSION_TO_LANGUAGE: dict[str, str] = {
    # Python
    ".py": "python",
    ".pyi": "python",
    # TypeScript/JavaScript
    ".ts": "typescript",
    ".tsx": "typescriptreact",
    ".js": "javascript",
    ".jsx": "javascriptreact",
    ".mjs": "javascript",
    ".cjs": "javascript",
    ".mts": "typescript",
    ".cts": "typescript",
    # Go
    ".go": "go",
    # Rust
    ".rs": "rust",
    # Java
    ".java": "java",
    # C/C++
    ".c": "c",
    ".cpp": "cpp",
    ".cc": "cpp",
    ".cxx": "cpp",
    ".h": "c",
    ".hpp": "cpp",
    ".hh": "cpp",
    ".hxx": "cpp",
    # C#
    ".cs": "csharp",
    # Ruby
    ".rb": "ruby",
    # PHP
    ".php": "php",
    # Swift
    ".swift": "swift",
    # Kotlin
    ".kt": "kotlin",
    ".kts": "kotlin",
    # Scala
    ".scala": "scala",
    # R
    ".r": "r",
    ".R": "r",
    # Lua
    ".lua": "lua",
    # Dart
    ".dart": "dart",
    # Zig
    ".zig": "zig",
    ".zon": "zig",
    # Shell
    ".sh": "shellscript",
    ".bash": "shellscript",
    ".zsh": "shellscript",
    # Config/Data
    ".yaml": "yaml",
    ".yml": "yaml",
    ".json": "json",
    ".jsonc": "jsonc",
    ".xml": "xml",
    ".toml": "toml",
    ".ini": "ini",
    # Web
    ".html": "html",
    ".htm": "html",
    ".css": "css",
    ".scss": "scss",
    ".sass": "sass",
    ".less": "less",
    # Documentation
    ".md": "markdown",
    ".markdown": "markdown",
    # Database
    ".sql": "sql",
    # Docker
    ".dockerfile": "dockerfile",
    "Dockerfile": "dockerfile",
    # Make
    "Makefile": "makefile",
    ".makefile": "makefile",
    ".mk": "makefile",
    # Elixir
    ".ex": "elixir",
    ".exs": "elixir",
    # Erlang
    ".erl": "erlang",
    # Haskell
    ".hs": "haskell",
    # OCaml
    ".ml": "ocaml",
    ".mli": "ocaml",
    # F#
    ".fs": "fsharp",
    ".fsx": "fsharp",
    # Clojure
    ".clj": "clojure",
    ".cljs": "clojurescript",
    # Vue
    ".vue": "vue",
    # Svelte
    ".svelte": "svelte",
}


# --- Exception Classes ---


class LSPError(Exception):
    """Base exception for LSP errors."""


class LSPConnectionError(LSPError):
    """Failed to connect to language server."""


class LSPTimeoutError(LSPError):
    """Request timed out."""


class LSPServerNotFoundError(LSPError):
    """Language server binary not found."""


class LSPInitializationError(LSPError):
    """Server failed to initialize."""


# --- Type Definitions ---


@dataclass
class Position:
    """0-based line and character position."""
    line: int
    character: int

    def to_dict(self) -> dict[str, int]:
        return {"line": self.line, "character": self.character}


@dataclass
class Range:
    """Range with start and end positions."""
    start: Position
    end: Position

    def to_dict(self) -> dict[str, dict[str, int]]:
        return {"start": self.start.to_dict(), "end": self.end.to_dict()}

    @classmethod
    def from_dict(cls, data: dict) -> "Range":
        return cls(
            start=Position(data["start"]["line"], data["start"]["character"]),
            end=Position(data["end"]["line"], data["end"]["character"]),
        )


@dataclass
class HoverResult:
    """Result from a hover request."""
    contents: str
    range: Range | None = None
    language: str = ""


class DiagnosticSeverity(IntEnum):
    """LSP diagnostic severity levels."""
    ERROR = 1
    WARNING = 2
    INFO = 3
    HINT = 4


@dataclass
class Diagnostic:
    """A single diagnostic from an LSP server.

    Attributes:
        range: Location of the diagnostic in the file
        severity: Error, warning, info, or hint
        message: The diagnostic message
        source: Name of the source (e.g., "typescript", "pylsp")
        code: Optional diagnostic code
    """
    range: Range
    severity: DiagnosticSeverity
    message: str
    source: str = ""
    code: str | int | None = None

    @classmethod
    def from_dict(cls, data: dict) -> "Diagnostic":
        """Parse Diagnostic from LSP JSON."""
        range_data = data.get("range", {"start": {"line": 0, "character": 0},
                                         "end": {"line": 0, "character": 0}})
        severity = DiagnosticSeverity(data.get("severity", DiagnosticSeverity.ERROR))
        return cls(
            range=Range.from_dict(range_data),
            severity=severity,
            message=data.get("message", ""),
            source=data.get("source", ""),
            code=data.get("code"),
        )

    def pretty_format(self) -> str:
        """Format diagnostic as human-readable string."""
        severity_names = {
            DiagnosticSeverity.ERROR: "ERROR",
            DiagnosticSeverity.WARNING: "WARN",
            DiagnosticSeverity.INFO: "INFO",
            DiagnosticSeverity.HINT: "HINT",
        }
        severity_str = severity_names.get(self.severity, "ERROR")
        # Convert to 1-based for display
        line = self.range.start.line + 1
        col = self.range.start.character + 1
        source_str = f"[{self.source}] " if self.source else ""
        return f"{severity_str} {source_str}[{line}:{col}] {self.message}"


@dataclass
class DiagnosticsResult:
    """Result from a diagnostics request."""
    file_path: str
    diagnostics: list[Diagnostic]
    error_count: int = 0
    warning_count: int = 0
    info_count: int = 0
    hint_count: int = 0

    @classmethod
    def from_diagnostics(cls, file_path: str, diagnostics: list[Diagnostic]) -> "DiagnosticsResult":
        """Create result and compute counts."""
        error_count = sum(1 for d in diagnostics if d.severity == DiagnosticSeverity.ERROR)
        warning_count = sum(1 for d in diagnostics if d.severity == DiagnosticSeverity.WARNING)
        info_count = sum(1 for d in diagnostics if d.severity == DiagnosticSeverity.INFO)
        hint_count = sum(1 for d in diagnostics if d.severity == DiagnosticSeverity.HINT)
        return cls(
            file_path=file_path,
            diagnostics=diagnostics,
            error_count=error_count,
            warning_count=warning_count,
            info_count=info_count,
            hint_count=hint_count,
        )

    def format_output(self) -> str:
        """Format diagnostics as human-readable string."""
        if not self.diagnostics:
            return f"No diagnostics found for {self.file_path}"

        lines = [f"Diagnostics for {self.file_path}:"]
        lines.append(f"\nSummary: {self.error_count} errors, {self.warning_count} warnings\n")

        for diag in self.diagnostics:
            lines.append(f"  {diag.pretty_format()}")

        return "\n".join(lines)


@dataclass
class ServerConfig:
    """Configuration for a language server."""
    id: str
    extensions: list[str]
    command: list[str]
    root_markers: list[str]
    init_options: dict = field(default_factory=dict)


# --- Utility Functions ---


def get_language_id(extension: str) -> str:
    """Get LSP language ID from file extension."""
    return EXTENSION_TO_LANGUAGE.get(extension, "plaintext")


def find_workspace_root(file_path: str, markers: list[str]) -> str:
    """Find workspace root by searching upward for marker files.

    Args:
        file_path: Path to file
        markers: List of marker files to search for

    Returns:
        Path to workspace root directory
    """
    path = Path(file_path).resolve()
    current = path.parent if path.is_file() else path

    while current != current.parent:
        for marker in markers:
            if (current / marker).exists():
                return str(current)
        current = current.parent

    # Fallback to file's directory
    return str(path.parent if path.is_file() else path)


def parse_hover_contents(contents: Any) -> str:
    """Parse hover contents from various LSP formats.

    LSP hover contents can be:
    - string: Plain text
    - MarkupContent: {kind: "plaintext"|"markdown", value: string}
    - MarkedString: {language: string, value: string} or string
    - MarkedString[]: Array of the above

    Args:
        contents: Raw hover contents from LSP response

    Returns:
        Formatted string representation
    """
    if contents is None:
        return ""

    if isinstance(contents, str):
        return contents

    if isinstance(contents, dict):
        # MarkupContent or MarkedString
        if "value" in contents:
            value = contents["value"]
            kind = contents.get("kind", "")
            language = contents.get("language", "")

            if language:
                return f"```{language}\n{value}\n```"
            return value
        return str(contents)

    if isinstance(contents, list):
        # Array of MarkedString
        parts = []
        for item in contents:
            parsed = parse_hover_contents(item)
            if parsed:
                parts.append(parsed)
        return "\n\n".join(parts)

    return str(contents)


def get_server_for_file(file_path: str) -> tuple[str, dict[str, Any]] | None:
    """Get server configuration for a file based on extension.

    Args:
        file_path: Path to file

    Returns:
        Tuple of (server_id, config) or None if no server found
    """
    ext = Path(file_path).suffix.lower()

    for server_id, config in LSP_SERVERS.items():
        if ext in config["extensions"]:
            return server_id, config

    return None


# --- LSP Connection (JSON-RPC 2.0 over stdio) ---


class LSPConnection:
    """JSON-RPC 2.0 connection over stdio with Content-Length framing."""

    def __init__(
        self,
        process: asyncio.subprocess.Process,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ):
        self.process = process
        self.reader = reader
        self.writer = writer
        self._request_id = 0
        self._pending_requests: dict[int, asyncio.Future[dict]] = {}
        self._notification_handlers: dict[str, Callable[[dict], None]] = {}
        self._response_task: asyncio.Task | None = None
        self._closed = False

    def on_notification(self, method: str, handler: Callable[[dict], None]) -> None:
        """Register a handler for a notification method.

        Args:
            method: LSP notification method name (e.g., "textDocument/publishDiagnostics")
            handler: Callback function that receives the params dict
        """
        self._notification_handlers[method] = handler

    async def start_response_listener(self) -> None:
        """Start background task to listen for responses."""
        self._response_task = asyncio.create_task(self._response_listener())

    async def _response_listener(self) -> None:
        """Background task to read responses and match to pending requests."""
        try:
            while not self._closed:
                try:
                    message = await self._read_message()
                    if message is None:
                        break

                    # Check if this is a response (has id but no method)
                    msg_id = message.get("id")
                    method = message.get("method")

                    if msg_id is not None and method is None:
                        # This is a response to a request
                        future = self._pending_requests.pop(msg_id, None)
                        if future and not future.done():
                            if "error" in message:
                                future.set_exception(
                                    LSPError(f"LSP error: {message['error']}")
                                )
                            else:
                                future.set_result(message.get("result"))
                    elif method is not None and msg_id is None:
                        # This is a notification from the server
                        handler = self._notification_handlers.get(method)
                        if handler:
                            try:
                                handler(message.get("params", {}))
                            except Exception:
                                # Don't let handler errors crash the listener
                                logger.debug("LSP notification handler failed", exc_info=True)
                    # Ignore requests from server (method + id) - we don't handle those
                except asyncio.CancelledError:
                    break
                except Exception:
                    # Connection error, stop listening
                    break
        finally:
            # Cancel any pending requests
            for future in self._pending_requests.values():
                if not future.done():
                    future.cancel()

    async def _read_message(self) -> dict | None:
        """Read Content-Length framed JSON message from reader."""
        headers: dict[str, str] = {}

        # Read headers until empty line
        while True:
            line = await self.reader.readline()
            if not line:
                return None

            line_str = line.decode("utf-8").strip()
            if not line_str:
                break

            if ":" in line_str:
                key, value = line_str.split(":", 1)
                headers[key.strip().lower()] = value.strip()

        # Read body based on Content-Length
        content_length = int(headers.get("content-length", 0))
        if content_length == 0:
            return None

        body = await self.reader.readexactly(content_length)
        return json.loads(body.decode("utf-8"))

    async def _write_message(self, message: dict) -> None:
        """Write Content-Length framed JSON message to writer."""
        body = json.dumps(message).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8")
        self.writer.write(header + body)
        await self.writer.drain()

    async def send_request(self, method: str, params: dict) -> Any:
        """Send JSON-RPC request and await response.

        Args:
            method: LSP method name
            params: Request parameters

        Returns:
            Response result

        Raises:
            LSPTimeoutError: If request times out
            LSPError: If server returns error
        """
        self._request_id += 1
        request_id = self._request_id

        future: asyncio.Future[dict] = asyncio.get_event_loop().create_future()
        self._pending_requests[request_id] = future

        message = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        }

        await self._write_message(message)

        try:
            result = await asyncio.wait_for(future, timeout=LSP_REQUEST_TIMEOUT_SECONDS)
            return result
        except asyncio.TimeoutError:
            self._pending_requests.pop(request_id, None)
            raise LSPTimeoutError(f"Request '{method}' timed out")

    async def send_notification(self, method: str, params: dict) -> None:
        """Send JSON-RPC notification (no response expected).

        Args:
            method: LSP method name
            params: Notification parameters
        """
        message = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        }
        await self._write_message(message)

    async def close(self) -> None:
        """Close connection and terminate process."""
        self._closed = True

        if self._response_task:
            self._response_task.cancel()
            try:
                await self._response_task
            except asyncio.CancelledError:
                logger.debug("LSP response task cancelled during close")

        self.writer.close()
        try:
            await asyncio.wait_for(self.writer.wait_closed(), timeout=1.0)
        except Exception:
            logger.debug("LSP writer did not close cleanly", exc_info=True)

        # Terminate process
        try:
            self.process.terminate()
            await asyncio.wait_for(self.process.wait(), timeout=2.0)
        except asyncio.TimeoutError:
            self.process.kill()
            await self.process.wait()
        except Exception:
            logger.debug("LSP process did not terminate cleanly", exc_info=True)


# --- LSP Client ---


class LSPClient:
    """LSP client for a single language server instance."""

    def __init__(
        self,
        server_id: str,
        root: str,
        connection: LSPConnection,
    ):
        self.server_id = server_id
        self.root = root
        self.connection = connection
        self.capabilities: dict = {}
        self._file_versions: dict[str, int] = {}
        self._file_versions_lock = asyncio.Lock()
        self._initialized = False
        self._open_files: set[str] = set()

        # Diagnostic storage
        self._diagnostics: dict[str, list[Diagnostic]] = {}  # file_path -> diagnostics
        self._diagnostics_lock = asyncio.Lock()
        self._diagnostics_events: dict[str, asyncio.Event] = {}  # file_path -> event

    @classmethod
    async def create(
        cls,
        server_id: str,
        root: str,
        command: list[str],
        init_options: dict | None = None,
    ) -> "LSPClient":
        """Factory method to spawn server and initialize connection.

        Args:
            server_id: Server identifier
            root: Workspace root path
            command: Command to spawn server
            init_options: Optional initialization options

        Returns:
            Initialized LSPClient

        Raises:
            LSPServerNotFoundError: If server binary not found
            LSPInitializationError: If initialization fails
        """
        # Check if command exists
        if not shutil.which(command[0]):
            raise LSPServerNotFoundError(
                f"LSP server '{command[0]}' not found. "
                f"Please install the language server."
            )

        # Spawn process
        try:
            process = await asyncio.create_subprocess_exec(
                *command,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=root,
            )
        except Exception as e:
            raise LSPConnectionError(f"Failed to spawn LSP server: {e}")

        if process.stdin is None or process.stdout is None:
            raise LSPConnectionError("Failed to get process pipes")

        # Create connection
        connection = LSPConnection(
            process=process,
            reader=process.stdout,
            writer=process.stdin,
        )

        # Start response listener
        await connection.start_response_listener()

        # Create client
        client = cls(server_id, root, connection)

        # Set up notification handlers
        client._setup_handlers()

        # Initialize
        try:
            await client.initialize(init_options)
        except Exception as e:
            await connection.close()
            raise LSPInitializationError(f"Failed to initialize LSP server: {e}")

        return client

    def _setup_handlers(self) -> None:
        """Set up notification handlers for the connection."""
        self.connection.on_notification(
            "textDocument/publishDiagnostics",
            self._handle_publish_diagnostics,
        )

    def _handle_publish_diagnostics(self, params: dict) -> None:
        """Handle textDocument/publishDiagnostics notification.

        Args:
            params: Notification params with uri and diagnostics array
        """
        uri = params.get("uri", "")
        # Convert file:// URI to path
        if uri.startswith("file://"):
            file_path = uri[7:]
        else:
            file_path = uri

        raw_diagnostics = params.get("diagnostics", [])
        diagnostics = [Diagnostic.from_dict(d) for d in raw_diagnostics]

        # Use sync approach since this is called from async context
        # The lock and event are asyncio primitives but we can't await here
        # Store directly - thread-safe due to GIL for simple dict operations
        self._diagnostics[file_path] = diagnostics

        # Signal any waiters
        if file_path in self._diagnostics_events:
            self._diagnostics_events[file_path].set()

    async def initialize(self, init_options: dict | None = None) -> dict:
        """Send initialize request and initialized notification.

        Args:
            init_options: Optional initialization options

        Returns:
            Server capabilities
        """
        params = {
            "processId": os.getpid(),
            "rootUri": f"file://{self.root}",
            "rootPath": self.root,
            "capabilities": {
                "textDocument": {
                    "hover": {
                        "contentFormat": ["markdown", "plaintext"],
                    },
                    "synchronization": {
                        "didOpen": True,
                        "didClose": True,
                    },
                },
            },
        }

        if init_options:
            params["initializationOptions"] = init_options

        # Send initialize with longer timeout
        try:
            result = await asyncio.wait_for(
                self.connection.send_request("initialize", params),
                timeout=LSP_INIT_TIMEOUT_SECONDS,
            )
        except asyncio.TimeoutError:
            raise LSPInitializationError("Initialize request timed out")

        self.capabilities = result.get("capabilities", {}) if result else {}

        # Send initialized notification
        await self.connection.send_notification("initialized", {})

        self._initialized = True
        return self.capabilities

    async def open_file(self, file_path: str) -> None:
        """Send textDocument/didOpen notification.

        Args:
            file_path: Path to file to open
        """
        if file_path in self._open_files:
            return

        try:
            with open(file_path, "r", encoding="utf-8") as f:
                content = f.read()
        except Exception as e:
            raise LSPError(f"Failed to read file: {e}")

        ext = Path(file_path).suffix
        language_id = get_language_id(ext)

        async with self._file_versions_lock:
            version = self._file_versions.get(file_path, 0)
            self._file_versions[file_path] = version

        params = {
            "textDocument": {
                "uri": f"file://{file_path}",
                "languageId": language_id,
                "version": version,
                "text": content,
            }
        }

        await self.connection.send_notification("textDocument/didOpen", params)
        self._open_files.add(file_path)

    async def hover(
        self,
        file_path: str,
        line: int,
        character: int,
    ) -> HoverResult | None:
        """Send textDocument/hover request.

        Args:
            file_path: Path to source file
            line: 0-based line number
            character: 0-based character offset

        Returns:
            HoverResult or None if no hover info
        """
        # Ensure file is open
        await self.open_file(file_path)

        params = {
            "textDocument": {
                "uri": f"file://{file_path}",
            },
            "position": {
                "line": line,
                "character": character,
            },
        }

        result = await self.connection.send_request("textDocument/hover", params)

        if result is None:
            return None

        contents = parse_hover_contents(result.get("contents"))
        if not contents:
            return None

        hover_range = None
        if "range" in result:
            hover_range = Range.from_dict(result["range"])

        ext = Path(file_path).suffix
        language = get_language_id(ext)

        return HoverResult(contents=contents, range=hover_range, language=language)

    async def workspace_symbol(self, query: str) -> list[dict[str, Any]]:
        """Search for symbols across the workspace.

        Args:
            query: Search query string

        Returns:
            List of symbol information dicts with name, kind, location
        """
        params = {"query": query}
        result = await self.connection.send_request("workspace/symbol", params)

        if result is None:
            return []

        # Parse result as list of SymbolInformation
        symbols = []
        for item in result:
            symbol = {
                "name": item.get("name", ""),
                "kind": item.get("kind", 0),
                "location": item.get("location", {}),
            }
            if "containerName" in item:
                symbol["containerName"] = item["containerName"]
            symbols.append(symbol)

        return symbols

    async def document_symbol(self, file_path: str) -> list[dict[str, Any]]:
        """Get symbols defined in a document.

        Args:
            file_path: Path to source file

        Returns:
            List of document symbol dicts with name, kind, range, children
        """
        # Ensure file is open
        await self.open_file(file_path)

        params = {
            "textDocument": {
                "uri": f"file://{file_path}",
            }
        }

        result = await self.connection.send_request("textDocument/documentSymbol", params)

        if result is None:
            return []

        # Result can be DocumentSymbol[] or SymbolInformation[]
        # Both have name and kind fields
        return result if isinstance(result, list) else []

    async def definition(
        self,
        file_path: str,
        line: int,
        character: int,
    ) -> list[dict[str, Any]]:
        """Go to definition of symbol at position.

        Args:
            file_path: Path to source file
            line: 0-based line number
            character: 0-based character offset

        Returns:
            List of location dicts with uri, range
        """
        # Ensure file is open
        await self.open_file(file_path)

        params = {
            "textDocument": {
                "uri": f"file://{file_path}",
            },
            "position": {
                "line": line,
                "character": character,
            },
        }

        result = await self.connection.send_request("textDocument/definition", params)

        if result is None:
            return []

        # Result can be Location, Location[], or LocationLink[]
        if isinstance(result, dict):
            return [result]
        elif isinstance(result, list):
            return result
        return []

    async def references(
        self,
        file_path: str,
        line: int,
        character: int,
        include_declaration: bool = True,
    ) -> list[dict[str, Any]]:
        """Find all references to symbol at position.

        Args:
            file_path: Path to source file
            line: 0-based line number
            character: 0-based character offset
            include_declaration: Whether to include the declaration

        Returns:
            List of location dicts with uri, range
        """
        # Ensure file is open
        await self.open_file(file_path)

        params = {
            "textDocument": {
                "uri": f"file://{file_path}",
            },
            "position": {
                "line": line,
                "character": character,
            },
            "context": {
                "includeDeclaration": include_declaration,
            },
        }

        result = await self.connection.send_request("textDocument/references", params)

        if result is None:
            return []

        # Result is Location[]
        return result if isinstance(result, list) else []

    async def wait_for_diagnostics(
        self,
        file_path: str,
        timeout: float = LSP_DIAGNOSTICS_TIMEOUT_SECONDS,
    ) -> list[Diagnostic]:
        """Wait for diagnostics to be published for a file.

        Opens the file if not already open, then waits for the server
        to publish diagnostics via textDocument/publishDiagnostics.

        Args:
            file_path: Path to file
            timeout: Maximum time to wait in seconds

        Returns:
            List of diagnostics for the file
        """
        # Create event for this file
        event = asyncio.Event()
        self._diagnostics_events[file_path] = event

        try:
            # Open file to trigger diagnostics
            was_open = file_path in self._open_files
            await self.open_file(file_path)

            # If file was already open, diagnostics might already be stored
            if was_open and file_path in self._diagnostics:
                return self._diagnostics.get(file_path, [])

            # Wait for diagnostics notification
            try:
                await asyncio.wait_for(event.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                # Return whatever we have (might be empty)
                return self._diagnostics.get(file_path, [])

            return self._diagnostics.get(file_path, [])
        finally:
            # Clean up event
            self._diagnostics_events.pop(file_path, None)

    def get_diagnostics(self, file_path: str) -> list[Diagnostic]:
        """Get current diagnostics for a file without waiting.

        Args:
            file_path: Path to file

        Returns:
            List of diagnostics (may be empty if not yet received)
        """
        return self._diagnostics.get(file_path, [])

    def get_all_diagnostics(self) -> dict[str, list[Diagnostic]]:
        """Get all stored diagnostics.

        Returns:
            Dict mapping file paths to their diagnostics
        """
        return dict(self._diagnostics)

    async def close(self) -> None:
        """Shutdown server gracefully."""
        if self._initialized:
            try:
                # Send shutdown request
                await asyncio.wait_for(
                    self.connection.send_request("shutdown", {}),
                    timeout=2.0,
                )
                # Send exit notification
                await self.connection.send_notification("exit", {})
            except Exception:
                logger.debug("LSP shutdown request failed", exc_info=True)

        await self.connection.close()


# --- LSP Manager (Singleton) ---


class LSPManager:
    """Singleton manager for LSP client lifecycle and pooling."""

    _instance: ClassVar["LSPManager | None"] = None
    _lock: ClassVar[asyncio.Lock] = asyncio.Lock()

    def __init__(self):
        self._clients: list[LSPClient] = []
        self._broken: set[tuple[str, str]] = set()  # (server_id, root) pairs
        self._client_lock = asyncio.Lock()

    @classmethod
    async def get_instance(cls) -> "LSPManager":
        """Get or create singleton instance."""
        async with cls._lock:
            if cls._instance is None:
                cls._instance = cls()
            return cls._instance

    @classmethod
    def reset_instance(cls) -> None:
        """Reset singleton instance (for testing)."""
        cls._instance = None

    def _is_broken(self, server_id: str, root: str) -> bool:
        """Check if server+root combination has failed previously."""
        return (server_id, root) in self._broken

    def _mark_broken(self, server_id: str, root: str) -> None:
        """Mark server+root as broken to prevent retry loops."""
        self._broken.add((server_id, root))

    def _find_client(self, server_id: str, root: str) -> LSPClient | None:
        """Find existing client by server ID and root."""
        for client in self._clients:
            if client.server_id == server_id and client.root == root:
                return client
        return None

    async def get_client(self, file_path: str) -> LSPClient | None:
        """Get or spawn client for file.

        Args:
            file_path: Path to file

        Returns:
            LSPClient or None if unavailable
        """
        # Get server config for file
        server_info = get_server_for_file(file_path)
        if server_info is None:
            return None

        server_id, config = server_info

        # Find workspace root
        root = find_workspace_root(file_path, config["root_markers"])

        # Check if broken
        if self._is_broken(server_id, root):
            return None

        async with self._client_lock:
            # Check for existing client
            client = self._find_client(server_id, root)
            if client:
                return client

            # Evict oldest client if at max
            if len(self._clients) >= LSP_MAX_CLIENTS:
                oldest = self._clients.pop(0)
                try:
                    await oldest.close()
                except Exception:
                    logger.debug("LSP client eviction close failed", exc_info=True)

            # Spawn new client
            try:
                client = await LSPClient.create(
                    server_id=server_id,
                    root=root,
                    command=config["command"],
                )
                self._clients.append(client)
                return client
            except LSPServerNotFoundError:
                self._mark_broken(server_id, root)
                raise
            except Exception as e:
                self._mark_broken(server_id, root)
                raise LSPError(f"Failed to create LSP client: {e}")

    async def shutdown_all(self) -> None:
        """Shutdown all active clients."""
        async with self._client_lock:
            for client in self._clients:
                try:
                    await client.close()
                except Exception:
                    logger.debug("LSP client shutdown failed", exc_info=True)
            self._clients.clear()

    def get_all_diagnostics(self) -> dict[str, list[Diagnostic]]:
        """Get aggregated diagnostics from all active clients.

        Returns:
            Dict mapping file paths to lists of diagnostics,
            aggregated across all LSP clients.
        """
        result: dict[str, list[Diagnostic]] = {}

        for client in self._clients:
            client_diagnostics = client.get_all_diagnostics()
            for file_path, diags in client_diagnostics.items():
                if file_path in result:
                    result[file_path].extend(diags)
                else:
                    result[file_path] = list(diags)

        return result


# --- Public API ---


_manager: LSPManager | None = None


async def get_lsp_manager() -> LSPManager:
    """Get the LSP manager instance."""
    return await LSPManager.get_instance()


async def hover(file_path: str, line: int, character: int) -> dict[str, Any]:
    """Get type information and documentation for a symbol at a position.

    Args:
        file_path: Absolute path to the source file
        line: 0-based line number
        character: 0-based character offset within the line

    Returns:
        dict with:
            - success: bool
            - contents: str (formatted markdown/plaintext)
            - range: dict with start/end positions (optional)
            - language: str language identifier
            - error: str error message if success=False
    """
    # Validate file exists
    if not os.path.isfile(file_path):
        return {
            "success": False,
            "error": f"File not found: {file_path}",
        }

    # Check if we have a server for this file type
    server_info = get_server_for_file(file_path)
    if server_info is None:
        ext = Path(file_path).suffix
        supported = ", ".join(
            ext for config in LSP_SERVERS.values() for ext in config["extensions"]
        )
        return {
            "success": False,
            "error": f"No LSP server available for '{ext}' files. Supported: {supported}",
        }

    try:
        manager = await get_lsp_manager()
        client = await manager.get_client(file_path)

        if client is None:
            return {
                "success": False,
                "error": "Failed to get LSP client",
            }

        result = await client.hover(file_path, line, character)

        if result is None:
            return {
                "success": True,
                "contents": "No hover information available at this position",
                "language": get_language_id(Path(file_path).suffix),
            }

        response: dict[str, Any] = {
            "success": True,
            "contents": result.contents,
            "language": result.language,
        }

        if result.range:
            response["range"] = result.range.to_dict()

        return response

    except LSPServerNotFoundError as e:
        server_id = server_info[0]
        install_hints = {
            "python": "pip install python-lsp-server",
            "typescript": "npm install -g typescript-language-server typescript",
            "go": "go install golang.org/x/tools/gopls@latest",
            "rust": "rustup component add rust-analyzer",
        }
        hint = install_hints.get(server_id, "")
        error_msg = str(e)
        if hint:
            error_msg += f" Install with: {hint}"
        return {
            "success": False,
            "error": error_msg,
        }

    except LSPTimeoutError as e:
        return {
            "success": False,
            "error": f"LSP request timed out: {e}",
        }

    except LSPError as e:
        return {
            "success": False,
            "error": str(e),
        }

    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {e}",
        }


async def diagnostics(
    file_path: str,
    timeout: float = LSP_DIAGNOSTICS_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Get diagnostics (errors, warnings, hints) for a file.

    Opens the file in the language server and waits for diagnostics
    to be published via textDocument/publishDiagnostics.

    Args:
        file_path: Absolute path to the source file
        timeout: Maximum time to wait for diagnostics in seconds

    Returns:
        dict with:
            - success: bool
            - file_path: str
            - diagnostics: list of formatted diagnostic strings
            - error_count: int
            - warning_count: int
            - summary: str human-readable summary
            - error: str error message if success=False
    """
    # Validate file exists
    if not os.path.isfile(file_path):
        return {
            "success": False,
            "error": f"File not found: {file_path}",
        }

    # Check if we have a server for this file type
    server_info = get_server_for_file(file_path)
    if server_info is None:
        ext = Path(file_path).suffix
        supported = ", ".join(
            ext for config in LSP_SERVERS.values() for ext in config["extensions"]
        )
        return {
            "success": False,
            "error": f"No LSP server available for '{ext}' files. Supported: {supported}",
        }

    try:
        manager = await get_lsp_manager()
        client = await manager.get_client(file_path)

        if client is None:
            return {
                "success": False,
                "error": "Failed to get LSP client",
            }

        # Wait for diagnostics
        diag_list = await client.wait_for_diagnostics(file_path, timeout=timeout)

        # Create result
        result = DiagnosticsResult.from_diagnostics(file_path, diag_list)

        return {
            "success": True,
            "file_path": file_path,
            "diagnostics": [d.pretty_format() for d in result.diagnostics],
            "error_count": result.error_count,
            "warning_count": result.warning_count,
            "info_count": result.info_count,
            "hint_count": result.hint_count,
            "summary": f"{result.error_count} errors, {result.warning_count} warnings",
            "formatted_output": result.format_output(),
        }

    except LSPServerNotFoundError as e:
        server_id = server_info[0]
        install_hints = {
            "python": "pip install python-lsp-server",
            "typescript": "npm install -g typescript-language-server typescript",
            "go": "go install golang.org/x/tools/gopls@latest",
            "rust": "rustup component add rust-analyzer",
        }
        hint = install_hints.get(server_id, "")
        error_msg = str(e)
        if hint:
            error_msg += f" Install with: {hint}"
        return {
            "success": False,
            "error": error_msg,
        }

    except LSPTimeoutError as e:
        return {
            "success": False,
            "error": f"LSP request timed out: {e}",
        }

    except LSPError as e:
        return {
            "success": False,
            "error": str(e),
        }

    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {e}",
        }


async def touch_file(
    file_path: str,
    wait_for_diagnostics: bool = True,
    timeout: float = LSP_DIAGNOSTICS_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Open a file in the LSP server and optionally wait for diagnostics.

    This is useful for pre-checking a file before making edits to understand
    its current state (errors, warnings, etc.).

    Args:
        file_path: Absolute path to the source file
        wait_for_diagnostics: Whether to wait for diagnostics after opening
        timeout: Maximum time to wait for diagnostics in seconds

    Returns:
        dict with:
            - success: bool
            - file_path: str
            - diagnostics: list of diagnostic dicts (if wait_for_diagnostics=True)
            - error_count: int
            - warning_count: int
            - error: str error message if success=False
    """
    # Validate file exists
    if not os.path.isfile(file_path):
        return {
            "success": False,
            "error": f"File not found: {file_path}",
        }

    # Check if we have a server for this file type
    server_info = get_server_for_file(file_path)
    if server_info is None:
        ext = Path(file_path).suffix
        supported = ", ".join(
            ext for config in LSP_SERVERS.values() for ext in config["extensions"]
        )
        return {
            "success": False,
            "error": f"No LSP server available for '{ext}' files. Supported: {supported}",
        }

    try:
        manager = await get_lsp_manager()
        client = await manager.get_client(file_path)

        if client is None:
            return {
                "success": False,
                "error": "Failed to get LSP client",
            }

        # Open file
        await client.open_file(file_path)

        if wait_for_diagnostics:
            # Wait for diagnostics
            diag_list = await client.wait_for_diagnostics(file_path, timeout=timeout)
            result = DiagnosticsResult.from_diagnostics(file_path, diag_list)

            return {
                "success": True,
                "file_path": file_path,
                "diagnostics": [d.pretty_format() for d in result.diagnostics],
                "error_count": result.error_count,
                "warning_count": result.warning_count,
                "summary": f"{result.error_count} errors, {result.warning_count} warnings",
            }
        else:
            return {
                "success": True,
                "file_path": file_path,
                "message": "File opened in LSP server",
            }

    except LSPServerNotFoundError as e:
        server_id = server_info[0]
        install_hints = {
            "python": "pip install python-lsp-server",
            "typescript": "npm install -g typescript-language-server typescript",
            "go": "go install golang.org/x/tools/gopls@latest",
            "rust": "rustup component add rust-analyzer",
        }
        hint = install_hints.get(server_id, "")
        error_msg = str(e)
        if hint:
            error_msg += f" Install with: {hint}"
        return {
            "success": False,
            "error": error_msg,
        }

    except LSPError as e:
        return {
            "success": False,
            "error": str(e),
        }

    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {e}",
        }


async def get_all_diagnostics_summary() -> dict[str, Any]:
    """Get aggregated diagnostics from all active LSP clients.

    Returns all diagnostics currently stored across all language servers,
    aggregated by file path.

    Returns:
        dict with:
            - success: bool
            - diagnostics: dict mapping file paths to list of diagnostic strings
            - total_errors: int
            - total_warnings: int
            - file_count: int
            - error: str error message if success=False
    """
    try:
        manager = await get_lsp_manager()
        all_diags = manager.get_all_diagnostics()

        # Format diagnostics and count totals
        formatted: dict[str, list[str]] = {}
        total_errors = 0
        total_warnings = 0

        for file_path, diags in all_diags.items():
            formatted[file_path] = [d.pretty_format() for d in diags]
            total_errors += sum(1 for d in diags if d.severity == DiagnosticSeverity.ERROR)
            total_warnings += sum(1 for d in diags if d.severity == DiagnosticSeverity.WARNING)

        return {
            "success": True,
            "diagnostics": formatted,
            "total_errors": total_errors,
            "total_warnings": total_warnings,
            "file_count": len(all_diags),
        }

    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {e}",
        }


async def workspace_symbol(query: str, file_path: str | None = None) -> dict[str, Any]:
    """Search for symbols across the workspace.

    Args:
        query: Search query string (symbol name or pattern)
        file_path: Optional file path to determine workspace (uses first available client if None)

    Returns:
        dict with:
            - success: bool
            - symbols: list of dicts with name, kind, location, containerName
            - count: int number of symbols found
            - error: str error message if success=False
    """
    try:
        manager = await get_lsp_manager()

        # Get client
        if file_path and os.path.isfile(file_path):
            client = await manager.get_client(file_path)
        else:
            # Use first available client
            async with manager._client_lock:
                if not manager._clients:
                    return {
                        "success": False,
                        "error": "No LSP clients available. Open a file first.",
                    }
                client = manager._clients[0]

        if client is None:
            return {
                "success": False,
                "error": "Failed to get LSP client",
            }

        # Search for symbols
        symbols = await client.workspace_symbol(query)

        return {
            "success": True,
            "symbols": symbols,
            "count": len(symbols),
        }

    except LSPError as e:
        return {
            "success": False,
            "error": str(e),
        }

    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {e}",
        }


async def go_to_definition(file_path: str, line: int, character: int) -> dict[str, Any]:
    """Go to the definition of a symbol at the given position.

    Args:
        file_path: Absolute path to the source file
        line: 0-based line number
        character: 0-based character offset within the line

    Returns:
        dict with:
            - success: bool
            - definitions: list of dicts with uri (file path) and range
            - count: int number of definitions found
            - error: str error message if success=False
    """
    # Validate file exists
    if not os.path.isfile(file_path):
        return {
            "success": False,
            "error": f"File not found: {file_path}",
        }

    # Check if we have a server for this file type
    server_info = get_server_for_file(file_path)
    if server_info is None:
        ext = Path(file_path).suffix
        supported = ", ".join(
            ext for config in LSP_SERVERS.values() for ext in config["extensions"]
        )
        return {
            "success": False,
            "error": f"No LSP server available for '{ext}' files. Supported: {supported}",
        }

    try:
        manager = await get_lsp_manager()
        client = await manager.get_client(file_path)

        if client is None:
            return {
                "success": False,
                "error": "Failed to get LSP client",
            }

        # Get definitions
        definitions = await client.definition(file_path, line, character)

        # Convert file:// URIs to paths
        for defn in definitions:
            if "uri" in defn and defn["uri"].startswith("file://"):
                defn["uri"] = defn["uri"][7:]

        return {
            "success": True,
            "definitions": definitions,
            "count": len(definitions),
        }

    except LSPServerNotFoundError as e:
        server_id = server_info[0]
        install_hints = {
            "python": "pip install python-lsp-server",
            "typescript": "npm install -g typescript-language-server typescript",
            "go": "go install golang.org/x/tools/gopls@latest",
            "rust": "rustup component add rust-analyzer",
        }
        hint = install_hints.get(server_id, "")
        error_msg = str(e)
        if hint:
            error_msg += f" Install with: {hint}"
        return {
            "success": False,
            "error": error_msg,
        }

    except LSPTimeoutError as e:
        return {
            "success": False,
            "error": f"LSP request timed out: {e}",
        }

    except LSPError as e:
        return {
            "success": False,
            "error": str(e),
        }

    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {e}",
        }


async def find_references(
    file_path: str,
    line: int,
    character: int,
    include_declaration: bool = True,
) -> dict[str, Any]:
    """Find all references to a symbol at the given position.

    Args:
        file_path: Absolute path to the source file
        line: 0-based line number
        character: 0-based character offset within the line
        include_declaration: Whether to include the symbol's declaration

    Returns:
        dict with:
            - success: bool
            - references: list of dicts with uri (file path) and range
            - count: int number of references found
            - files: list of unique file paths containing references
            - error: str error message if success=False
    """
    # Validate file exists
    if not os.path.isfile(file_path):
        return {
            "success": False,
            "error": f"File not found: {file_path}",
        }

    # Check if we have a server for this file type
    server_info = get_server_for_file(file_path)
    if server_info is None:
        ext = Path(file_path).suffix
        supported = ", ".join(
            ext for config in LSP_SERVERS.values() for ext in config["extensions"]
        )
        return {
            "success": False,
            "error": f"No LSP server available for '{ext}' files. Supported: {supported}",
        }

    try:
        manager = await get_lsp_manager()
        client = await manager.get_client(file_path)

        if client is None:
            return {
                "success": False,
                "error": "Failed to get LSP client",
            }

        # Get references
        references = await client.references(file_path, line, character, include_declaration)

        # Convert file:// URIs to paths and collect unique files
        unique_files = set()
        for ref in references:
            if "uri" in ref and ref["uri"].startswith("file://"):
                ref["uri"] = ref["uri"][7:]
                unique_files.add(ref["uri"])

        return {
            "success": True,
            "references": references,
            "count": len(references),
            "files": sorted(list(unique_files)),
        }

    except LSPServerNotFoundError as e:
        server_id = server_info[0]
        install_hints = {
            "python": "pip install python-lsp-server",
            "typescript": "npm install -g typescript-language-server typescript",
            "go": "go install golang.org/x/tools/gopls@latest",
            "rust": "rustup component add rust-analyzer",
        }
        hint = install_hints.get(server_id, "")
        error_msg = str(e)
        if hint:
            error_msg += f" Install with: {hint}"
        return {
            "success": False,
            "error": error_msg,
        }

    except LSPTimeoutError as e:
        return {
            "success": False,
            "error": f"LSP request timed out: {e}",
        }

    except LSPError as e:
        return {
            "success": False,
            "error": str(e),
        }

    except Exception as e:
        return {
            "success": False,
            "error": f"Unexpected error: {e}",
        }
