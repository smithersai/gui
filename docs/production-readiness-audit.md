# Production Readiness Audit

Date: 2026-05-03

## Verdict

SmithersGUI is not production-ready yet.

The backend has been hardened in several important areas, and a focused
Pydantic-free test slice is green. Full release validation is currently blocked
by a local macOS `syspolicyd` hang that prevents native extensions and generated
SwiftPM helper executables from loading. Separately, first-party docs still
record product gaps that must be reconciled before a release claim is honest.

## Objective Checklist

| Requirement | Current status | Evidence |
| --- | --- | --- |
| All features implemented | Not met | `UNIMPLEMENTED_FEATURES.md` now separates implemented-but-unverified backend items from remaining gaps. It and `docs/reference-app-feature-parity.md` still identify unresolved CLI, UI, config, sandbox, observability, and parity gaps. |
| Maintainable code | Improved, not fully audited | Backend lazy imports, plugin validation, file safety, permission models, and PTY timeout handling were tightened. Full Swift, Zig, libsmithers, iOS, and vendored integration paths still need a dedicated pass. |
| Good logging and observability | Partial | LSP silent failures now log debug details; server security and permission changes log useful events. Full OpenTelemetry/structured event coverage is still listed as missing in `UNIMPLEMENTED_FEATURES.md`. |
| Great test coverage | Partial | Focused Python suite passes. Full Python, Swift aggregate, Zig, Xcode, iOS, and external/hive tests are not green or not yet verified in this environment. |
| External tests / hive tests pass | Unverified | No hive test command or green external result was found or run during this pass. |
| Docs fully document behavior | Partial | README and docs are substantial, but gap/review docs still contain unresolved findings and stale feature-inventory claims. |
| No stubs, mocks, TODOs, placeholders | Not met as written | First-party scans still find intentional UI-test placeholders and review docs with unresolved issues. Vendored `ghostty`/`tmux` trees contain many TODO/stub hits and should be excluded or tracked separately by policy. |
| No backwards-compatibility tech debt | Partially met | Recent changes deliberately removed obsolete safe-file placeholder modules and did not preserve unreleased legacy behavior. Broader review docs still call out transitional paths. |
| All tests pass | Not met / blocked | Focused tests pass, but full Python and Swift aggregate runs are blocked by `syspolicyd`. |

## Backend Work Completed In This Pass

- Locked server binding down to loopback by default and added API-key middleware
  for remote exposure.
- Narrowed default CORS and disabled credentialed wildcard CORS.
- Replaced executable plugin validation with AST-only inspection.
- Added plugin filename/path validation to prevent traversal.
- Made `multiedit` atomic: all edits are simulated first, then written once.
- Added a pure `read_file_safe` helper with working-directory containment and
  read tracking.
- Added working-directory containment to `grep` so absolute search paths cannot
  bypass the active workspace.
- Enforced read-before-write safety in wrapper tool-call handling.
- Removed obsolete safe-file placeholder modules.
- Implemented PTY `timeout_ms` behavior for `unified_exec`.
- Made approve-always permissions persist for edit and webfetch operations.
- Converted permission and event envelope models away from Pydantic so pure
  permission tests no longer depend on native extension loading.
- Fixed wrapper tool-result handling so file safety checks resolve tool names
  from the original tool-call context.
- Implemented request-level tool disabling for `tools={"*": false}` and wired
  the TUI `--no-tools` flag through the message API.
- Split the MCP server manifest into a pure helper and made the status endpoint
  report configured built-in servers without spawning subprocesses.
- Moved API route registration into `server.app` while keeping route package
  imports lazy enough for pure helper tests.
- Fixed the plugin authoring prompt so generated plugin templates include the
  required decorator/model imports.
- Reconciled `UNIMPLEMENTED_FEATURES.md` so implemented backend/TUI items such
  as `exec`, `apply`, `unified_exec`, feature flags, skills, and custom slash
  commands are no longer listed as simply missing.
- Added focused regression tests for security, plugin validation/storage,
  atomic multiedit, truncation/read tracking, wrapper file safety, PTY timeout,
  LSP behavior, MCP manifests, plugin authoring guidance, and permission
  serialization.

