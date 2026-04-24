# Plue: add GET /api/user/repos

## Problem

The iOS switcher now needs a repository picker for workspace creation and filtering. The client first calls `GET /api/user/repos`, but this checkout only shows existing test usage for `POST /api/user/repos` and does not include a local `plue/` tree to verify or update the route.

## Expected

Expose an authenticated `GET /api/user/repos` endpoint returning the current user's repositories. The iOS client accepts either an array payload or an envelope such as `{ "repos": [...] }`, with each repo including at least:

- `owner`
- `name`

## Current Client Fallback

Until the route is confirmed, iOS falls back to deriving the unique repo set from `GET /api/user/workspaces?limit=100` when `GET /api/user/repos` returns `404`, `405`, or `501`.

## Acceptance

- `GET /api/user/repos` returns repos owned by or accessible to the signed-in user.
- Empty accounts return `200` with an empty list, not `404`.
- The endpoint has auth coverage for signed-out and foreign-user cases.
