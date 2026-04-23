//! libsmithers-core — connection-scoped production runtime (ticket 0120).
//!
//! This module is the NEW center of gravity for libsmithers, replacing the
//! `App.zig`-centered architecture documented in the ticket. It is shaped
//! around the spec's rule: one `Core` per process, one `Session` per engine
//! connection, and a `Session` owns Electric subscriptions, WebSocket PTY,
//! HTTP writes, and a bounded SQLite cache.
//!
//! Scope for this landing (per 0120 "critical scope caveat"):
//!   - Core + Session lifecycle with credentials callback.
//!   - ONE shape end-to-end: `agent_sessions` — subscribe, receive deltas
//!     through a pluggable transport, persist into the cache, expose via
//!     `cache_query`.
//!   - HTTP write: skeleton (enqueues a future, fires WRITE_ACK).
//!   - PTY attach/resize/write/detach: skeleton (records calls; no
//!     real WebSocket here — the transport hook is in place for 0120-followup).
//!   - Cache wipe on sign-out.
//!
//! Out of scope for this landing (follow-up tickets):
//!   - All other shapes (agent_messages, agent_parts, workspaces,
//!     workspace_sessions, approvals, workflow_runs, devtools_snapshots)
//!   - Real WebSocket PTY wiring to 0094's client
//!   - SSE fallback, reconnect policy
//!   - LRU eviction policy for cache_max_mb
//! Each of the above is marked with `TODO(0120-followup): ...`.

const std = @import("std");
pub const cache = @import("cache.zig");
pub const transport = @import("transport.zig");
pub const session = @import("session.zig");
pub const ffi = @import("ffi.zig");
pub const schema = @import("schema.zig");
/// Electric shape protocol client (promoted from poc/zig-electric-client
/// per ticket 0140). Exposed for tests + tools that want to drive the
/// HTTP layer directly; RealTransport is the only production consumer.
pub const electric = @import("electric/mod.zig");
/// WebSocket PTY client (promoted from poc/zig-ws-pty per ticket 0140).
pub const wspty = @import("wspty/mod.zig");

pub const Cache = cache.Cache;
pub const Transport = transport.Transport;
pub const TransportVTable = transport.VTable;
pub const Session = session.Session;
pub const EngineConfig = session.EngineConfig;
pub const EventTag = session.EventTag;

pub const Credentials = struct {
    bearer: []const u8,
    expires_unix_ms: i64 = 0,
    refresh_token: ?[]const u8 = null,
};

/// Platform-provided callback: fill `out` with a borrowed bearer string
/// valid for the duration of the callback. Returning false triggers an
/// AUTH_EXPIRED event on sessions attempting to use credentials.
pub const CredentialsFn = *const fn (userdata: ?*anyopaque, out: *Credentials) callconv(.c) bool;

pub const Error = error{
    FeatureFlagDisabled,
    OutOfMemory,
    InvalidArgument,
    AlreadyClosed,
    AuthExpired,
    TransportError,
    CacheError,
    UnknownShape,
};

/// Feature flag for 0112. Until plue lands it as a real flag, we honour
/// the env var SMITHERS_REMOTE_SANDBOX_ENABLED=1. Default: enabled in
/// tests, disabled in release (override at create time).
fn remoteSandboxEnabled(allocator: std.mem.Allocator) bool {
    const override = std.process.getEnvVarOwned(allocator, "SMITHERS_REMOTE_SANDBOX_ENABLED") catch {
        return true; // default on; plue will flip this when 0112 lands.
    };
    defer allocator.free(override);
    return std.mem.eql(u8, override, "1") or std.mem.eql(u8, override, "true");
}

/// The process-lifetime runtime root. Owns no per-connection state;
/// sessions are spawned from it via `connect`.
pub const Core = struct {
    allocator: std.mem.Allocator,
    credentials_cb: CredentialsFn,
    credentials_userdata: ?*anyopaque,
    mutex: std.Thread.Mutex = .{},
    sessions: std.ArrayList(*Session) = .empty,
    /// Dependency-injection hook for tests: when non-null, new sessions use
    /// this vtable instead of the real transport. Production code leaves it
    /// null; tests set it to a fake.
    transport_override: ?*const TransportVTable = null,

    /// Test-only flag: when true, sessions construct a `FakeTransport`
    /// instead of the real Electric/WS/HTTP stack. This keeps the 0120
    /// lifecycle tests deterministic without requiring a live plue.
    ///
    /// When FALSE (default), sessions build a `RealTransport` per 0140.
    /// Integration tests gated on `POC_ELECTRIC_STACK=1` leave this off.
    testing_use_fake_transport: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        credentials_cb: CredentialsFn,
        credentials_userdata: ?*anyopaque,
    ) !*Core {
        if (!remoteSandboxEnabled(allocator)) return Error.FeatureFlagDisabled;
        const self = try allocator.create(Core);
        self.* = .{
            .allocator = allocator,
            .credentials_cb = credentials_cb,
            .credentials_userdata = credentials_userdata,
        };
        return self;
    }

    pub fn destroy(self: *Core) void {
        self.mutex.lock();
        // Take a local copy of the sessions list; each session's destroy
        // path removes itself from this list, so we can't iterate in place.
        const drained = self.sessions.toOwnedSlice(self.allocator) catch &[_]*Session{};
        self.mutex.unlock();
        for (drained) |s| s.destroy();
        self.allocator.free(drained);
        self.allocator.destroy(self);
    }

    /// Invoke the credentials callback. Returns Error.AuthExpired if the
    /// platform returned false.
    pub fn fetchCredentials(self: *Core) Error!Credentials {
        var out: Credentials = .{ .bearer = "" };
        const ok = self.credentials_cb(self.credentials_userdata, &out);
        if (!ok) return Error.AuthExpired;
        return out;
    }

    pub fn connect(self: *Core, cfg: EngineConfig) !*Session {
        const s = try Session.create(self, cfg);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.sessions.append(self.allocator, s);
        return s;
    }

    /// Called by Session.destroy to unregister itself from the core.
    pub fn removeSession(self: *Core, s: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.sessions.items.len) : (i += 1) {
            if (self.sessions.items[i] == s) {
                _ = self.sessions.swapRemove(i);
                return;
            }
        }
    }
};

test {
    _ = @import("cache.zig");
    _ = @import("transport.zig");
    _ = @import("session.zig");
    _ = @import("schema.zig");
    _ = @import("electric/mod.zig");
    _ = @import("wspty/mod.zig");
}

// -----------------------------------------------------------------------
// Tests — lifecycle with a fake credentials callback + no transport.
// -----------------------------------------------------------------------

const testing = std.testing;

fn testCredsOk(_: ?*anyopaque, out: *Credentials) callconv(.c) bool {
    out.* = .{ .bearer = "test-bearer" };
    return true;
}

fn testCredsExpired(_: ?*anyopaque, out: *Credentials) callconv(.c) bool {
    _ = out;
    return false;
}

test "Core: create and destroy with no sessions" {
    const core = try Core.create(testing.allocator, testCredsOk, null);
    core.destroy();
}

test "Core: fetchCredentials propagates AuthExpired" {
    const core = try Core.create(testing.allocator, testCredsExpired, null);
    defer core.destroy();
    try testing.expectError(Error.AuthExpired, core.fetchCredentials());
}

test "Core: fetchCredentials returns bearer" {
    const core = try Core.create(testing.allocator, testCredsOk, null);
    defer core.destroy();
    const c = try core.fetchCredentials();
    try testing.expectEqualStrings("test-bearer", c.bearer);
}
