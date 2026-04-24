// libsmithers embedding API.
//
// This header is the SKELETON contract between:
//   - the Zig core (libsmithers/src/)
//   - the macOS Swift shell (macos/Sources/Smithers/)
//   - the Linux GTK shell (linux/, also in Zig but consumes the ABI in-process)
//
// Architectural model is taken verbatim from ghostty (see ghostty/include/ghostty.h
// and ghostty/src/apprt/embedded.zig). Key rules:
//
//   1. All types prefixed with `smithers_`.
//   2. Opaque handles are `void *` aliases; never peer inside from the host.
//   3. Any non-opaque struct or enum defined here is duplicated in
//      libsmithers/src/apprt/structs.zig with a `// keep in sync` comment.
//   4. Host → core calls are synchronous and expected to be on the main thread.
//   5. Core → host events arrive via the callbacks registered in
//      smithers_runtime_config_s at app_new time.
//   6. Strings: when the core allocates and returns a string, it also exposes a
//      paired `smithers_*_free` function. The host must never free core-allocated
//      memory with its own allocator.
//   7. This header is the source of truth. If a codex stream needs a change,
//      drop libsmithers/ABI_CHANGE_REQUEST_<slug>.md instead of editing directly.
//
// THIS FILE IS A SKELETON. Codex Stream A is expected to:
//   - keep all signatures here stable (or request changes via the process above)
//   - fill in any missing structs/enums required to implement the domains listed
//     at the bottom of this file
//   - expand the per-domain function sections as implementation proceeds

#ifndef SMITHERS_H
#define SMITHERS_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

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

#define SMITHERS_SUCCESS 0

//------------------------------------------------------------------------------
// Opaque handles

typedef void *smithers_app_t;          // global app: workspaces, recents, config
typedef void *smithers_session_t;      // one tab/session (run, terminal, chat)
typedef void *smithers_client_t;       // daemon/CLI transport (HTTP + SSE)
typedef void *smithers_workspace_t;    // an open workspace (root path, state)
typedef void *smithers_palette_t;      // command palette / slash command model
typedef void *smithers_persistence_t;  // SQLite-backed session persistence
typedef void *smithers_workflow_t;     // a workflow definition
typedef void *smithers_run_t;          // an active run (subscribed devtools)
typedef void *smithers_event_stream_t; // async event stream (SSE, devtools, chat)

//------------------------------------------------------------------------------
// Primitive result / string types

typedef struct {
  const char *ptr; // UTF-8, NUL-terminated; owned by core until *_free is called
  size_t len;      // excludes trailing NUL
} smithers_string_s;

SMITHERS_API void smithers_string_free(smithers_string_s s);

typedef struct {
  int32_t code;    // 0 on success, nonzero on error (domain-specific)
  const char *msg; // optional NUL-terminated error message (core-owned)
} smithers_error_s;

SMITHERS_API void smithers_error_free(smithers_error_s e);

// A core-allocated blob that the host treats as opaque bytes.
typedef struct {
  const uint8_t *ptr;
  size_t len;
} smithers_bytes_s;

SMITHERS_API void smithers_bytes_free(smithers_bytes_s b);

//------------------------------------------------------------------------------
// Platform

typedef enum {
  SMITHERS_PLATFORM_INVALID = 0,
  SMITHERS_PLATFORM_MACOS,
  SMITHERS_PLATFORM_LINUX,
} smithers_platform_e;

typedef enum {
  SMITHERS_COLOR_SCHEME_LIGHT = 0,
  SMITHERS_COLOR_SCHEME_DARK = 1,
} smithers_color_scheme_e;

//------------------------------------------------------------------------------
// Session kind (referenced by both actions and session options)

typedef enum {
  SMITHERS_SESSION_KIND_TERMINAL = 0,
  SMITHERS_SESSION_KIND_CHAT,
  SMITHERS_SESSION_KIND_RUN_INSPECT,
  SMITHERS_SESSION_KIND_WORKFLOW,
  SMITHERS_SESSION_KIND_MEMORY,
  SMITHERS_SESSION_KIND_DASHBOARD,
} smithers_session_kind_e;

//------------------------------------------------------------------------------
// Actions (host ← core)
//
// Modelled on ghostty apprt.action.Action: a tagged union of things the core
// wants the host to do. Each apprt impl (Swift AppKit, GTK) handles the same
// set. New variants MUST be appended (never renumbered).

