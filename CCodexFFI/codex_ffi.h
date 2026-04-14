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

/// Send a prompt to codex. Blocks until the turn completes.
/// Events are delivered via `callback`.
/// Returns 0 on success, -1 on failure.
int32_t codex_send(CodexHandle *handle, const char *prompt,
                   CodexEventCallback callback, void *user_data);

/// Cancel the current operation.
void codex_cancel(CodexHandle *handle);

/// Destroy a codex session and free all resources.
void codex_destroy(CodexHandle *handle);

#endif /* CODEX_FFI_H */
