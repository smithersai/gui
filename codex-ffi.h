#ifndef CODEX_FFI_H
#define CODEX_FFI_H

#include <stdint.h>

/// Opaque handle to a codex session.
typedef struct CodexHandle CodexHandle;

/// Callback type for receiving events.
/// `event_json` is a UTF-8 JSON string (valid only during the callback).
/// `user_data` is the pointer passed to codex_send.
typedef void (*CodexEventCallback)(const char *event_json, void *user_data);

/// Create a new codex session.
/// `cwd` - working directory path (UTF-8 C string).
/// Returns NULL on failure.
CodexHandle *codex_create(const char *cwd);

/// Create a new codex session with optional model/reasoning/policy overrides.
/// Pass NULL for `model`, `reasoning_effort`, `approval_policy`, and/or
/// `sandbox_mode` to use config defaults.
CodexHandle *codex_create_with_options(const char *cwd,
                                       const char *model,
                                       const char *reasoning_effort,
                                       const char *approval_policy,
                                       const char *sandbox_mode);

/// Send a prompt to codex. Blocks until the turn completes.
/// Events are delivered via `callback`.
/// Returns 0 on success, -1 on failure.
int32_t codex_send(CodexHandle *handle, const char *prompt,
                   CodexEventCallback callback, void *user_data);

/// Cancel the current operation.
void codex_cancel(CodexHandle *handle);

/// Destroy a codex session and free all resources.
void codex_destroy(CodexHandle *handle);

/// Read the effective model selection as JSON:
/// {"ok":bool,"model":string|null,"reasoning_effort":string|null,
///  "active_profile":string|null,"error":string|null}
char *codex_get_model_selection_json(const char *cwd);

/// Read the effective approval/sandbox selection as JSON:
/// {"ok":bool,"approval_policy":string|null,"sandbox_mode":string|null,
///  "error":string|null}
char *codex_get_approval_sandbox_json(const char *cwd);

/// Read model presets as JSON:
/// {"ok":bool,"presets":[{"id":...,"model":...,"display_name":...,
/// "description":...,"default_reasoning_effort":...,
/// "supported_reasoning_efforts":[{"effort":...,"description":...}],
/// "is_default":bool}],"error":string|null}
char *codex_get_model_presets_json(void);

/// Persist model selection using Codex config/profile semantics. Returns the
/// same JSON shape as `codex_get_model_selection_json`.
char *codex_persist_model_selection_json(const char *cwd,
                                         const char *model,
                                         const char *reasoning_effort);

/// Read configured MCP servers and live MCP tool/resource/auth status as JSON:
/// {"ok":bool,"servers":[...],"errors":[...],"error":string|null}
char *codex_get_mcp_status_json(const char *cwd);

/// Free strings returned by codex_*_json APIs.
void codex_string_free(char *value);

#endif /* CODEX_FFI_H */
