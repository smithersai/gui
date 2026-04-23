//! WebSocket PTY client promoted into libsmithers-core.
//!
//! Promoted from poc/zig-ws-pty/ per ticket 0140. The PoC stays intact
//! as a reference harness; production callers use this namespace.
//!
//! Protocol logic (frame encoding, masking, handshake validation,
//! fragment reassembly, auto-pong) is unchanged from 0094. The only
//! integration work is in `transport.zig` which spawns a reader thread
//! per attached PTY and forwards binary frames as `pty_data` deltas.

pub const errors = @import("errors.zig");
pub const frame = @import("frame.zig");
pub const handshake = @import("handshake.zig");
pub const client = @import("client.zig");

pub const Error = errors.Error;
pub const Client = client.Client;
pub const ConnectOptions = client.ConnectOptions;
pub const EventKind = client.EventKind;

test {
    _ = errors;
    _ = frame;
    _ = handshake;
    _ = client;
}