typedef enum {
  SMITHERS_ACTION_NONE = 0,

  // Windowing / navigation
  SMITHERS_ACTION_OPEN_WORKSPACE,         // payload: path string
  SMITHERS_ACTION_CLOSE_WORKSPACE,
  SMITHERS_ACTION_NEW_SESSION,            // payload: session_kind_e
  SMITHERS_ACTION_CLOSE_SESSION,          // payload: session handle
  SMITHERS_ACTION_FOCUS_SESSION,
  SMITHERS_ACTION_PRESENT_COMMAND_PALETTE,
  SMITHERS_ACTION_DISMISS_COMMAND_PALETTE,

  // Notifications / toasts
  SMITHERS_ACTION_SHOW_TOAST,             // payload: title, body, kind
  SMITHERS_ACTION_DESKTOP_NOTIFY,         // payload: title, body

  // Workflow / run lifecycle
  SMITHERS_ACTION_RUN_STARTED,
  SMITHERS_ACTION_RUN_FINISHED,
  SMITHERS_ACTION_RUN_STATE_CHANGED,
  SMITHERS_ACTION_APPROVAL_REQUESTED,

  // Clipboard / shell
  SMITHERS_ACTION_CLIPBOARD_WRITE,
  SMITHERS_ACTION_OPEN_URL,               // payload: url

  // Config
  SMITHERS_ACTION_CONFIG_CHANGED,

  SMITHERS_ACTION__MAX, // sentinel; do not use
} smithers_action_tag_e;

// The payload is a tagged union. Codex Stream A designs the full struct; this
// is a minimal skeleton. Values are borrowed for the duration of the callback
// unless the tag-specific comment says otherwise.
typedef struct {
  smithers_action_tag_e tag;
  union {
    struct { const char *path; } open_workspace;
    struct { smithers_session_kind_e kind; } new_session;
    struct { smithers_session_t session; } close_session;
    struct { const char *title; const char *body; int32_t kind; } toast;
    struct { const char *title; const char *body; } desktop_notify;
    struct { const char *url; } open_url;
    struct { const char *text; } clipboard_write;
    struct { const char *run_id; } run_event;
    // extend as needed; keep in sync with apprt/action.zig
    uint8_t _reserved[64];
  } u;
} smithers_action_s;

// Target of an action: app-level vs session-scoped.
typedef enum {
  SMITHERS_ACTION_TARGET_APP = 0,
  SMITHERS_ACTION_TARGET_SESSION = 1,
} smithers_action_target_tag_e;

typedef struct {
  smithers_action_target_tag_e tag;
  union {
    smithers_app_t app;
    smithers_session_t session;
  } u;
} smithers_action_target_s;

//------------------------------------------------------------------------------
// Runtime config (callbacks the host provides to the core)

typedef void *smithers_userdata_t;

typedef struct {
  smithers_userdata_t userdata;

  // Core wants a tick of the app run loop (e.g. after an async event).
  void (*wakeup)(smithers_userdata_t);

  // Core requests the host perform an action. Returns true if handled.
  bool (*action)(smithers_app_t, smithers_action_target_s, smithers_action_s);

  // Clipboard (host implements using native APIs).
  //
  // read_clipboard: on success, fills *out with UTF-8 bytes BORROWED by the
  // host for the duration of this call. Core MUST copy the bytes synchronously
  // before returning from the callback and MUST NOT pass the returned value to
  // smithers_string_free. Hosts return host-owned storage; libsmithers never
  // frees it. Returns true iff *out is populated.
  bool (*read_clipboard)(smithers_userdata_t, smithers_string_s *out);
  void (*write_clipboard)(smithers_userdata_t, const char *text);

  // Persistence notification: core has updated state the host may want to mirror.
  void (*state_changed)(smithers_userdata_t);

  // Optional logging sink. Level: 0=trace,1=debug,2=info,3=warn,4=error.
  void (*log)(smithers_userdata_t, int32_t level, const char *msg);

  // Optional path to the sqlite database used to persist app-level state
  // (recent workspaces, etc.). When null, state is kept in-memory only.
  const char *recents_db_path;
} smithers_runtime_config_s;

//------------------------------------------------------------------------------
// Top-level init / info

