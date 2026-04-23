# Client: iOS release plumbing and TestFlight path

## Context

The repo currently has no iOS distribution path. `project.yml:7-11` sets manual code signing with a placeholder identity, `project.yml:125-180` only configures the macOS app and test bundles, and there is no checked-in iOS/TestFlight automation in this tree today. The main spec and ticket 0101 both assume iOS will ship through private/TestFlight phases after desktop-remote.

The build-target work in `0121` creates the iOS app target, but it does not make the target shippable. This ticket owns the productization work needed to turn “builds on a simulator” into “can be distributed to internal/whitelist users.”

## Problem

If signing, provisioning, archive, and TestFlight setup are left implicit, the team can finish the app code and still be unable to distribute a real iOS build for rollout.

## Goal

Make the iOS app target releasable through TestFlight: correct bundle/signing configuration, provisioning, versioning, archive/upload automation, and documentation for repeatable internal distribution.

## Scope

- **In scope**
  - Add the iOS code-signing and bundle configuration required by the new target from `0121`:
    - bundle identifier,
    - signing team/profile setup,
    - generated Info.plist keys,
    - entitlements needed by the iOS app’s auth and runtime path.
  - Carry forward the auth plumbing prerequisites from `0106` and `0109` into releasable target configuration:
    - custom URL scheme or callback configuration,
    - any Info.plist entries required for the sign-in flow,
    - secure-store compatible entitlements.
  - Add archive/export/upload automation for TestFlight in the repo’s chosen automation surface, plus the secret/config inputs it requires outside the repo.
  - Define repeatable version/build-number rules so internal builds do not collide in App Store Connect.
  - Add the minimum release documentation for engineers:
    - how to produce a signed archive locally,
    - how CI uploads to TestFlight,
    - where secrets/profiles live,
    - how to reset a broken provisioning setup.
  - Keep the rollout contract with `0101`: this ticket is for private/internal/TestFlight phases only, not a full App Store launch package.
- **Out of scope**
  - Building the iOS target in the first place; `0121` owns that.
  - Feature wiring, runtime behavior, or terminal portability.
  - App Store review metadata, screenshots, marketing copy, or GA launch paperwork.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md`
- `.smithers/tickets/0101-design-rollout-plan.md`
- `.smithers/tickets/0106-plue-oauth2-pkce-for-mobile.md`
- `.smithers/tickets/0109-client-oauth2-signin-ui.md`
- `project.yml:7-11`
- `project.yml:125-180`

## Acceptance criteria

- The iOS target can be archived and signed for device distribution.
- CI can produce a signed iOS archive and upload it to TestFlight.
- Bundle/signing/callback configuration required for the OAuth flow is present in the releasable target.
- Build numbering/versioning is deterministic and documented.
- Repo documentation explains the local and CI release paths plus the secret/provisioning prerequisites.
- The resulting path is good enough for the internal/alpha phases in `0101`.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the TestFlight job produces a real signed archive rather than a simulator build, the callback/sign-in configuration used by `0109` is present in the release target, and the documentation names every external prerequisite instead of assuming tribal knowledge.

## Risks / unknowns

- Apple signing/provisioning is an external dependency and can stall validation even when the code is correct.
- If the target structure from `0121` changes late, archive automation will need to be updated in lockstep.
- This ticket should not absorb “fix the app” work just because release testing finds product bugs; those should feed back into the relevant implementation tickets.
