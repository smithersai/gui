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
  bool (*read_clipboard)(smithers_userdata_t, smithers_string_s *out);
  void (*write_clipboard)(smithers_userdata_t, const char *text);

  // Persistence notification: core has updated state the host may want to mirror.
  void (*state_changed)(smithers_userdata_t);

  // Optional logging sink. Level: 0=trace,1=debug,2=info,3=warn,4=error.
  void (*log)(smithers_userdata_t, int32_t level, const char *msg);
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

//------------------------------------------------------------------------------
// Session (one tab/run/terminal/chat surface)
//
// Mirrors ghostty_surface_t in role: the long-lived per-tab object the UI binds
// to. The Swift SurfaceView and GTK widget both wrap one of these.

typedef enum {
  SMITHERS_SESSION_KIND_TERMINAL = 0,
  SMITHERS_SESSION_KIND_CHAT,
  SMITHERS_SESSION_KIND_RUN_INSPECT,
  SMITHERS_SESSION_KIND_WORKFLOW,
  SMITHERS_SESSION_KIND_MEMORY,
  SMITHERS_SESSION_KIND_DASHBOARD,
} smithers_session_kind_e;

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

#ifdef __cplusplus
}
#endif
#endif // SMITHERS_H