typedef struct {
  const char *version;      // "0.1.0"
  const char *commit;       // git sha or "unknown"
  smithers_platform_e platform;
} smithers_info_s;

SMITHERS_API int32_t smithers_init(int argc, char **argv);
SMITHERS_API smithers_info_s smithers_info(void);

//------------------------------------------------------------------------------
// App
//
// The app owns: global config, list of workspaces, recent workspace store,
// global palette, global event bus. It lives for the lifetime of the process.

SMITHERS_API smithers_app_t smithers_app_new(const smithers_runtime_config_s *cfg);
SMITHERS_API void           smithers_app_free(smithers_app_t app);

SMITHERS_API void           smithers_app_tick(smithers_app_t app);
SMITHERS_API smithers_userdata_t smithers_app_userdata(smithers_app_t app);
SMITHERS_API void           smithers_app_set_color_scheme(smithers_app_t app, smithers_color_scheme_e s);

// Workspace management
SMITHERS_API smithers_workspace_t smithers_app_open_workspace(smithers_app_t app, const char *path);
SMITHERS_API void smithers_app_close_workspace(smithers_app_t app, smithers_workspace_t ws);
SMITHERS_API smithers_string_s smithers_app_active_workspace_path(smithers_app_t app);
SMITHERS_API smithers_string_s smithers_app_recent_workspaces_json(smithers_app_t app);
SMITHERS_API void smithers_app_remove_recent_workspace(smithers_app_t app, const char *path);

//------------------------------------------------------------------------------
// Session (one tab/run/terminal/chat surface)
//
// Mirrors ghostty_surface_t in role: the long-lived per-tab object the UI binds
// to. The Swift SurfaceView and GTK widget both wrap one of these.

typedef struct {
  smithers_session_kind_e kind;
  const char *workspace_path; // nullable; defaults to active workspace
  const char *target_id;      // nullable; kind-specific (run id, workflow path)
  smithers_userdata_t userdata;
} smithers_session_options_s;

SMITHERS_API smithers_session_t smithers_session_new(smithers_app_t app, smithers_session_options_s opts);
SMITHERS_API void smithers_session_free(smithers_session_t s);
SMITHERS_API smithers_session_kind_e smithers_session_kind(smithers_session_t s);
SMITHERS_API smithers_userdata_t smithers_session_userdata(smithers_session_t s);
SMITHERS_API smithers_string_s smithers_session_title(smithers_session_t s);

// Send user input (slash command, chat message, terminal text).
SMITHERS_API void smithers_session_send_text(smithers_session_t s, const char *text, size_t len);

// Subscribe to session-level events (chat blocks, devtools frames, status).
// Returns a stream handle; host pumps via smithers_event_stream_next.
SMITHERS_API smithers_event_stream_t smithers_session_events(smithers_session_t s);

//------------------------------------------------------------------------------
// Event stream (SSE-like)
//
// Unified async event channel. Each event is a JSON string owned by the core.
// Host calls *_next until it returns tag=NONE, then waits for the wakeup
// callback before draining again.

typedef enum {
  SMITHERS_EVENT_NONE = 0,
  SMITHERS_EVENT_JSON,        // payload: json string (core-owned)
  SMITHERS_EVENT_END,         // stream closed
  SMITHERS_EVENT_ERROR,
} smithers_event_tag_e;

typedef struct {
  smithers_event_tag_e tag;
  smithers_string_s payload; // freed by smithers_event_free
} smithers_event_s;

SMITHERS_API smithers_event_s smithers_event_stream_next(smithers_event_stream_t stream);
SMITHERS_API void             smithers_event_free(smithers_event_s ev);
SMITHERS_API void             smithers_event_stream_free(smithers_event_stream_t stream);

//------------------------------------------------------------------------------
// Client (Smithers daemon / HTTP + CLI transport)
//
// This wraps what SmithersClient.swift does today. The full surface is large
// (~60+ methods). Codex Stream A will enumerate them, but the ABI strategy is:
//
//   - A single generic request entrypoint that takes a "method name" + JSON
//     body and returns JSON. Thin, stable, easy to evolve.
//   - A couple of specialized entrypoints for streaming endpoints (SSE, devtools).
//
// Swift / GTK shells both call through this.

SMITHERS_API smithers_client_t smithers_client_new(smithers_app_t app);
SMITHERS_API void              smithers_client_free(smithers_client_t c);

