// libsmithers modern C ABI.
//
// This header is the source of truth for embedders. The legacy
// app/session/client/palette/persistence ABI was removed; downstream code
// should use the connection-scoped smithers_core_* runtime and the
// process-wide smithers_obs_* observability API.

#ifndef SMITHERS_H
#define SMITHERS_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

//------------------------------------------------------------------------------
// Visibility

#ifndef SMITHERS_API
#  if defined(SMITHERS_STATIC)
#    define SMITHERS_API
#  elif defined(_WIN32) || defined(_WIN64)
#    ifdef SMITHERS_BUILD_SHARED
#      define SMITHERS_API __declspec(dllexport)
#    else
#      define SMITHERS_API __declspec(dllimport)
#    endif
#  elif defined(__GNUC__) && __GNUC__ >= 4
#    define SMITHERS_API __attribute__((visibility("default")))
#  else
#    define SMITHERS_API
#  endif
#endif

typedef void *smithers_userdata_t;

//------------------------------------------------------------------------------
// Primitive result / string types

typedef struct {
  const char *ptr; // UTF-8, NUL-terminated; owned by core until freed.
  size_t len;      // excludes trailing NUL
} smithers_string_s;

SMITHERS_API void smithers_string_free(smithers_string_s s);

typedef struct {
  int32_t code;    // 0 on success, nonzero on error.
  const char *msg; // optional NUL-terminated error message, core-owned.
} smithers_error_s;

SMITHERS_API void smithers_error_free(smithers_error_s e);

typedef struct {
  const uint8_t *ptr;
  size_t len;
} smithers_bytes_s;

SMITHERS_API void smithers_bytes_free(smithers_bytes_s b);

//------------------------------------------------------------------------------
// Core runtime

typedef void *smithers_core_t;               // process-lifetime runtime
typedef void *smithers_core_session_t;       // one engine connection
typedef uint64_t smithers_subscription_t;    // shape subscription handle
typedef uint64_t smithers_write_future_t;    // pending HTTP write handle
typedef void *smithers_pty_handle_t;         // attached PTY stream

typedef struct {
  const char *bearer;          // NUL-terminated; NULL if no credentials
  int64_t expires_unix_ms;     // 0 if unknown
  const char *refresh_token;   // optional; NULL if not provided
} smithers_credentials_s;

typedef bool (*smithers_credentials_fn)(smithers_userdata_t ud,
                                        smithers_credentials_s *out);

typedef struct {
  const char *engine_id;       // stable id, used as cache partition key
  const char *base_url;        // plue API base URL
  const char *shape_proxy_url; // Electric auth-proxy URL; nullable
  const char *ws_pty_url;      // WebSocket PTY endpoint; nullable
  const char *cache_dir;       // NULL => memory
  uint32_t cache_max_mb;       // 0 => unbounded
} smithers_core_engine_config_s;

typedef enum {
  SMITHERS_CORE_EVENT_STATE_CHANGED = 0,
  SMITHERS_CORE_EVENT_AUTH_EXPIRED,
  SMITHERS_CORE_EVENT_RECONNECT,
  SMITHERS_CORE_EVENT_SHAPE_DELTA,
  SMITHERS_CORE_EVENT_WRITE_ACK,
  SMITHERS_CORE_EVENT_PTY_DATA,
  SMITHERS_CORE_EVENT_PTY_CLOSED,
} smithers_core_event_tag_e;

typedef void (*smithers_core_event_fn)(
    smithers_userdata_t ud,
    smithers_core_event_tag_e tag,
    const char *payload_json_or_null);

SMITHERS_API smithers_core_t smithers_core_new(
    smithers_credentials_fn credentials_cb,
    smithers_userdata_t userdata,
    smithers_error_s *out_err);

SMITHERS_API void smithers_core_free(smithers_core_t core);

// Test hook: force subsequently-created sessions to use FakeTransport.
SMITHERS_API void smithers_core_use_fake_transport_for_test(smithers_core_t core);

SMITHERS_API smithers_core_session_t smithers_core_connect(
    smithers_core_t core,
    const smithers_core_engine_config_s *cfg,
    smithers_error_s *out_err);

SMITHERS_API void smithers_core_disconnect(smithers_core_session_t s);

SMITHERS_API void smithers_core_register_callback(
    smithers_core_session_t s,
    smithers_core_event_fn cb,
    smithers_userdata_t userdata);

SMITHERS_API smithers_subscription_t smithers_core_subscribe(
    smithers_core_session_t s,
    const char *shape_name,
    const char *params_json,
    smithers_error_s *out_err);

SMITHERS_API void smithers_core_unsubscribe(
    smithers_core_session_t s,
    smithers_subscription_t handle);

SMITHERS_API void smithers_core_pin(
    smithers_core_session_t s,
    smithers_subscription_t handle);

SMITHERS_API void smithers_core_unpin(
    smithers_core_session_t s,
    smithers_subscription_t handle);

SMITHERS_API smithers_string_s smithers_core_cache_query(
    smithers_core_session_t s,
    const char *table,
    const char *where_sql,
    int32_t limit,
    int32_t offset,
    smithers_error_s *out_err);

SMITHERS_API smithers_write_future_t smithers_core_write(
    smithers_core_session_t s,
    const char *action,
    const char *payload_json,
    smithers_error_s *out_err);

SMITHERS_API smithers_pty_handle_t smithers_core_attach_pty(
    smithers_core_session_t s,
    const char *session_id,
    smithers_error_s *out_err);

SMITHERS_API uint64_t smithers_core_pty_public_handle(
    smithers_pty_handle_t h);

SMITHERS_API smithers_error_s smithers_core_pty_write(
    smithers_pty_handle_t h,
    const uint8_t *bytes,
    size_t len);

SMITHERS_API smithers_error_s smithers_core_pty_resize(
    smithers_pty_handle_t h,
    uint16_t cols,
    uint16_t rows);

SMITHERS_API void smithers_core_detach_pty(smithers_pty_handle_t h);

SMITHERS_API smithers_error_s smithers_core_cache_wipe(
    smithers_core_session_t s);

// Test hook for deterministic runtime tests.
SMITHERS_API void smithers_core_tick_for_test(smithers_core_session_t s);

//------------------------------------------------------------------------------
// Observability runtime

typedef void (*smithers_obs_event_fn)(
    smithers_userdata_t userdata,
    uint64_t seq,
    int64_t timestamp_ms,
    int32_t level,
    const char *subsystem,
    const char *name,
    int64_t duration_ms,
    const char *fields_json_or_null);

SMITHERS_API void smithers_obs_set_callback(
    smithers_obs_event_fn cb,
    smithers_userdata_t userdata);

SMITHERS_API void smithers_obs_set_min_level(int32_t level);

SMITHERS_API smithers_string_s smithers_obs_drain_json(uint64_t after_seq);

SMITHERS_API smithers_string_s smithers_obs_metrics_json(void);

SMITHERS_API void smithers_obs_emit(
    int32_t level,
    const char *subsystem,
    const char *name,
    int64_t duration_ms,
    const char *fields_json_or_null);

SMITHERS_API void smithers_obs_record_method(
    const char *method,
    int64_t duration_ms,
    bool is_error);

SMITHERS_API void smithers_obs_increment_counter(
    const char *name,
    uint64_t delta);

#ifdef __cplusplus
}
#endif
#endif // SMITHERS_H
