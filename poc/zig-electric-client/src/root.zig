//! zig-electric-client — minimal Zig library for subscribing to plue's
//! ElectricSQL shape proxy. See README for scope and the auth contract
//! (repository_id IN (...) filtering enforced by plue/internal/electric).

pub const errors = @import("errors.zig");
pub const http = @import("http.zig");
pub const message = @import("message.zig");
pub const persistence = @import("persistence.zig");
pub const client = @import("client.zig");

pub const Error = errors.Error;
pub const Persistence = persistence.Persistence;
pub const Client = client.Client;
pub const Config = client.Config;

test {
    _ = errors;
    _ = http;
    _ = message;
    _ = persistence;
    _ = client;
}
