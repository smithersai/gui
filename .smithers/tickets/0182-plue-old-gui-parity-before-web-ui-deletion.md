# 0182 Plue Old GUI Parity Before Web UI Deletion

Audit date: 2026-04-24

## Summary

`/Users/williamcory/plue` still contains browser and desktop GUI surfaces that are slated for deletion. Deleting them safely requires a Smithers GUI parity matrix first, because the old apps cover more than the minimal workspace terminal flow.

This ticket is the `../gui` blocker for `/Users/williamcory/plue/.smithers/tickets/20-delete-deprecated-browser-gui.md`.

## Source Surfaces

- `/Users/williamcory/plue/apps/ui`
- `/Users/williamcory/plue/oss/apps/ui`
- `/Users/williamcory/plue/oss/apps/desktop`
- `/Users/williamcory/plue/e2e/playwright`

## Required Parity Matrix

Map every old GUI feature to one of:

- implemented in `../gui`, with source file and test reference
- intentionally CLI/API-only, with owner sign-off
- intentionally retired, with owner sign-off
- missing, with a new GUI ticket

Feature groups to cover:

- Auth/session: token entry, WorkOS/GitHub OAuth, restored-session validation, logout, auth errors.
- Repos: repo list, create/connect, settings, archive/transfer/delete where supported, topics/metadata.
- Workspaces: list, create, delete, snapshots/forks if supported, open terminal, terminal resize/reconnect/fullscreen/cleanup.
- Repo activity: issues, issue creation/detail, landings, changes, diffs, bookmarks, code browser, graph, wiki, releases.
- Automation: workflow definitions, workflow runs, run logs/artifacts, agent sessions, agent chat, approvals, devtools snapshots.
- Search and navigation: global search, command navigation, deep links from notifications/email.
- Org/admin: organizations, teams, admin users/orgs/repos/system health/audit/runners if these remain GUI-owned.
- Settings: accounts, emails, SSH keys, API tokens, OAuth apps, notifications, secrets, variables, webhooks/integrations.
- Product web leftovers: marketing/login/waitlist/thank-you pages must either move out of GUI scope or be explicitly retired.

## Acceptance Criteria

- [ ] Add a checked-in parity document under `docs/` or `.smithers/` that covers all source surfaces above.
- [ ] The minimal `apps/ui` flows have native GUI coverage: auth, repo list, workspace list/create/delete, and terminal session attach/resize/reconnect/cleanup.
- [ ] Legacy `oss/apps/ui` admin/settings/repo-management gaps are either implemented or split into follow-up GUI tickets before plue deletes the web UI.
- [ ] Any browser-only feature that is not appropriate for native GUI is explicitly assigned to CLI/API/docs or marked retired.
- [ ] Native GUI tests replace the old Playwright browser checks for user-visible flows that remain GUI-owned.
- [ ] The plue deletion ticket can link to this ticket as deletion-ready evidence.

## Related

- `/Users/williamcory/plue/.smithers/tickets/20-delete-deprecated-browser-gui.md`
- `/Users/williamcory/plue/.smithers/tickets/23-live-deployment-infra-reconciliation.md`

