//! Electric shape client promoted into libsmithers-core.
//!
//! Promoted from poc/zig-electric-client/ per ticket 0140. The PoC is
//! kept intact at `poc/zig-electric-client/` as reference + harness;
//! production clients use this namespace which is integrated with:
//!   * `cache.zig` for cursor persistence (via the `CursorStore` vtable)
//!   * `transport.zig` / `session.zig` for delta emission (via `Sink`)
//!
//! See `client.zig` for the adapted protocol driver, `http.zig` for the
//! hand-rolled HTTP/1.1 impl, `message.zig` for the JSON parsing.

pub const errors = @import("errors.zig");
pub const http = @import("http.zig");
pub const message = @import("message.zig");
pub const client = @import("client.zig");

pub const Error = errors.Error;
pub const Client = client.Client;
pub const Config = client.Config;
pub const CursorStore = client.CursorStore;
pub const Sink = client.Sink;

test {
    _ = errors;
    _ = http;
    _ = message;
    _ = client;
}
