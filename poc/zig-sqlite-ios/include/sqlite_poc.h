// PoC: Zig-managed SQLite wrapper for iOS.
//
// Swift calls open() with an absolute path (the app's Documents directory).
// Zig opens the database using system `libsqlite3` (linked via `-lsqlite3`;
// the dylib stub `libsqlite3.tbd` lives in the iOS SDK). All SQL is executed
// inside Zig to keep the test surface honest — Swift does NOT call sqlite3_*
// directly.
//
// Ownership:
//   - `sqpoc_open` returns an opaque handle. Caller owns it and MUST call
//     `sqpoc_close` exactly once. Double-close is a no-op.
//   - `sqpoc_last_error` returns a pointer owned by the handle; valid until
//     the next call on that handle.
//   - Inserted rows are parameterised via `sqpoc_insert_row(id, text)`.

#ifndef SQPOC_H
#define SQPOC_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

typedef struct sqpoc_handle sqpoc_handle_t;

// Open (or create) a DB at `path` and ensure the PoC schema exists.
// Returns NULL on failure; call `sqpoc_open_error` for a static English message.
sqpoc_handle_t *sqpoc_open(const char *path);

// Static error string for the most recent `sqpoc_open` failure. Thread-local.
const char *sqpoc_open_error(void);

// Close and free the handle. Safe to call with NULL.
void sqpoc_close(sqpoc_handle_t *h);

// Insert one row into the PoC table. Returns 0 on success, nonzero on error.
int32_t sqpoc_insert_row(sqpoc_handle_t *h, int64_t id, const char *text);

// Count rows in the PoC table. Returns -1 on error.
int64_t sqpoc_count_rows(sqpoc_handle_t *h);

// Fetch the `text` column for the given id. On success writes up to
// `buf_len-1` bytes + NUL into `buf` and returns the full length (excluding
// NUL). Returns -1 if the row does not exist, -2 on error.
int64_t sqpoc_get_text(sqpoc_handle_t *h, int64_t id, char *buf, int32_t buf_len);

// Last error message for operations on this handle. NUL-terminated, owned
// by the handle (do not free).
const char *sqpoc_last_error(sqpoc_handle_t *h);

#ifdef __cplusplus
}
#endif
#endif // SQPOC_H
