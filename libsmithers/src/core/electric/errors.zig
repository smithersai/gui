//! Errors the Electric shape client can raise. Promoted verbatim from
//! poc/zig-electric-client/src/errors.zig — callers (RealTransport,
//! integration tests) switch on these to decide retry / token refresh /
//! surface-to-user behaviour.

pub const Error = error{
    // --- HTTP layer ---
    BadStatus,
    Unauthorized,
    Forbidden,
    HttpMalformed,
    ShortRead,

    // --- Shape protocol layer ---
    JsonMalformed,
    MissingElectricHeader,
    UnknownOperation,
    OffsetRegression,

    // --- State layer ---
    AlreadyClosed,

    // --- Misc ---
    OutOfMemory,
    IoError,
    InvalidUrl,
};
