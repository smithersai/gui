# 0183 Smithers GUI Brand and Backend Namespace Cleanup

Audit date: 2026-04-24

## Summary

The native GUI repo is named Smithers, but user-facing strings and backend namespace references still mix Smithers, JJHub, Codeplane, and plue. Clean this up with an explicit allowlist so the GUI can replace old plue browser/desktop clients without carrying their naming drift forward.

## Findings

Examples found during the audit:

- UI strings such as `JJHub Workflows`.
- Dashboard copy such as `Codeplane At A Glance`.
- `plue` environment and backend naming such as `PLUE_BASE_URL` and `PLUE_CHECKOUT`.
- `jjhub` CLI command construction in the libsmithers/client layer.
- iOS onboarding copy such as `Sign in with JJHub` and links to `jjhub.tech`.
- Remote-mode fallback URLs under the old jjhub namespace.

## Acceptance Criteria

- [ ] Define a GUI naming allowlist: Smithers for product/UI, jjhub only for explicit backend CLI/API/protocol calls that remain supported, and plue only for immutable legacy infra identifiers.
- [ ] Replace user-facing `JJHub`, `Codeplane`, and `plue` copy with Smithers unless the allowlist says otherwise.
- [ ] Rename primary environment variables to Smithers names and keep legacy aliases only where needed for migration.
- [ ] Keep `jjhub` CLI executable usage only behind a backend adapter or compatibility layer, not scattered through views.
- [ ] Update onboarding, settings, dashboard, workflows, run-inspection, terminal, and remote-mode copy.
- [ ] Add a grep-based check or documented command proving no forbidden names remain outside fixtures, historical docs, or compatibility tests.
- [ ] Coordinate domain/default URL changes with the plue live deployment ticket before changing production endpoints.

## Source Context

- `macos/Sources/Smithers/`
- `ios/Sources/SmithersiOS/`
- `Shared/Sources/`
- `libsmithers/src/client/`
- `linux/src/`
- `docs/`

## Related

- `/Users/williamcory/plue/.smithers/tickets/19-smithers-product-boundary-and-rename.md`
- `/Users/williamcory/plue/.smithers/tickets/23-live-deployment-infra-reconciliation.md`

