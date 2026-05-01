"""
Tests for web fetch tool with size limits.

Tests verify:
- Content-Length header checking before download
- Streaming read with size enforcement
- Successful fetches under limit
- Edge cases (exactly 5MB, 5MB + 1 byte)
"""

import pytest
import httpx
from unittest.mock import AsyncMock, Mock, patch, MagicMock

from agent.tools.web_fetch import fetch_url
from core.constants import MAX_RESPONSE_SIZE


def create_mock_client(mock_head_response, mock_stream_response):
    """Helper to create a properly mocked httpx.AsyncClient."""
    mock_client = Mock()  # Use Mock instead of AsyncMock to avoid coroutine issues

    # Mock head() to return the response directly
    async def mock_head(*args, **kwargs):
        return mock_head_response
    mock_client.head = mock_head

    # Create proper async context manager for stream()
    mock_stream = MagicMock()
    mock_stream.__aenter__ = AsyncMock(return_value=mock_stream_response)
    mock_stream.__aexit__ = AsyncMock(return_value=None)

    # Make stream() a regular function that returns the context manager
    def mock_stream_fn(*args, **kwargs):
        return mock_stream
    mock_client.stream = mock_stream_fn

    return mock_client


class TestWebFetchSizeLimit:
    """Test suite for web fetch size limit enforcement."""

    @pytest.mark.asyncio
    async def test_content_length_header_rejection(self):
        """Test rejection via Content-Length header before download."""
        # Mock a response with Content-Length > 5MB
        mock_response = Mock()
        mock_response.headers = {"content-length": str(10 * 1024 * 1024)}  # 10MB
        mock_response.status_code = 200

        with patch("httpx.AsyncClient") as mock_client:
            mock_client_instance = AsyncMock()
            mock_client.return_value.__aenter__.return_value = mock_client_instance
            mock_client_instance.head.return_value = mock_response

            with pytest.raises(ValueError, match="response too large \\(exceeds 5MB limit\\)"):
                await fetch_url("https://example.com/large-file.zip")

    @pytest.mark.asyncio
    async def test_streaming_read_size_enforcement(self):
        """Test size limit enforcement during streaming read."""
        # Mock a response without Content-Length that streams > 5MB
        mock_head_response = Mock()
        mock_head_response.headers = {}  # No Content-Length

        # Create a mock streaming response
        mock_stream_response = AsyncMock()
        mock_stream_response.headers = {}
        mock_stream_response.status_code = 200
        mock_stream_response.raise_for_status = Mock()

        # Generate chunks that exceed 5MB
        chunk_size = 1024 * 1024  # 1MB chunks
        total_chunks = 6  # 6MB total

        async def aiter_bytes_mock():
            for _ in range(total_chunks):
                yield b"x" * chunk_size

        mock_stream_response.aiter_bytes = aiter_bytes_mock

        with patch("agent.tools.web_fetch.httpx.AsyncClient") as mock_client_cls:
            mock_client = create_mock_client(mock_head_response, mock_stream_response)
            mock_client_cls.return_value.__aenter__.return_value = mock_client
            mock_client_cls.return_value.__aexit__.return_value = None

            with pytest.raises(ValueError, match="response too large \\(exceeds 5MB limit\\)"):
                await fetch_url("https://example.com/streaming-large-file")

    @pytest.mark.asyncio
    async def test_successful_fetch_under_limit(self):
        """Test successful fetch of content under 5MB."""
        content = b"This is a small response"

        # Mock HEAD response
        mock_head_response = Mock()
        mock_head_response.headers = {"content-length": str(len(content))}

        # Mock streaming response
        mock_stream_response = AsyncMock()
        mock_stream_response.headers = {
            "content-length": str(len(content)),
            "content-type": "text/html; charset=utf-8"
        }
        mock_stream_response.status_code = 200
        mock_stream_response.raise_for_status = Mock()

        async def aiter_bytes_mock():
            yield content

        mock_stream_response.aiter_bytes = aiter_bytes_mock

        with patch("agent.tools.web_fetch.httpx.AsyncClient") as mock_client_cls:
            mock_client = create_mock_client(mock_head_response, mock_stream_response)
            mock_client_cls.return_value.__aenter__.return_value = mock_client
            mock_client_cls.return_value.__aexit__.return_value = None

            result = await fetch_url("https://example.com/small-file")
            assert result == content.decode("utf-8")

    @pytest.mark.asyncio
    async def test_exactly_5mb(self):
        """Test edge case: exactly 5MB should succeed."""
        # Create exactly 5MB of data
        content = b"x" * MAX_RESPONSE_SIZE

        mock_head_response = Mock()
        mock_head_response.headers = {"content-length": str(len(content))}

        mock_stream_response = AsyncMock()
        mock_stream_response.headers = {"content-length": str(len(content))}
        mock_stream_response.status_code = 200
        mock_stream_response.raise_for_status = Mock()

        async def aiter_bytes_mock():
            # Yield in chunks
            chunk_size = 1024 * 1024
            for i in range(0, len(content), chunk_size):
                yield content[i:i + chunk_size]

        mock_stream_response.aiter_bytes = aiter_bytes_mock

        with patch("agent.tools.web_fetch.httpx.AsyncClient") as mock_client_cls:
            mock_client = create_mock_client(mock_head_response, mock_stream_response)
            mock_client_cls.return_value.__aenter__.return_value = mock_client
            mock_client_cls.return_value.__aexit__.return_value = None

            result = await fetch_url("https://example.com/exactly-5mb")
            assert len(result) == MAX_RESPONSE_SIZE

    @pytest.mark.asyncio
    async def test_5mb_plus_one_byte(self):
        """Test edge case: 5MB + 1 byte should fail."""
        # Create 5MB + 1 byte of data
        content_size = MAX_RESPONSE_SIZE + 1

        mock_head_response = Mock()
        mock_head_response.headers = {"content-length": str(content_size)}

        with patch("httpx.AsyncClient") as mock_client:
            mock_client_instance = AsyncMock()
            mock_client.return_value.__aenter__.return_value = mock_client_instance
            mock_client_instance.head.return_value = mock_head_response

            with pytest.raises(ValueError, match="response too large \\(exceeds 5MB limit\\)"):
                await fetch_url("https://example.com/5mb-plus-one")

    @pytest.mark.asyncio
    async def test_url_validation(self):
        """Test URL validation."""
        # Test empty URL
        with pytest.raises(ValueError, match="URL must be a non-empty string"):
            await fetch_url("")

        # Test URL without scheme
        with pytest.raises(ValueError, match="URL must start with http://"):
            await fetch_url("example.com")

        # Test non-string URL
        with pytest.raises(ValueError, match="URL must be a non-empty string"):
            await fetch_url(None)

    @pytest.mark.asyncio
    async def test_timeout_handling(self):
        """Test timeout handling."""
        with patch("agent.tools.web_fetch.httpx.AsyncClient") as mock_client_cls:
            mock_client = Mock()

            async def mock_head_timeout(*args, **kwargs):
                raise httpx.TimeoutException("Timeout")
            mock_client.head = mock_head_timeout

            # The timeout will be caught and GET will be attempted
            # Make GET also timeout
            mock_stream_response = Mock()
            mock_stream_response.headers = {}  # Empty headers to avoid get() issues
            mock_stream_response.raise_for_status = Mock(
                side_effect=httpx.TimeoutException("Timeout")
            )

            mock_stream = MagicMock()
            mock_stream.__aenter__ = AsyncMock(return_value=mock_stream_response)
            mock_stream.__aexit__ = AsyncMock(return_value=None)
            mock_client.stream = lambda *args, **kwargs: mock_stream

            mock_client_cls.return_value.__aenter__.return_value = mock_client
            mock_client_cls.return_value.__aexit__.return_value = None

            with pytest.raises(httpx.TimeoutException, match="Request timed out"):
                await fetch_url("https://example.com/slow", timeout=1.0)

    @pytest.mark.asyncio
    async def test_http_error_handling(self):
        """Test HTTP error handling."""
        mock_response = Mock()
        mock_response.status_code = 404
        mock_response.reason_phrase = "Not Found"

        with patch("agent.tools.web_fetch.httpx.AsyncClient") as mock_client_cls:
            # HEAD request succeeds
            mock_head_response = Mock()
            mock_head_response.headers = {}

            # GET request fails - use Mock instead of AsyncMock for response
            mock_stream_response = Mock()
            mock_stream_response.status_code = 404
            mock_stream_response.reason_phrase = "Not Found"
            mock_stream_response.headers = {}  # Empty headers dict
            mock_stream_response.raise_for_status = Mock(
                side_effect=httpx.HTTPStatusError(
                    "404", request=Mock(), response=mock_response
                )
            )

            # Create async iterator for bytes
            async def aiter_bytes_mock():
                # This will never be reached because raise_for_status will raise
                if False:
                    yield
            mock_stream_response.aiter_bytes = aiter_bytes_mock

            mock_client = create_mock_client(mock_head_response, mock_stream_response)
            mock_client_cls.return_value.__aenter__.return_value = mock_client
            mock_client_cls.return_value.__aexit__.return_value = None

            with pytest.raises(ValueError, match="HTTP error 404"):
                await fetch_url("https://example.com/not-found")

    @pytest.mark.asyncio
    async def test_encoding_detection(self):
        """Test character encoding detection and decoding."""
        content = "Hello, 世界!".encode("utf-8")

        mock_head_response = Mock()
        mock_head_response.headers = {}

        mock_stream_response = AsyncMock()
        mock_stream_response.headers = {
            "content-type": "text/html; charset=utf-8",
            "content-length": str(len(content))
        }
        mock_stream_response.status_code = 200
        mock_stream_response.raise_for_status = Mock()

        async def aiter_bytes_mock():
            yield content

        mock_stream_response.aiter_bytes = aiter_bytes_mock

        with patch("agent.tools.web_fetch.httpx.AsyncClient") as mock_client_cls:
            mock_client = create_mock_client(mock_head_response, mock_stream_response)
            mock_client_cls.return_value.__aenter__.return_value = mock_client
            mock_client_cls.return_value.__aexit__.return_value = None

            result = await fetch_url("https://example.com/unicode")
            assert result == "Hello, 世界!"

    @pytest.mark.asyncio
    async def test_no_content_length_header(self):
        """Test handling of responses without Content-Length header."""
        content = b"Content without length header"

        mock_head_response = Mock()
        mock_head_response.headers = {}  # No Content-Length

        mock_stream_response = AsyncMock()
        mock_stream_response.headers = {}  # No Content-Length in GET either
        mock_stream_response.status_code = 200
        mock_stream_response.raise_for_status = Mock()

        async def aiter_bytes_mock():
            yield content

        mock_stream_response.aiter_bytes = aiter_bytes_mock

        with patch("agent.tools.web_fetch.httpx.AsyncClient") as mock_client_cls:
            mock_client = create_mock_client(mock_head_response, mock_stream_response)
            mock_client_cls.return_value.__aenter__.return_value = mock_client
            mock_client_cls.return_value.__aexit__.return_value = None

            result = await fetch_url("https://example.com/no-length")
            assert result == content.decode("utf-8")
