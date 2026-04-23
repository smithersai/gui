//! Errors the Electric shape client can return. libsmithers-core (and the
//! PoC tests) switch on these to decide retry / surface-to-user / fatal-crash
//! behaviour.

pub const Error = error{
    // --- HTTP layer ---
    /// Server replied with a non-2xx HTTP status. Inspect `last_status`.
    BadStatus,
    /// Specifically: 401 Unauthorized (bad / missing bearer token).
    Unauthorized,
    /// Specifically: 403 Forbidden (plue auth proxy rejected `where`).
    Forbidden,
    /// Response headers / status line malformed.
    HttpMalformed,
    /// Server closed the socket before a complete response arrived.
    ShortRead,

    // --- Shape protocol layer ---
    /// JSON body failed to parse.
    JsonMalformed,
    /// Required Electric response header missing (`electric-handle` on the
    /// first response, or `electric-offset` on any response).
    MissingElectricHeader,
    /// Server sent a message with an operation we cannot dispatch
    /// (unrecognised `operation` or `control` value).
    UnknownOperation,
    /// Observed offset went backwards relative to our stored offset — the
    /// server violated the protocol's monotonic-offset guarantee.
    OffsetRegression,

    // --- State layer ---
    /// Caller tried to operate on a client that was already unsubscribed.
    AlreadyClosed,

    // --- Misc ---
    OutOfMemory,
    IoError,
    InvalidUrl,
};