// Synchronous JSON-RPC-ish call. Method names mirror existing Swift methods
// (e.g. "listWorkflows", "inspectRun", "approveNode"). Arguments are JSON.
SMITHERS_API smithers_string_s smithers_client_call(
    smithers_client_t c,
    const char *method,
    const char *args_json,
    smithers_error_s *out_err);

// Streaming variants return an event stream the host drains.
SMITHERS_API smithers_event_stream_t smithers_client_stream(
    smithers_client_t c,
    const char *method,
    const char *args_json,
    smithers_error_s *out_err);

//------------------------------------------------------------------------------
// Command palette + slash commands
//
// Wraps SlashCommands.swift, CommandPaletteModel.swift, and the WorkspaceFileSearchIndex.

typedef enum {
  SMITHERS_PALETTE_MODE_ALL = 0,
  SMITHERS_PALETTE_MODE_COMMANDS,
  SMITHERS_PALETTE_MODE_FILES,
  SMITHERS_PALETTE_MODE_WORKFLOWS,
  SMITHERS_PALETTE_MODE_WORKSPACES,
  SMITHERS_PALETTE_MODE_RUNS,
} smithers_palette_mode_e;

SMITHERS_API smithers_palette_t smithers_palette_new(smithers_app_t app);
SMITHERS_API void               smithers_palette_free(smithers_palette_t p);
SMITHERS_API void               smithers_palette_set_mode(smithers_palette_t p, smithers_palette_mode_e m);
SMITHERS_API void               smithers_palette_set_query(smithers_palette_t p, const char *query);
// Returns a JSON array of [{id, title, subtitle, kind, score}, ...]. Core-owned.
SMITHERS_API smithers_string_s  smithers_palette_items_json(smithers_palette_t p);
SMITHERS_API smithers_error_s   smithers_palette_activate(smithers_palette_t p, const char *item_id);

// Pure parser (no state): parse a raw input into a slash command + args.
// Returns JSON: {"command": "...", "args": [...], "mode": "..."}.
SMITHERS_API smithers_string_s smithers_slashcmd_parse(const char *input);

//------------------------------------------------------------------------------
// CWD resolver (pure)
//
// Port of CWDResolver.swift. Given an input (env, arg, or nil), returns the
// resolved working directory. Deterministic and easy to unit-test.

SMITHERS_API smithers_string_s smithers_cwd_resolve(const char *requested /* nullable */);

//------------------------------------------------------------------------------
// Persistence (SQLite-backed session store)
//
// Wraps SessionPersistenceStore.swift / SQLiteSessionPersistence.

SMITHERS_API smithers_persistence_t smithers_persistence_open(const char *db_path, smithers_error_s *out_err);
SMITHERS_API void                   smithers_persistence_close(smithers_persistence_t p);
// All load/save operations are JSON-based to keep the ABI narrow.
SMITHERS_API smithers_string_s smithers_persistence_load_sessions(smithers_persistence_t p, const char *workspace_path);
SMITHERS_API smithers_error_s  smithers_persistence_save_sessions(smithers_persistence_t p, const char *workspace_path, const char *sessions_json);

//------------------------------------------------------------------------------
// Domains delegated to Codex Stream A
//
// The following Swift files are in scope for full Zig port. Stream A designs
// whatever additional ABI surface is needed to expose them, following the
// "narrow generic call + JSON" pattern above whenever possible (avoid typed
// structs for everything that is just a Codable model today).
//
//   SmithersClient.swift           → smithers_client_* + JSON-RPC methods
//   SmithersModels.swift           → JSON shapes only; no typed C structs
//   SessionStore.swift             → owned by smithers_app_t internally
//   SessionPersistenceStore.swift  → smithers_persistence_*
//   SlashCommands.swift            → smithers_slashcmd_*, smithers_palette_*
//   CommandPaletteModel.swift      → smithers_palette_*
//   CWDResolver.swift              → smithers_cwd_resolve
//   WorkspaceManager.swift         → smithers_app_{open,close,recent}_workspace
//   Models.swift                   → JSON shapes only (RunWorkspace, TerminalWorkspaceRecord, etc.)
//
// Out of scope (stay in Swift / GTK, not ported):
//   - All *View.swift SwiftUI files
//   - Theme.swift, KeyboardShortcut*.swift, UITestSupport.swift
//   - AppKit/NSView integration, SceneKit, etc.