## Verification Completed

Commands that passed:

```bash
poetry run python -m pytest \
  legacy-agent-tests/test_security.py \
  legacy-agent-tests/test_permissions.py \
  legacy-agent-tests/test_permissions_standalone.py \
  legacy-agent-tests/test_plugins/test_validator.py \
  legacy-agent-tests/test_plugins/test_storage.py \
  legacy-agent-tests/test_agent/test_tools/test_multiedit.py \
  legacy-agent-tests/test_agent/test_tools/test_grep.py \
  legacy-agent-tests/test_agent/test_truncation.py \
  legacy-agent-tests/test_agent/test_tools/test_file_safety.py \
  legacy-agent-tests/test_agent/test_wrapper_file_safety.py \
  legacy-agent-tests/test_pty_exec.py \
  legacy-agent-tests/test_agent/test_tools/test_lsp.py \
  legacy-agent-tests/test_mcp_routes.py -q
# 309 passed, 6 skipped in 66.07s
```

The grep-specific slice also passes independently:

```bash
poetry run python -m pytest legacy-agent-tests/test_agent/test_tools/test_grep.py -q
# 47 passed in 12.12s
```

```bash
poetry run python -m pytest legacy-agent-tests/test_plugins -q
# 99 passed in 2.51s
```

```bash
poetry run python -m pytest legacy-agent-tests/test_web_fetch.py -q
# 10 passed in 0.06s
```

```bash
poetry run python -m pytest \
  legacy-agent-tests/test_permissions.py \
  legacy-agent-tests/test_permissions_standalone.py -q
# 46 passed in 0.05s
```

```bash
(git diff --name-only --diff-filter=ACMR -- '*.py'; git ls-files --others --exclude-standard -- '*.py') \
  | sort -u \
  | xargs poetry run python -m py_compile
git diff --check
poetry check
```

All three passed.

## Verification Blockers

### Python

Fresh probe:

```bash
poetry run python -c 'import pydantic; print("pydantic import ok")'
# timed out after 8s
```

Earlier investigation showed third-party native extensions such as
`pydantic_core`, `orjson`, and `ujson` hang in import-time extension loading
while `/usr/libexec/syspolicyd` is stuck at about 100% CPU. Full pytest cannot
be treated as valid until that service is restarted or the machine is rebooted.

### Swift

`swift test --jobs 1` was attempted. It produced no test output after roughly
two minutes and was found stuck in SwiftPM's generated `gui-manifest` executable:

```text
swift-test --jobs 1
.../TemporaryDirectory.../gui-manifest -fileno 4 ...
```

That process was terminated cleanly. This is consistent with the same local
code-signing/native-executable gate affecting Python native extensions.

Current blocker process observed:

```text
/usr/libexec/syspolicyd
# elapsed about 1 day 22 hours, about 70-100% CPU
```

Admin action needed:

```bash
sudo killall syspolicyd
# or reboot macOS
```

### Go / TUI

`go test ./...` in `tui/` could not run because `go` is not installed on PATH
in this environment.

## Remaining Release Work

1. Restart `syspolicyd` or reboot, then run the full validation suite:
   `poetry run python -m pytest -q`, `swift test --jobs 1`, `zig build test`,
   and the relevant Xcode/iOS release gates.
2. Identify and run the external/hive test command; record the command and
   result in this document.
3. Reconcile `UNIMPLEMENTED_FEATURES.md` against the current implementation.
   Remove stale completed gaps and convert real gaps into tracked release tasks.
4. Work through the unresolved findings in `docs/reviews/*.md`, especially
   slash commands, terminal behavior, workflows/approvals/prompts, navigation,
   landings/issues/workspaces, and dashboard review items.
5. Decide whether vendored `ghostty`, `tmux`, and generated/build trees are
   excluded from the "no TODO/stub" policy. If not excluded, the current
   requirement is not feasible without upstream/vendor cleanup.
6. Add release-grade observability criteria: structured event taxonomy, log
   retention, user bug-report bundle coverage, and optional OTEL/export story.
7. Update README/status docs once aggregate tests and product parity gates are
   genuinely green.
