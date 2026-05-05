"""
PTY session management for interactive command execution.

This module provides PTYManager for creating and managing pseudo-terminal (PTY)
sessions, enabling interactive command execution with stdin/stdout support.
"""

import asyncio
import os
import pty
import pwd
import select
import signal
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional


# Constants
DEFAULT_MAX_SESSIONS = 10
DEFAULT_SESSION_TIMEOUT = 300  # 5 minutes
DEFAULT_READ_TIMEOUT_MS = 100
DEFAULT_MAX_READ_BYTES = 65536


def default_user_shell() -> str:
    """Resolve the user's configured login shell with conservative fallbacks."""
    try:
        shell = pwd.getpwuid(os.getuid()).pw_shell
        if shell:
            return shell
    except Exception:
        pass
    return os.environ.get("SHELL") or "/bin/zsh"


@dataclass
class PTYSession:
    """Represents an active PTY session.

    Attributes:
        id: Unique session identifier
        master_fd: Master file descriptor for PTY
        slave_fd: Slave file descriptor (unused in parent)
        pid: Process ID of child
        output_buffer: Accumulated output from process
        created_at: Session creation timestamp
        last_activity: Last read/write timestamp
    """
    id: str
    master_fd: int
    slave_fd: int
    pid: int
    output_buffer: str = ""
    created_at: float = field(default_factory=time.time)
    last_activity: float = field(default_factory=time.time)


