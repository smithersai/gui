"""
Async HTTP client for Swift browser automation API.

Connects to the BrowserAPIServer running in the Swift app to expose
browser automation capabilities as MCP tools.
"""

import logging
import os
from pathlib import Path
from typing import Any

import httpx

# Constants
DEFAULT_PORT = 48484
PORT_FILE_PATH = Path.home() / ".plue" / "browser-api.port"
REQUEST_TIMEOUT_SECONDS = 30.0
BASE_URL_TEMPLATE = "http://127.0.0.1:{port}"

logger = logging.getLogger(__name__)


class BrowserClient:
    """Async HTTP client for Swift browser automation API."""

    def __init__(self, port: int | None = None):
        """Initialize browser client.

        Args:
            port: Port number to connect to. If None, discovers from port file
                  or environment variable BROWSER_API_PORT.
        """
        self._port = port
        self._client: httpx.AsyncClient | None = None

    @property
    def port(self) -> int:
        """Get the port to connect to, discovering if needed."""
        if self._port is not None:
            return self._port

        # Check environment variable first
        env_port = os.environ.get("BROWSER_API_PORT")
        if env_port:
            try:
                self._port = int(env_port)
                return self._port
            except ValueError:
                logger.debug("Ignoring invalid BROWSER_API_PORT value: %s", env_port)

        # Check port file
        if PORT_FILE_PATH.exists():
            try:
                self._port = int(PORT_FILE_PATH.read_text().strip())
                return self._port
            except (ValueError, IOError) as e:
                logger.debug("Ignoring invalid browser API port file %s: %s", PORT_FILE_PATH, e)

        # Fall back to default
        self._port = DEFAULT_PORT
        return self._port

    @property
    def base_url(self) -> str:
        """Get the base URL for the browser API."""
        return BASE_URL_TEMPLATE.format(port=self.port)

    async def _get_client(self) -> httpx.AsyncClient:
        """Get or create the HTTP client."""
        if self._client is None:
            self._client = httpx.AsyncClient(
                base_url=self.base_url,
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
        return self._client

    async def close(self) -> None:
        """Close the HTTP client."""
        if self._client:
            await self._client.aclose()
            self._client = None

    async def _post(self, endpoint: str, data: dict[str, Any] | None = None) -> dict[str, Any]:
        """Make a POST request to the browser API.

        Args:
            endpoint: API endpoint path (e.g., "/browser/snapshot")
            data: JSON body data

        Returns:
            Response JSON as dict

        Raises:
            httpx.ConnectError: If browser is not connected
            httpx.TimeoutException: If operation times out
        """
        client = await self._get_client()
        response = await client.post(endpoint, json=data or {})
        return response.json()

    async def _get(self, endpoint: str) -> dict[str, Any]:
        """Make a GET request to the browser API.

        Args:
            endpoint: API endpoint path

        Returns:
            Response JSON as dict
        """
        client = await self._get_client()
        response = await client.get(endpoint)
        return response.json()

    # MARK: - Browser Operations

    async def status(self) -> dict[str, Any]:
        """Get browser connection status.

        Returns:
            Dict with 'success' and 'connected' fields
        """
        return await self._get("/browser/status")

    async def snapshot(
        self,
        include_hidden: bool = False,
        max_depth: int = 50,
    ) -> dict[str, Any]:
        """Take accessibility snapshot of browser page.

        Args:
            include_hidden: Include hidden elements in snapshot
            max_depth: Maximum depth of element tree to traverse

        Returns:
            Dict with 'success', 'text_tree', 'url', 'title', 'element_count'
        """
        return await self._post("/browser/snapshot", {
            "include_hidden": include_hidden,
            "max_depth": max_depth,
        })

    async def click(self, ref: str) -> dict[str, Any]:
        """Click an element by ref.

        Args:
            ref: Element reference (e.g., 'e1', 'e23')

        Returns:
            Dict with 'success' and optional 'error'
        """
        return await self._post("/browser/click", {"ref": ref})

    async def type_text(
        self,
        ref: str,
        text: str,
        clear: bool = False,
    ) -> dict[str, Any]:
        """Type text into an element.

        Args:
            ref: Element reference
            text: Text to type
            clear: Whether to clear existing content first

        Returns:
            Dict with 'success' and optional 'error'
        """
        return await self._post("/browser/type", {
            "ref": ref,
            "text": text,
            "clear": clear,
        })

    async def scroll(
        self,
        direction: str = "down",
        amount: int = 300,
    ) -> dict[str, Any]:
        """Scroll the page.

        Args:
            direction: Scroll direction (up, down, left, right)
            amount: Scroll amount in pixels

        Returns:
            Dict with 'success'
        """
        return await self._post("/browser/scroll", {
            "direction": direction,
            "amount": amount,
        })

    async def extract_text(self, ref: str) -> dict[str, Any]:
        """Extract text content from an element.

        Args:
            ref: Element reference

        Returns:
            Dict with 'success' and 'text'
        """
        return await self._post("/browser/extract", {"ref": ref})

    async def screenshot(self) -> dict[str, Any]:
        """Take a screenshot of the browser page.

        Returns:
            Dict with 'success' and 'image_base64'
        """
        return await self._post("/browser/screenshot")

    async def navigate(self, url: str) -> dict[str, Any]:
        """Navigate browser to a URL.

        Args:
            url: URL to navigate to

        Returns:
            Dict with 'success'
        """
        return await self._post("/browser/navigate", {"url": url})


# Singleton instance
_browser_client: BrowserClient | None = None


def get_browser_client() -> BrowserClient:
    """Get the singleton browser client instance."""
    global _browser_client
    if _browser_client is None:
        _browser_client = BrowserClient()
    return _browser_client


async def is_browser_available() -> bool:
    """Check if the Plue browser app is running and accessible.
    
    Makes a quick HTTP request to the browser API status endpoint
    to determine if the browser tools should be enabled.
    
    Returns:
        True if browser API is reachable, False otherwise
    """
    try:
        client = get_browser_client()
        # Use a short timeout for the availability check
        async with httpx.AsyncClient(
            base_url=client.base_url,
            timeout=2.0,  # Quick timeout for availability check
        ) as quick_client:
            response = await quick_client.get("/browser/status")
            return response.status_code == 200
    except (httpx.ConnectError, httpx.TimeoutException, Exception):
        return False
