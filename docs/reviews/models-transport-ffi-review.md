# Models Transport FFI Review

Review scope: `DATA_MODELS`, `DATA_TRANSPORT`, `FFI`, and `STREAMING` feature groups, focused on `SmithersModels.swift`, `SmithersClient.swift`, `codex-ffi.h`, `CCodexFFI/codex_ffi.h`, the Swift FFI consumers, and related unit test files. Per request, `swift test` was not run.

## Findings

### High: Missing approval decision actions default to approved

`ApprovalDecision.init(from:)` falls back to `"approved"` when `action`, `decision`, and `status` are all absent at `SmithersModels.swift:735`. That is unsafe for a decision/history model: malformed rows, legacy rows, or unresolved approval rows without a decision field are presented as an approval instead of being rejected or treated as pending/unknown.

This is especially risky because `listRecentDecisionsFromSQLite()` reads from `_smithers_approvals` at `SmithersClient.swift:3534` and then filters decoded decisions for `approved` or `denied` at `SmithersClient.swift:3541`. If a row can take the direct Codable path with no explicit decision field, the model supplies `approved` and the row survives the history filter.

The test suite currently locks in the unsafe behavior with `testDecisionDefaultsToApproved` in `Tests/SmithersGUITests/AdditionalSmithersModelsTests.swift:112`.

Recommendation: make approval decisions require an explicit decision/action/status, or default to a non-terminal value such as `pending`/`unknown` and filter it out of recent decisions. Add a regression for a decision payload that has `id`, `runId`, and `nodeId`, but no action field.

### High: The FFI callback lifetime contract is not explicit enough for the Swift wrapper

The headers say `event_json` is valid only during the callback at `codex-ffi.h:10`, but they do not state whether callbacks are guaranteed to be synchronous and complete before `codex_send` returns. The Swift wrapper assumes that stronger contract: `CodexBridge.send` retains `CallbackBox` at `AgentService.swift:68`, passes it as `user_data` to `codex_send` at `AgentService.swift:71`, and releases it immediately after `codex_send` returns at `AgentService.swift:79`.

If the C/Rust side ever dispatches a callback after `codex_send` returns, or retains `user_data` for cancellation/cleanup work, the next callback dereferences freed Swift memory. The header also does not define whether `codex_cancel` may be called concurrently with `codex_send`, even though the Swift lifecycle does exactly that from another detached task at `AgentService.swift:391`.

Recommendation: strengthen the C API contract in both headers. Either document that callbacks are strictly inline and `user_data` is never retained past `codex_send`, or move ownership to an explicit registration/session lifetime. Also document `codex_cancel` thread-safety relative to `codex_send`. Add nullability annotations while there so Swift imports the API with safer optionality.

### Medium: Direct approval decision decoding loses `_ms` timestamp aliases

`ApprovalDecision` decodes `resolvedAt`, `resolved_at`, `decidedAt`, and `decided_at`, plus `requestedAt` and `requested_at`, at `SmithersModels.swift:741` and `SmithersModels.swift:753`. It does not decode common millisecond aliases such as `decided_at_ms`, `resolved_at_ms`, or `requested_at_ms`.

The dictionary fallback in `SmithersClient.swift:3808` does include `decided_at_ms` and `requested_at_ms`, but that fallback only runs after direct Codable decoding fails. A valid array payload with no object-valued `payload` field can direct-decode successfully and silently lose timestamps, which then affects decision sorting at `SmithersClient.swift:3900` and the history display.

The existing exec transport test uses `decided_at_ms` and `requested_at_ms` at `Tests/SmithersGUITests/SmithersClientTests.swift:1051`, but it also includes an object `payload`, which forces the direct Codable path to fail and hides this alias gap.

Recommendation: add the `_ms` aliases to `ApprovalDecision.CodingKeys` and decode them before falling back to nil. Add a model-level test with `decided_at_ms` and no object payload so it exercises the direct Codable path.

### Medium: Raw-value status enums are brittle against new backend states

`RunStatus` and `WorkflowStatus` are raw `Codable` enums at `SmithersModels.swift:6` and `SmithersModels.swift:155`. Unknown values fail decoding for direct API/CLI shapes. The separate CLI adapter then collapses every unknown run status to `.running` at `SmithersClient.swift:5876`, which can mislabel a new terminal or blocked state as actively running.

The current tests only cover the five known `RunStatus` cases and the four known `WorkflowStatus` cases. There is no unknown-status regression.

Recommendation: use a resilient status model with an `.unknown(String)` case, or store backend status as a string and derive UI labels separately. At minimum, do not map unknown CLI statuses to `.running`; preserve the raw value or map to an explicit unknown state.

### Medium: SSE parsing drops and mutates valid SSE data

