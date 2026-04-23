//! ws_pty — a Zig client-only WebSocket library specialised for plue's
//! workspace terminal endpoint. See README.md for the exact wire protocol.
//!
//! Public API surface is intentionally small:
//!   - `frame`       — RFC-6455 frame encode/decode (pure, no I/O).
//!   - `handshake`   — HTTP/1.1 upgrade request + response parsing.
//!   - `Client`      — high-level: connect, read event, write bytes, resize, close.
//!   - `Error`       — distinct error set so callers can react to each failure mode.

pub const frame = @import("frame.zig");
pub const handshake = @import("handshake.zig");
pub const client = @import("client.zig");

pub const Client = client.Client;
pub const Event = client.Event;
pub const ResizeMsg = client.ResizeMsg;
pub const ConnectOptions = client.ConnectOptions;
pub const Error = @import("errors.zig").Error;

test {
    // Pull in submodule tests when running `zig build test` at the lib level.
    _ = frame;
    _ = handshake;
    _ = client;
}
