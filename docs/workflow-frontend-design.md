# Workflow Frontends For Smithers

## Summary

This proposes a Smithers-native workflow frontend feature that lets a workflow ship its own HTML/JS app, typically React, and have Smithers serve it directly. Smithers GUI then becomes one consumer of that feature: it embeds the served app in `WKWebView` instead of owning the UI contract.

The POC in this repo uses the existing `ticket-kanban` workflow and demonstrates the shape with:

- a workflow-adjacent frontend bundle
- a small HTTP server that serves the app plus workflow data
- a new `App` tab in the macOS workflow detail view that embeds the served app

The POC is intentionally implemented in the workspace, not in Smithers core, but the contract is designed so it can move into Smithers with minimal churn.

## Goals

- Let a workflow define a custom frontend in HTML/JS.
- Make the frontend portable across Smithers clients.
- Keep Smithers GUI thin: it should host the app, not define its API.
- Reuse Smithers as the source of truth for workflow state, runs, approvals, outputs, and launch actions.
- Support React cleanly.

## Non-goals

- Replacing the existing generic GUI for all workflows.
- Exposing arbitrary local filesystem access to frontend code.
- Designing a full plugin marketplace, auth model, or remote multi-user deployment in this pass.

## Why This Should Live In Smithers

If the frontend contract lives in Smithers:

- the same workflow app can run in Smithers GUI, a browser, or a future JJHub surface
- workflow authors only target one API/runtime contract
- the GUI does not need workflow-specific Swift code
- the lifecycle is correct: when Smithers can inspect a run, it can also serve the UI for that run

The current Smithers package already has HTTP serving primitives:

- single-run `createServeApp(...)`
- generic server routes like `/v1/runs`, `/v1/runs/:runId`, `/v1/runs/:runId/events`

That means the right long-term direction is to extend Smithers' existing HTTP server with workflow-owned static assets and a small frontend manifest, not build a separate GUI-only protocol.

## Proposed Contract

### 1. Workflow-adjacent frontend directory

Convention:

```text
.smithers/workflows/
  ticket-kanban.tsx
  ticket-kanban.frontend/
    manifest.json
    dist/
      index.html
      assets/...
```

This keeps the app discoverable from the workflow path and easy to move with the workflow.

### 2. Frontend manifest

Example:

```json
{
  "version": 1,
  "id": "ticket-kanban",
  "name": "Ticket Kanban",
  "framework": "react",
  "entry": "dist/index.html",
  "apiBasePath": "/api",
  "defaultPath": "/",
  "permissions": {
    "read": ["workflow", "runs", "inspect", "tickets"],
    "write": ["launchRun", "cancelRun"]
  }
}
```

Fields:

- `version`: manifest schema version
- `id`: frontend id, usually workflow id
- `name`: display name for hosts
- `framework`: informational only
- `entry`: static entrypoint relative to the frontend directory
- `apiBasePath`: base path the frontend should call
- `defaultPath`: route to open first
- `permissions`: declarative intent for future sandboxing/policy

### 3. Smithers HTTP mount points

Recommended long-term routes:

- `GET /v1/workflows/:workflowId/frontend`
  Returns manifest + resolved asset metadata.
- `GET /v1/workflows/:workflowId/frontend/*`
  Serves static assets.
- `GET /v1/workflows/:workflowId/frontend/api/*`
  Workflow-scoped API routes.

For run-scoped pages, the frontend should also be able to consume the existing generic run APIs:

- `GET /v1/runs`
- `GET /v1/runs/:runId`
- `GET /v1/runs/:runId/events`
- `POST /v1/runs`
- `POST /v1/runs/:runId/cancel`
- `POST /v1/runs/:runId/nodes/:nodeId/approve`
- `POST /v1/runs/:runId/nodes/:nodeId/deny`

### 4. Small JS SDK

Smithers should eventually expose a tiny browser SDK, for example:

```ts
import { createSmithersFrontend } from "@smithers-orchestrator/frontend";

const smithers = createSmithersFrontend({
  baseUrl: "/v1/workflows/ticket-kanban/frontend"
});
```

