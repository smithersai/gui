# Fix HTTP/SSE Transport Ignores serverURL

## Problem

The HTTP and SSE transport hardcodes or ignores the configured `serverURL`,
always connecting to a default address.

Review: platform.

## Current State

- `serverURL` is stored in configuration but not used when constructing
  HTTP/SSE requests.

## Proposed Changes

- Use the configured `serverURL` as the base URL for all HTTP and SSE
  requests.
- Fall back to the default only when no URL is configured.

## Files

- `SmithersClient.swift`
- Transport/connection files

## Acceptance Criteria

- HTTP/SSE requests use the configured `serverURL`.
- Changing `serverURL` takes effect without restarting the app.