//------------------------------------------------------------------------------
// Core runtime (ticket 0120) — connection-scoped production runtime.
//
// This is the NEW center of gravity replacing the app/session/client split
// above. One `smithers_core_t` per process, one `smithers_core_session_t`
// per engine connection. A session owns:
//   - Electric shape subscriptions (see 0093)
//   - WebSocket PTY attachments (see 0094)
//   - HTTP JSON writes (pessimistic write then await shape echo)
//   - Bounded per-connection SQLite cache (per 0103 + spec)
//   - Platform-injected OAuth credentials (0109) via callback — core
//     NEVER reads tokens from disk.
//
// The old `smithers_app_t` / `smithers_client_t` / `smithers_session_t`
// surface above is retained for compatibility (REMOVE-AFTER-0126) while
// desktop-local migrates. New downstream code should target THIS surface
// exclusively.

typedef void *smithers_core_t;               // process-lifetime runtime
typedef void *smithers_core_session_t;       // one engine connection
typedef uint64_t smithers_subscription_t;    // handle for a shape subscription
typedef uint64_t smithers_write_future_t;    // handle for a pending HTTP write
typedef void *smithers_pty_handle_t;         // attached PTY stream

// Credentials token returned by the platform.
// The core copies these bytes synchronously inside the callback; the host
// retains ownership of the underlying storage (typically Keychain-backed).
typedef struct {
  const char *bearer;          // NUL-terminated; NULL if no credentials
  int64_t expires_unix_ms;     // 0 if unknown
  const char *refresh_token;   // optional; NULL if not provided
} smithers_credentials_s;

// Platform-provided credentials callback. Core invokes this when it needs
// a fresh bearer (connect, 401 recovery, pre-flight). Host implementations
// typically read from iOS/macOS Keychain.
//
// Contract: fill `*out` with borrowed pointers valid for the duration of
// the callback. Return true iff credentials were populated. Returning
// false triggers the auth-expired event on the session.
typedef bool (*smithers_credentials_fn)(smithers_userdata_t ud,
                                        smithers_credentials_s *out);

// Engine connection configuration — passed to smithers_core_connect.
// `base_url` is the plue API base (e.g. https://api.plue.example).
// `shape_proxy_url` is the Electric auth-proxy URL.
// `ws_pty_url` is the WebSocket PTY endpoint. Either may be NULL to
// disable that transport (e.g. read-only sessions).
typedef struct {
  const char *engine_id;       // stable id, used as cache partition key
  const char *base_url;
  const char *shape_proxy_url;
  const char *ws_pty_url;
  const char *cache_dir;       // per-connection cache directory; NULL => memory
  uint32_t cache_max_mb;       // 0 => unbounded; otherwise LRU evicts unpinned
} smithers_core_engine_config_s;

// Session lifecycle events delivered to the host.
typedef enum {
  SMITHERS_CORE_EVENT_STATE_CHANGED = 0,   // connected / disconnected / reconnecting
  SMITHERS_CORE_EVENT_AUTH_EXPIRED,        // credentials callback returned false or got 401
  SMITHERS_CORE_EVENT_RECONNECT,           // transport reconnected
  SMITHERS_CORE_EVENT_SHAPE_DELTA,         // a subscribed shape applied new rows
  SMITHERS_CORE_EVENT_WRITE_ACK,           // HTTP write future resolved
  SMITHERS_CORE_EVENT_PTY_DATA,            // bytes arrived on a PTY handle
  SMITHERS_CORE_EVENT_PTY_CLOSED,          // PTY stream ended
} smithers_core_event_tag_e;

typedef void (*smithers_core_event_fn)(
    smithers_userdata_t ud,
    smithers_core_event_tag_e tag,
    const char *payload_json_or_null);

// --- Core lifecycle ---

// Create a new core. The credentials callback is required; it's how the
// core acquires bearer tokens for every engine it connects to. `userdata`
// is passed verbatim to the callback.
//
// Returns NULL and sets `*out_err` if the feature flag
// `remote_sandbox_enabled` is off, or if initialization fails.
SMITHERS_API smithers_core_t smithers_core_new(
    smithers_credentials_fn credentials_cb,
    smithers_userdata_t userdata,
    smithers_error_s *out_err);

