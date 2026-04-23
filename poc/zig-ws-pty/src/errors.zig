//! All errors the library can return. Callers (e.g. libsmithers-core) switch on
//! these to decide retry / surface-to-user / fatal-crash behaviour.

pub const Error = error{
    // --- Handshake layer ---
    /// Server replied with a non-101 HTTP status. See `Client.last_status`.
    HandshakeBadStatus,
    /// Specifically: server replied 403 Forbidden. Plue returns this for a bad
    /// Origin. Caller can distinguish from other 4xx via this variant.
    HandshakeOriginRejected,
    /// Specifically: server replied 401 Unauthorized (bad / missing bearer token).
    HandshakeUnauthorized,
    /// Server did not include the required upgrade headers.
    HandshakeMissingUpgrade,
    /// Sec-WebSocket-Accept did not match the expected SHA1(key + magic).
    HandshakeBadAcceptKey,
    /// HTTP response could not be parsed (malformed status line / headers).
    HandshakeMalformed,
    /// Client-side: URL could not be parsed.
    InvalidUrl,

    // --- Frame layer ---
    /// Frame decoded that violates RFC 6455 (reserved bits set, bad opcode,
    /// control-frame > 125 bytes, masked server frame, etc.)
    ProtocolError,
    /// Payload length exceeded the configured read limit.
    MessageTooLarge,
    /// Decoder needs more bytes; caller should read from transport and retry.
    /// Not actually returned to callers of `Client.readEvent` — they see it as
    /// a retriable read; included here for completeness of the frame layer.
    ShortRead,

    // --- Connection layer ---
    /// Underlying TCP read returned 0 / EOF mid-message without a close frame.
    /// Distinct from graceful close.
    AbruptDisconnect,
    /// Peer sent a Close frame. Inspect `Client.close_code` for details.
    PeerClosed,

    // --- Misc ---
    OutOfMemory,
    IoError,
};
