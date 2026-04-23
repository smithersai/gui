//! Per-connection cache schema.
//!
//! This is the bounded cache model called for by the spec. The tables
//! mirror the production shapes (0114-0118) — rows land here after an
//! Electric shape delta applies. The cache is NEVER the source of truth
//! for remote state; it is a read-side projection.
//!
//! This landing implements ONLY the `agent_sessions` table per the 0120
//! scope caveat. Additional tables are skeletons (DDL present but no
//! adapter code yet), to document the cut line the spec wants.

const std = @import("std");

/// SQL executed at cache open. Keep it idempotent (`IF NOT EXISTS`).
///
/// Shape tables mirror plue column names. `row_json` is the denormalised
/// value Electric gave us — we decode on demand rather than shredding.
/// `pk` is the shape's primary key (string id). `subscription_id` ties a
/// row to the subscription that wrote it, for pinning + eviction.
pub const ddl =
    \\CREATE TABLE IF NOT EXISTS core_subscriptions (
    \\  id INTEGER PRIMARY KEY,
    \\  shape_name TEXT NOT NULL,
    \\  params_json TEXT NOT NULL,
    \\  pinned INTEGER NOT NULL DEFAULT 0,
    \\  electric_handle TEXT,
    \\  electric_offset TEXT,
    \\  created_unix_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS agent_sessions (
    \\  pk TEXT PRIMARY KEY,
    \\  subscription_id INTEGER NOT NULL,
    \\  row_json TEXT NOT NULL,
    \\  applied_unix_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_agent_sessions_sub
    \\  ON agent_sessions(subscription_id);
    \\
    \\-- TODO(0120-followup): mirror additional shapes from 0115-0118.
    \\CREATE TABLE IF NOT EXISTS agent_messages (
    \\  pk TEXT PRIMARY KEY,
    \\  subscription_id INTEGER NOT NULL,
    \\  row_json TEXT NOT NULL,
    \\  applied_unix_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS agent_parts (
    \\  pk TEXT PRIMARY KEY,
    \\  subscription_id INTEGER NOT NULL,
    \\  row_json TEXT NOT NULL,
    \\  applied_unix_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS workspaces (
    \\  pk TEXT PRIMARY KEY,
    \\  subscription_id INTEGER NOT NULL,
    \\  row_json TEXT NOT NULL,
    \\  applied_unix_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS workspace_sessions (
    \\  pk TEXT PRIMARY KEY,
    \\  subscription_id INTEGER NOT NULL,
    \\  row_json TEXT NOT NULL,
    \\  applied_unix_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS approvals (
    \\  pk TEXT PRIMARY KEY,
    \\  subscription_id INTEGER NOT NULL,
    \\  row_json TEXT NOT NULL,
    \\  applied_unix_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS workflow_runs (
    \\  pk TEXT PRIMARY KEY,
    \\  subscription_id INTEGER NOT NULL,
    \\  row_json TEXT NOT NULL,
    \\  applied_unix_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS devtools_snapshots (
    \\  pk TEXT PRIMARY KEY,
    \\  subscription_id INTEGER NOT NULL,
    \\  row_json TEXT NOT NULL,
    \\  applied_unix_ms INTEGER NOT NULL
    \\);
;

/// Known shape names. Adapters route incoming deltas to the correct table
/// via this enum. Only `agent_sessions` is production-wired in this
/// landing; the rest are skeleton rows per the scope caveat.
pub const Shape = enum {
    agent_sessions,
    agent_messages,
    agent_parts,
    workspaces,
    workspace_sessions,
    approvals,
    workflow_runs,
    devtools_snapshots,

    pub fn parse(name: []const u8) ?Shape {
        const map = std.StaticStringMap(Shape).initComptime(.{
            .{ "agent_sessions", .agent_sessions },
            .{ "agent_messages", .agent_messages },
            .{ "agent_parts", .agent_parts },
            .{ "workspaces", .workspaces },
            .{ "workspace_sessions", .workspace_sessions },
            .{ "approvals", .approvals },
            .{ "workflow_runs", .workflow_runs },
            .{ "devtools_snapshots", .devtools_snapshots },
        });
        return map.get(name);
    }

    pub fn tableName(self: Shape) []const u8 {
        return switch (self) {
            .agent_sessions => "agent_sessions",
            .agent_messages => "agent_messages",
            .agent_parts => "agent_parts",
            .workspaces => "workspaces",
            .workspace_sessions => "workspace_sessions",
            .approvals => "approvals",
            .workflow_runs => "workflow_runs",
            .devtools_snapshots => "devtools_snapshots",
        };
    }

    /// Whether this shape has a live adapter that applies incoming deltas
    /// to its backing table. Shapes without an adapter still get
    /// subscription rows but row inserts are no-ops pending 0120-followup.
    pub fn hasLiveAdapter(self: Shape) bool {
        return self == .agent_sessions;
    }
};

const testing = std.testing;

test "Shape.parse: known names" {
    try testing.expectEqual(Shape.agent_sessions, Shape.parse("agent_sessions").?);
    try testing.expectEqual(Shape.approvals, Shape.parse("approvals").?);
}

test "Shape.parse: unknown returns null" {
    try testing.expect(Shape.parse("does_not_exist") == null);
}

test "Shape.hasLiveAdapter: only agent_sessions in this landing" {
    try testing.expect(Shape.agent_sessions.hasLiveAdapter());
    try testing.expect(!Shape.agent_messages.hasLiveAdapter());
}
