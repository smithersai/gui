// PoC FFI: Zig ↔ Swift observable counter.
//
// This header is the contract Swift imports. Threading model, lifecycle rules,
// and ownership semantics are documented in poc/zig-swift-ffi/README.md.
//
// Summary:
//   - A session owns one synthetic counter and one background "event loop"
//     thread. `ffi_tick` increments the counter synchronously from any thread;
//     the background thread drains the pending delta queue and invokes each
//     subscriber callback ONCE per tick, in monotonic order, from the same
//     thread. Swift is responsible for dispatching to the main actor.
//   - `user_data` is owned by the host. The Zig core never copies or frees it.
//     It is passed to the callback unmodified on every invocation.
//   - Subscribe/unsubscribe are safe to call from any thread. Unsubscribe
//     blocks briefly if a callback is currently in flight for that handle.
//   - `ffi_close_session` is safe to call with live subscribers; they are
//     force-removed. It is undefined behavior to call any `ffi_*` function
//     with a session pointer after `ffi_close_session` returns.

#ifndef FFI_POC_H
#define FFI_POC_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

typedef void *ffi_session_t;   // opaque; freed by ffi_close_session
typedef uint64_t ffi_sub_t;    // opaque subscription handle; 0 == invalid

// Callback signature. `counter` is the current monotonically-increasing value
// AFTER the tick. `user_data` is the pointer supplied at subscribe time.
//
// INVOKED ON: the session's event-loop thread (NOT Swift's main thread).
typedef void (*ffi_callback_t)(uint64_t counter, void *user_data);

// Create a new session. Spins up one background thread. Returns NULL on OOM.
ffi_session_t ffi_new_session(void);

// Destroy a session. Signals the loop thread, joins it, frees all state.
// Safe to call even with live subscribers.
void ffi_close_session(ffi_session_t s);

// Increment the counter and post an event onto the session's queue.
// Safe to call from any thread. Returns the counter value posted.
uint64_t ffi_tick(ffi_session_t s);

// Register a subscriber. Returns a handle that must be passed to unsubscribe.
// `user_data` ownership remains with the caller; Zig only stores the raw
// pointer for later callback invocation. Returns 0 on failure.
ffi_sub_t ffi_subscribe(ffi_session_t s, ffi_callback_t cb, void *user_data);

// Unregister a subscriber. After this returns, the callback will NOT be
// invoked again for this handle. If a callback for this handle is currently
// running on the loop thread, the call blocks until it returns.
void ffi_unsubscribe(ffi_session_t s, ffi_sub_t handle);

#ifdef __cplusplus
}
#endif
#endif // FFI_POC_H
