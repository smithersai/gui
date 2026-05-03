"""
Custom web fetch tool with size limits.

Implements a 5MB size limit for web fetch operations to prevent memory
exhaustion and denial-of-service issues when fetching large files or
malicious content.
"""

import httpx
from core.constants import MAX_RESPONSE_SIZE, DEFAULT_WEB_TIMEOUT


async def fetch_url(url: str, timeout: float = DEFAULT_WEB_TIMEOUT) -> str:
    """
    Fetch content from a URL with size limit enforcement.

    This function implements a 5MB size limit to prevent:
    - Memory exhaustion attacks
    - Accidentally downloading large files (videos, datasets)
    - Malicious servers streaming infinite data

    Args:
        url: URL to fetch
        timeout: Request timeout in seconds (default: 30)

    Returns:
        Response content as string

    Raises:
        ValueError: If response exceeds size limit or other validation errors
        httpx.HTTPError: For HTTP-related errors (timeout, connection, etc.)
    """
    # Validate URL
    if not url or not isinstance(url, str):
        raise ValueError("URL must be a non-empty string")

    # Ensure URL has a scheme
    if not url.startswith(("http://", "https://")):
        raise ValueError("URL must start with http:// or https://")

    async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
        try:
            # Send HEAD request first to check Content-Length if available
            # This avoids downloading large files unnecessarily
            try:
                head_response = await client.head(url)
                content_length = head_response.headers.get("content-length")
                if content_length:
                    size = int(content_length)
                    if size > MAX_RESPONSE_SIZE:
                        raise ValueError("response too large (exceeds 5MB limit)")
            except (httpx.HTTPError, ValueError) as e:
                # HEAD request failed or content-length indicates too large
                # If it's a size error, re-raise it
                if isinstance(e, ValueError) and "exceeds 5MB limit" in str(e):
                    raise
                # Otherwise, continue with GET request
                # (some servers don't support HEAD or don't return Content-Length)

            # Perform GET request with streaming to enforce size limit
            async with client.stream("GET", url) as response:
                response.raise_for_status()

                # Check Content-Length header from GET response
                content_length = response.headers.get("content-length")
                if content_length:
                    size = int(content_length)
                    if size > MAX_RESPONSE_SIZE:
                        raise ValueError("response too large (exceeds 5MB limit)")

                # Read response body with size limit enforcement
                # We read MAX_RESPONSE_SIZE + 1 bytes to detect if content exceeds limit
                chunks = []
                total_size = 0

                async for chunk in response.aiter_bytes():
                    chunks.append(chunk)
                    total_size += len(chunk)

                    # Check if we've exceeded the limit
                    if total_size > MAX_RESPONSE_SIZE:
                        raise ValueError("response too large (exceeds 5MB limit)")

                # Combine chunks
                data = b"".join(chunks)

                # Final size validation
                if len(data) > MAX_RESPONSE_SIZE:
                    raise ValueError("response too large (exceeds 5MB limit)")

                # Decode to string
                # Try to get encoding from Content-Type header
                content_type = response.headers.get("content-type", "")
                encoding = "utf-8"  # Default encoding

                if "charset=" in content_type:
                    try:
                        encoding = content_type.split("charset=")[1].split(";")[0].strip()
                    except (IndexError, AttributeError):
                        encoding = "utf-8"

                try:
                    return data.decode(encoding)
                except UnicodeDecodeError:
                    # Fallback to latin-1 which accepts all byte values
                    return data.decode("latin-1")

        except httpx.TimeoutException as e:
            raise httpx.TimeoutException(f"Request timed out after {timeout}s") from e
        except httpx.HTTPStatusError as e:
            raise ValueError(f"HTTP error {e.response.status_code}: {e.response.reason_phrase}") from e
        except httpx.RequestError as e:
            raise ValueError(f"Request failed: {str(e)}") from e