class PTYManager:
    """Manages multiple PTY sessions for interactive command execution.

    This class handles the lifecycle of pseudo-terminal sessions, including:
    - Creating new PTY sessions with forked processes
    - Writing input to running sessions
    - Reading output from sessions
    - Cleaning up stale/timed-out sessions
    - Graceful process termination

    Examples:
        >>> manager = PTYManager()
        >>> session = await manager.create_session("python3", workdir="/tmp")
        >>> output = await manager.read_output(session.id, timeout_ms=1000)
        >>> await manager.write_input(session.id, "print('hello')\\n")
        >>> output = await manager.read_output(session.id, timeout_ms=1000)
        >>> await manager.close_session(session.id)
    """

    def __init__(
        self,
        max_sessions: int = DEFAULT_MAX_SESSIONS,
        session_timeout: float = DEFAULT_SESSION_TIMEOUT,
    ):
        """Initialize PTYManager.

        Args:
            max_sessions: Maximum number of concurrent sessions
            session_timeout: Session timeout in seconds
        """
        self.sessions: dict[str, PTYSession] = {}
        self.max_sessions = max_sessions
        self.session_timeout = session_timeout
        self._lock = asyncio.Lock()

    async def create_session(
        self,
        cmd: str,
        workdir: Optional[str] = None,
        shell: Optional[str] = None,
        env: Optional[dict[str, str]] = None,
        login: bool = False,
    ) -> PTYSession:
        """Create a new PTY session.

        Args:
            cmd: Command to execute
            workdir: Working directory (defaults to current directory)
            shell: Shell to use (defaults to user's configured login shell)
            env: Additional environment variables
            login: Use login shell

        Returns:
            PTYSession instance

        Raises:
            RuntimeError: If max sessions limit reached
        """
        async with self._lock:
            # Cleanup old sessions first
            await self._cleanup_stale_sessions()

            if len(self.sessions) >= self.max_sessions:
                raise RuntimeError(
                    f"Maximum PTY sessions ({self.max_sessions}) reached"
                )

            session_id = str(uuid.uuid4())[:8]

            # Fork PTY
            pid, master_fd = pty.fork()

            if pid == 0:
                # Child process
                try:
                    if workdir:
                        os.chdir(workdir)

                    # Update environment
                    if env:
                        os.environ.update(env)

                    # Determine shell
                    if shell is None:
                        shell = default_user_shell()

                    # Build shell arguments
                    shell_args = [shell]
                    if login:
                        shell_args.append("-l")
                    shell_args.extend(["-c", cmd])

                    # Execute command in shell
                    os.execvp(shell, shell_args)
                except Exception as e:
                    # If exec fails, print error and exit
                    print(f"Error executing command: {e}", flush=True)
                    os._exit(1)
            else:
                # Parent process
                # Set master FD to non-blocking mode
                import fcntl
                flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
                fcntl.fcntl(master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

                session = PTYSession(
                    id=session_id,
                    master_fd=master_fd,
                    slave_fd=-1,  # Not used in parent
                    pid=pid,
                )
                self.sessions[session_id] = session
                return session

    async def write_input(self, session_id: str, data: str) -> None:
        """Write input to PTY session.

        Args:
            session_id: Session ID
            data: Input data to write

        Raises:
            KeyError: If session not found
        """
        session = self.sessions.get(session_id)
        if not session:
            raise KeyError(f"Session {session_id} not found")

        try:
            os.write(session.master_fd, data.encode())
            session.last_activity = time.time()
        except OSError as e:
            # Process may have exited
            raise OSError(f"Failed to write to session {session_id}: {e}")

    async def read_output(
        self,
        session_id: str,
        timeout_ms: int = DEFAULT_READ_TIMEOUT_MS,
        max_bytes: int = DEFAULT_MAX_READ_BYTES,
    ) -> str:
        """Read available output from PTY session.

        Args:
            session_id: Session ID
            timeout_ms: Timeout in milliseconds
            max_bytes: Maximum bytes to read

        Returns:
            Output string

        Raises:
            KeyError: If session not found
        """
        session = self.sessions.get(session_id)
        if not session:
            raise KeyError(f"Session {session_id} not found")

        output = []
        deadline = time.time() + (timeout_ms / 1000.0)
        total_bytes = 0

        while time.time() < deadline and total_bytes < max_bytes:
            try:
                readable, _, _ = select.select([session.master_fd], [], [], 0.01)
                if readable:
                    try:
                        data = os.read(session.master_fd, 4096)
                        if data:
                            decoded = data.decode("utf-8", errors="replace")
                            output.append(decoded)
                            total_bytes += len(data)
                        else:
                            # EOF - process exited
                            break
                    except OSError:
                        # Process may have exited
                        break
                else:
                    # No data available, yield to event loop
                    await asyncio.sleep(0.01)
            except Exception:
                break

        result = "".join(output)
        session.output_buffer += result
        session.last_activity = time.time()
        return result

    def get_process_status(self, session_id: str) -> dict[str, Any]:
        """Get the status of a PTY session's process.

        Args:
            session_id: Session ID

        Returns:
            Dictionary with process status information:
                - running: Whether process is still running
                - exit_code: Exit code if process terminated

        Raises:
            KeyError: If session not found
        """
        session = self.sessions.get(session_id)
        if not session:
            raise KeyError(f"Session {session_id} not found")

        try:
            # Check if process is still running
            pid, status = os.waitpid(session.pid, os.WNOHANG)
            if pid == 0:
                # Process still running
                return {"running": True, "exit_code": None}
            else:
                # Process exited
                if os.WIFEXITED(status):
                    exit_code = os.WEXITSTATUS(status)
                elif os.WIFSIGNALED(status):
                    exit_code = -os.WTERMSIG(status)
                else:
                    exit_code = -1
                return {"running": False, "exit_code": exit_code}
        except ChildProcessError:
            # Process already reaped
            return {"running": False, "exit_code": 0}

    async def close_session(self, session_id: str, force: bool = False) -> None:
        """Close and cleanup PTY session.

        Args:
            session_id: Session ID
            force: If True, use SIGKILL instead of SIGTERM

        Raises:
            KeyError: If session not found
        """
        async with self._lock:
            session = self.sessions.pop(session_id, None)
            if session:
                try:
                    # Send termination signal
                    sig = signal.SIGKILL if force else signal.SIGTERM
                    os.kill(session.pid, sig)

                    # Wait for process to exit (with timeout)
                    if not force:
                        for _ in range(10):  # Wait up to 1 second
                            try:
                                pid, _ = os.waitpid(session.pid, os.WNOHANG)
                                if pid != 0:
                                    break
                            except ChildProcessError:
                                break
                            await asyncio.sleep(0.1)

                    # Close file descriptor
                    os.close(session.master_fd)
                except (OSError, ChildProcessError):
                    # Process may have already exited or FD already closed
                    return

    async def _cleanup_stale_sessions(self) -> None:
        """Remove sessions that have timed out."""
        now = time.time()
        stale = [
            sid for sid, s in self.sessions.items()
            if now - s.last_activity > self.session_timeout
        ]
        for sid in stale:
            try:
                await self.close_session(sid)
            except KeyError:
                continue  # Already removed

    async def cleanup_all(self) -> None:
        """Close all active sessions."""
        session_ids = list(self.sessions.keys())
        for sid in session_ids:
            try:
                await self.close_session(sid)
            except KeyError:
                continue

    def list_sessions(self) -> list[dict[str, Any]]:
        """List all active sessions.

        Returns:
            List of session information dictionaries
        """
        return [
            {
                "id": s.id,
                "pid": s.pid,
                "created_at": s.created_at,
                "last_activity": s.last_activity,
                "output_buffer_size": len(s.output_buffer),
            }
            for s in self.sessions.values()
        ]
