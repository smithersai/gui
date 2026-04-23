//! Errors the WebSocket PTY client can raise. Promoted verbatim from
//! poc/zig-ws-pty/src/errors.zig. RealTransport switches on these to
//! dispatch pty_closed events + surface auth failures.

pub const Error = error{
    HandshakeBadStatus,
    HandshakeOriginRejected,
    HandshakeUnauthorized,
    HandshakeMissingUpgrade,
    HandshakeBadAcceptKey,
    HandshakeMalformed,
    InvalidUrl,

    ProtocolError,
    MessageTooLarge,
    ShortRead,

    AbruptDisconnect,
    PeerClosed,

    OutOfMemory,
    IoError,
};