Responsibilities:

- resolve base URLs
- wrap fetch + SSE
- expose typed helpers for runs, approvals, and workflow metadata
- optionally expose host hints like `openExternal(url)` or `copy(text)`

The host should not inject workflow-specific JS APIs.

## React Recommendation

React is a good default here because:

- Smithers workflows are already JSX/TS-heavy
- workflow authors will likely want stateful UIs, polling/SSE subscriptions, and composition
- React can compile to static assets and run inside any browser/webview host

The frontend contract should be framework-agnostic, but React should be the documented happy path.

## Smithers Core Changes Recommended

### Phase 1

- Add frontend discovery by convention:
  - `<workflow basename>.frontend/manifest.json`
- Add static asset serving to the existing Smithers server.
- Add workflow frontend metadata to `workflow list` / `listWorkflows`.
- Add a minimal `frontend api` helper for workflow-specific routes.

### Phase 2

- Add a first-party browser SDK package.
- Add SSE helpers for workflow apps.
- Add permission enforcement based on manifest declarations.
- Add build hooks:
  - `smithers workflow build-frontend <workflowId>`
  - `smithers workflow serve-frontend <workflowId>`

### Phase 3

- Support remote/JJHub-hosted workflow frontends.
- Support auth/session-aware frontends.
- Support host capabilities like file download, clipboard, open-tab, or deep-linking.

## Security Model

Baseline rules:

- Frontends are static assets only.
- All privileged actions still go through Smithers HTTP endpoints.
- No direct shell or filesystem access from the browser runtime.
- Workflow-specific API routes must be explicitly mounted by Smithers, not inferred from arbitrary local files.
- Manifest permissions should be surfaced to users and enforced later.

For the macOS host:

- keep using `WKWebView`
- prefer localhost HTTP over `file://` for parity with Smithers-native serving
- do not expose a wide native JS bridge for this feature

## POC Shape In This Repo

The POC stays close to the proposed contract:

- `ticket-kanban.frontend/manifest.json`
- a React bundle in `ticket-kanban.frontend/dist`
- a small Bun server in `ticket-kanban.frontend/server.ts`
- the macOS app launches that server on demand and embeds it in a webview

Differences from the final Smithers-native design:

- the server is workspace-local instead of living in Smithers core
- it shells out to the `smithers` CLI instead of calling Smithers internals directly
- its API is workflow-specific and thin

Those differences are acceptable for a POC because they validate:

- discovery
- hosting
- the frontend manifest shape
- a React-based workflow app
- the GUI embedding model

## Kanban-Specific API In The POC

Routes:

- `GET /api/health`
- `GET /api/workflow`
- `GET /api/runs`
- `GET /api/board`
- `POST /api/run`
- `POST /api/runs/:runId/cancel`

`/api/board` aggregates:

- ticket files from `.smithers/tickets`
- recent `ticket-kanban` runs
- selected run inspection
- derived ticket state from step ids like:
  - `<slug>:implement`
  - `<slug>:validate`
  - `<slug>:review:*`
  - `result-<slug>`

This is enough to render a useful Kanban board without changing Smithers itself.

## GUI Integration

The GUI should:

- detect the frontend manifest next to the workflow
- show an `App` tab when present
- boot the local server process on demand
- embed the app URL in a webview
- stay ignorant of workflow-specific state

This mirrors the long-term architecture where Smithers, not Swift, owns the app contract.

## Open Questions

- Should frontend discovery be convention-only, or also declarable in workflow metadata?
- Should workflow-specific APIs be code-defined, or should frontends consume only generic Smithers APIs?
- Should frontend assets be prebuilt and committed, or built on demand by Smithers?
- Should the first-class host model be workflow-scoped or run-scoped?

## Recommendation

Build the feature into Smithers as:

1. frontend discovery by adjacent manifest
2. static asset serving from the existing HTTP server
3. a tiny frontend SDK for React/browser apps
4. host embedding in GUI as a thin webview shell

The POC in this repo validates that this model is workable with the `ticket-kanban` workflow right now.