The SSE parser inside `sseStream` only emits an event when `dataBuffer` is non-empty at `SmithersClient.swift:5476` and `SmithersClient.swift:5497`, so `data:` events with an intentionally empty payload are dropped. It also trims all leading and trailing whitespace from `data:` values at `SmithersClient.swift:5492`; the SSE format only permits stripping one optional leading space after the colon, and trailing spaces are payload data.

The parser also ignores `id:` and `retry:` fields and has no reusable production parser. The tests define a private copy of the parsing logic at `Tests/SmithersGUITests/SmithersClientTests.swift:8`, so they can drift from production and cannot validate the actual `AsyncBytes` path, fallback URL handling, cancellation, or non-200 behavior.

Recommendation: extract a small `SSEParser` type that implements the SSE field rules, preserves payload whitespace, handles empty `data:` events intentionally, and can be unit-tested directly. Add stream-level tests with a custom `URLProtocol` or injected session for multi-URL fallback and cancellation.

### Medium: CLI timeout handling can still block forever

`execBinaryArgs` enforces a deadline while the process is running, but the timeout branch then calls `process.terminate()`, optionally `process.interrupt()`, and finally `process.waitUntilExit()` without another deadline at `SmithersClient.swift:746`. A child process that ignores SIGTERM/SIGINT, or a subprocess tree that keeps descriptors open, can still hang the detached task after the timeout path is reached.

Recommendation: after SIGTERM, wait for a short bounded grace period, then send SIGKILL to the process group or child process and bound the final wait. Add a focused test around a fake CLI that ignores termination; this can be done without `swift test` in review, but should be in the suite.

### Low: Prompt input defaults only decode strings

`PromptInput` accepts `default` and `defaultValue`, but both are decoded as `String` only at `SmithersModels.swift:810`. `WorkflowLaunchField` already handles non-string JSON defaults via `JSONValue` at `SmithersModels.swift:193`, so prompt inputs are less complete than workflow inputs. A prompt schema that returns a boolean, number, array, or object default can fail decoding or lose the default depending on the payload path.

Recommendation: mirror `WorkflowLaunchField` by decoding a string first, then `JSONValue` to compact JSON/text. Add tests for boolean, number, object, and array defaults for both `default` and `defaultValue`.

### Low: FFI headers are duplicated with no drift guard

`codex-ffi.h` and `CCodexFFI/codex_ffi.h` are currently identical, and `CCodexFFI/module.modulemap:2` imports the copy under `CCodexFFI`. Keeping two declarations of the same C ABI is easy to break accidentally; a future edit to one header can compile one integration path while leaving the other stale.

Recommendation: generate one header from the other, symlink if the repo policy allows it, or add a lightweight CI/script check that diffs the two files. Also add `extern "C"` guards if any C++ consumers may include the public header.

## Coverage Review

The model tests cover many happy-path Codable shapes, including run status cases, workflow DAG lossy int/bool decoding, approval/source helpers, prompt default aliases, SQL rows, chat block deduplication, and SSE run-id extraction. The client tests also cover several real fake-CLI paths for workflows, approvals, prompts, JJHub, cron, agents, and connection checks.

The highest-risk gaps are:

- Unknown enum values are not covered for `RunStatus`, `WorkflowStatus`, Codex reasoning/approval/sandbox enums, or MCP transport variants beyond one unknown transport type.
- Approval decision tests cover `_ms` timestamp aliases only through a fallback path, not through direct Codable decoding.
- Several CLI command tests are documentation-style hard-coded arrays rather than exercising production command builders or fake CLI execution.
- Fake CLI call logs use `"$*"` and string `contains` assertions, so they cannot prove argument boundaries when values contain spaces, newlines, quotes, or shell metacharacters.
- SSE coverage tests a copied parser, not the production parser or network stream behavior.
- FFI config/model/MCP tests skip real FFI calls during unit tests, and there are no callback lifetime, null pointer, invalid UTF-8, delayed callback, or concurrent cancel/send tests.
- Error handling coverage is thin for HTTP non-2xx payload extraction, CLI stderr/stdout parsing, timeout escalation, and fallback behavior when HTTP is configured but fails with authorization/server errors.
- Non-string defaults are covered for workflow launch fields but not prompt inputs.
- The duplicate FFI headers have no test or script enforcing that they stay in sync.

## Feature Coverage Summary

- Data models: broad shape coverage exists, but status enums and several Codable models are not resilient to unknown or richer backend payloads.
- Data transport: CLI and HTTP fallback paths are implemented in many places, with useful fake-CLI tests. Error handling and argument-boundary tests need tightening.
- FFI: string-returning config calls free returned pointers correctly in the Swift consumers, but callback lifetime, cancellation thread-safety, and header nullability are under-specified.
- Streaming: `AsyncStream<SSEEvent>` plumbing exists, run-id extraction/filtering is tested, but the SSE parser should be extracted and made spec-aware.

## Verification

Commands used during review were source inspection only (`rg`, `nl`, `sed`, `find`, `diff`, and `git diff`). `swift test` was not run, per request.