SMITHERS_API void smithers_core_free(smithers_core_t core);

// --- Session lifecycle ---

// Open a session for the given engine. Returns NULL on failure.
// On 401 during initial handshake, the core fires AUTH_EXPIRED and returns
// a session in state=disconnected that can be retried after token refresh.
SMITHERS_API smithers_core_session_t smithers_core_connect(
    smithers_core_t core,
    const smithers_core_engine_config_s *cfg,
    smithers_error_s *out_err);

SMITHERS_API void smithers_core_disconnect(smithers_core_session_t s);

// Register a single event callback per session. Re-registering replaces
// the previous callback.
SMITHERS_API void smithers_core_register_callback(
    smithers_core_session_t s,
    smithers_core_event_fn cb,
    smithers_userdata_t userdata);

// --- Shape subscriptions ---

// Subscribe to an Electric shape. `shape_name` is one of the production
// shape names from 0114-0118 (agent_sessions, agent_messages, agent_parts,
// workspaces, workspace_sessions, approvals). `params_json` carries the
// server-side where clause parameters (e.g. repository filter).
//
// Returns 0 on failure; check out_err. On success, deltas begin arriving
// via SHAPE_DELTA events and rows land in the cache.
SMITHERS_API smithers_subscription_t smithers_core_subscribe(
    smithers_core_session_t s,
    const char *shape_name,
    const char *params_json,
    smithers_error_s *out_err);

SMITHERS_API void smithers_core_unsubscribe(
    smithers_core_session_t s,
    smithers_subscription_t handle);

// Pinning keeps a subscription's rows in the cache past LRU eviction.
// Default state is unpinned. Idempotent.
SMITHERS_API void smithers_core_pin(
    smithers_core_session_t s,
    smithers_subscription_t handle);
SMITHERS_API void smithers_core_unpin(
    smithers_core_session_t s,
    smithers_subscription_t handle);

// --- Cache reads ---

// Query the bounded per-connection cache. `where_sql` is an optional
// substring appended as `WHERE <where_sql>` (parameterized through the
// adapter's bindings; pass NULL for no filter). Returns a JSON array of
// rows, core-owned. For the skeleton, only the `agent_sessions` table is
// supported; other tables return an empty array and a non-zero err.code.
SMITHERS_API smithers_string_s smithers_core_cache_query(
    smithers_core_session_t s,
    const char *table,
    const char *where_sql,  // nullable
    int32_t limit,          // <= 0 => unbounded
    int32_t offset,
    smithers_error_s *out_err);

// --- Writes ---

// Issue an HTTP JSON write. `action` is the plue write route identifier
// (e.g. "agent_session.create"). `payload_json` is the request body.
// Returns 0 on failure. The future resolves via WRITE_ACK event carrying
// a JSON object: {"future_id": <id>, "ok": <bool>, "body": "...", "status": N}.
SMITHERS_API smithers_write_future_t smithers_core_write(
    smithers_core_session_t s,
    const char *action,
    const char *payload_json,
    smithers_error_s *out_err);

// --- PTY ---

SMITHERS_API smithers_pty_handle_t smithers_core_attach_pty(
    smithers_core_session_t s,
    const char *session_id,
    smithers_error_s *out_err);

SMITHERS_API smithers_error_s smithers_core_pty_write(
    smithers_pty_handle_t h,
    const uint8_t *bytes,
    size_t len);

SMITHERS_API smithers_error_s smithers_core_pty_resize(
    smithers_pty_handle_t h,
    uint16_t cols,
    uint16_t rows);

SMITHERS_API void smithers_core_detach_pty(smithers_pty_handle_t h);

// --- Cache maintenance ---

// Wipe the bounded cache for this session. Called by the platform on
// sign-out so no cached rows outlive credential revocation (per 0133).
SMITHERS_API smithers_error_s smithers_core_cache_wipe(
    smithers_core_session_t s);

// --- Test hooks (do NOT call from shipping code) ---

// Drive the transport tick synchronously. Used by SmithersRuntime's
// test target so integration tests are deterministic. Production code
// relies on a background event-loop thread; calling this from a
// shipping code path is a bug.
SMITHERS_API void smithers_core_tick_for_test(smithers_core_session_t s);

#ifdef __cplusplus
}
#endif
#endif // SMITHERS_H
