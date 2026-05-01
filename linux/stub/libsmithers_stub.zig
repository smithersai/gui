const std = @import("std");

const c = @cImport({
    @cInclude("smithers.h");
});

const alloc = std.heap.c_allocator;

const StubApp = struct {
    cfg: c.smithers_runtime_config_s,
    active_path: ?[]u8 = null,
    approval_pending: bool = true,
};

const StubWorkspace = struct {
    path: []u8,
};

const StubClient = struct {
    app: *StubApp,
};

const StubPalette = struct {
    app: *StubApp,
    mode: c.smithers_palette_mode_e = c.SMITHERS_PALETTE_MODE_ALL,
    query: ?[]u8 = null,
};

const StubSession = struct {
    app: *StubApp,
    kind: c.smithers_session_kind_e,
    title: []u8,
    userdata: c.smithers_userdata_t,
};

const StubStream = struct {
    sent: bool = false,
    payload: ?[]const u8 = null,
};

fn emptyString() c.smithers_string_s {
    return .{ .ptr = null, .len = 0 };
}

fn makeString(text: []const u8) c.smithers_string_s {
    const buf = alloc.allocSentinel(u8, text.len, 0) catch return emptyString();
    @memcpy(buf[0..text.len], text);
    return .{ .ptr = buf.ptr, .len = text.len };
}

fn freeString(s: c.smithers_string_s) void {
    if (s.ptr == null) return;
    const ptr: [*]u8 = @ptrCast(@constCast(s.ptr));
    alloc.free(ptr[0 .. s.len + 1]);
}

fn okError() c.smithers_error_s {
    return .{ .code = 0, .msg = null };
}

fn setOk(out_err: [*c]c.smithers_error_s) void {
    if (out_err != null) out_err.* = okError();
}

fn spanZ(ptr: [*c]const u8) []const u8 {
    if (ptr == null) return "";
    return std.mem.span(ptr);
}

fn appFrom(handle: c.smithers_app_t) ?*StubApp {
    return @ptrCast(@alignCast(handle orelse return null));
}

fn clientFrom(handle: c.smithers_client_t) ?*StubClient {
    return @ptrCast(@alignCast(handle orelse return null));
}

fn paletteFrom(handle: c.smithers_palette_t) ?*StubPalette {
    return @ptrCast(@alignCast(handle orelse return null));
}

fn sessionFrom(handle: c.smithers_session_t) ?*StubSession {
    return @ptrCast(@alignCast(handle orelse return null));
}

fn streamFrom(handle: c.smithers_event_stream_t) ?*StubStream {
    return @ptrCast(@alignCast(handle orelse return null));
}

export fn smithers_string_free(s: c.smithers_string_s) callconv(.c) void {
    freeString(s);
}

export fn smithers_error_free(e: c.smithers_error_s) callconv(.c) void {
    if (e.msg == null) return;
    const text = std.mem.span(e.msg);
    const ptr: [*]u8 = @ptrCast(@constCast(e.msg));
    alloc.free(ptr[0 .. text.len + 1]);
}

export fn smithers_bytes_free(b: c.smithers_bytes_s) callconv(.c) void {
    if (b.ptr == null) return;
    const ptr: [*]u8 = @ptrCast(@constCast(b.ptr));
    alloc.free(ptr[0..b.len]);
}

export fn smithers_init(_: c_int, _: [*c][*c]u8) callconv(.c) i32 {
    return c.SMITHERS_SUCCESS;
}

export fn smithers_info() callconv(.c) c.smithers_info_s {
    return .{
        .version = "0.1.0-stub",
        .commit = "stub",
        .platform = c.SMITHERS_PLATFORM_LINUX,
    };
}

export fn smithers_app_new(cfg: [*c]const c.smithers_runtime_config_s) callconv(.c) c.smithers_app_t {
    const app = alloc.create(StubApp) catch return null;
    app.* = .{ .cfg = if (cfg != null) cfg.* else std.mem.zeroes(c.smithers_runtime_config_s) };
    return app;
}

export fn smithers_app_free(handle: c.smithers_app_t) callconv(.c) void {
    const app = appFrom(handle) orelse return;
    if (app.active_path) |path| alloc.free(path);
    alloc.destroy(app);
}

export fn smithers_app_tick(_: c.smithers_app_t) callconv(.c) void {}

export fn smithers_app_userdata(handle: c.smithers_app_t) callconv(.c) c.smithers_userdata_t {
    const app = appFrom(handle) orelse return null;
    return app.cfg.userdata;
}

export fn smithers_app_set_color_scheme(_: c.smithers_app_t, _: c.smithers_color_scheme_e) callconv(.c) void {}

export fn smithers_app_open_workspace(handle: c.smithers_app_t, path: [*c]const u8) callconv(.c) c.smithers_workspace_t {
    const app = appFrom(handle) orelse return null;
    const path_slice = spanZ(path);
    if (app.active_path) |old| alloc.free(old);
    app.active_path = alloc.dupe(u8, path_slice) catch null;

    const ws = alloc.create(StubWorkspace) catch return null;
    ws.* = .{ .path = alloc.dupe(u8, path_slice) catch {
        alloc.destroy(ws);
        return null;
    } };
    return ws;
}

export fn smithers_app_close_workspace(app_handle: c.smithers_app_t, handle: c.smithers_workspace_t) callconv(.c) void {
    const app = appFrom(app_handle);
    const ws: *StubWorkspace = @ptrCast(@alignCast(handle orelse return));
    if (app) |a| {
        if (a.active_path) |path| {
            if (std.mem.eql(u8, path, ws.path)) {
                alloc.free(path);
                a.active_path = null;
            }
        }
    }
    alloc.free(ws.path);
    alloc.destroy(ws);
}

export fn smithers_app_active_workspace_path(handle: c.smithers_app_t) callconv(.c) c.smithers_string_s {
    const app = appFrom(handle) orelse return makeString("");
    if (app.active_path) |path| return makeString(path);
    const cwd = std.process.getCwdAlloc(alloc) catch return makeString("");
    defer alloc.free(cwd);
    return makeString(cwd);
}

export fn smithers_app_remove_recent_workspace(_: c.smithers_app_t, _: [*c]const u8) callconv(.c) void {}

export fn smithers_app_recent_workspaces_json(_: c.smithers_app_t) callconv(.c) c.smithers_string_s {
    return makeString(
        \\[
        \\ {"id":"smithers-gui","name":"Smithers GUI","status":"active","createdAt":"today"},
        \\ {"id":"demo","name":"Demo Workspace","status":"suspended","createdAt":"recent"}
        \\]
    );
}

export fn smithers_session_new(handle: c.smithers_app_t, opts: c.smithers_session_options_s) callconv(.c) c.smithers_session_t {
    const app = appFrom(handle) orelse return null;
    const title = switch (opts.kind) {
        c.SMITHERS_SESSION_KIND_TERMINAL => "Terminal",
        c.SMITHERS_SESSION_KIND_CHAT => "Chat",
        c.SMITHERS_SESSION_KIND_RUN_INSPECT => "Run Inspector",
        c.SMITHERS_SESSION_KIND_WORKFLOW => "Workflow",
        c.SMITHERS_SESSION_KIND_MEMORY => "Memory",
        c.SMITHERS_SESSION_KIND_DASHBOARD => "Dashboard",
        else => "Session",
    };
    const session = alloc.create(StubSession) catch return null;
    const title_copy = alloc.dupe(u8, title) catch {
        alloc.destroy(session);
        return null;
    };
    session.* = .{
        .app = app,
        .kind = opts.kind,
        .title = title_copy,
        .userdata = opts.userdata,
    };
    return session;
}

export fn smithers_session_free(handle: c.smithers_session_t) callconv(.c) void {
    const session = sessionFrom(handle) orelse return;
    alloc.free(session.title);
    alloc.destroy(session);
}

export fn smithers_session_kind(handle: c.smithers_session_t) callconv(.c) c.smithers_session_kind_e {
    const session = sessionFrom(handle) orelse return c.SMITHERS_SESSION_KIND_DASHBOARD;
    return session.kind;
}

export fn smithers_session_userdata(handle: c.smithers_session_t) callconv(.c) c.smithers_userdata_t {
    const session = sessionFrom(handle) orelse return null;
    return session.userdata;
}

export fn smithers_session_title(handle: c.smithers_session_t) callconv(.c) c.smithers_string_s {
    const session = sessionFrom(handle) orelse return makeString("Session");
    return makeString(session.title);
}

export fn smithers_session_send_text(handle: c.smithers_session_t, text: [*c]const u8, len: usize) callconv(.c) void {
    _ = len;
    const session = sessionFrom(handle) orelse return;
    if (session.app.cfg.wakeup) |wakeup| wakeup(session.app.cfg.userdata);
    _ = text;
}

export fn smithers_session_events(handle: c.smithers_session_t) callconv(.c) c.smithers_event_stream_t {
    const session = sessionFrom(handle) orelse return null;
    const stream = alloc.create(StubStream) catch return null;
    stream.* = .{
        .payload = if (session.kind == c.SMITHERS_SESSION_KIND_CHAT)
            "{\"markdown\":\"## Stub assistant\\nlibsmithers is not built yet, so this chat block comes from linux/stub/libsmithers_stub.zig.\"}"
        else
            null,
    };
    return stream;
}

export fn smithers_event_stream_next(handle: c.smithers_event_stream_t) callconv(.c) c.smithers_event_s {
    const stream = streamFrom(handle) orelse return .{ .tag = c.SMITHERS_EVENT_NONE, .payload = emptyString() };
    if (stream.sent or stream.payload == null) {
        return .{ .tag = c.SMITHERS_EVENT_NONE, .payload = emptyString() };
    }
    stream.sent = true;
    return .{ .tag = c.SMITHERS_EVENT_JSON, .payload = makeString(stream.payload.?) };
}

export fn smithers_event_free(ev: c.smithers_event_s) callconv(.c) void {
    freeString(ev.payload);
}

export fn smithers_event_stream_free(handle: c.smithers_event_stream_t) callconv(.c) void {
    const stream = streamFrom(handle) orelse return;
    alloc.destroy(stream);
}

export fn smithers_client_new(handle: c.smithers_app_t) callconv(.c) c.smithers_client_t {
    const app = appFrom(handle) orelse return null;
    const client = alloc.create(StubClient) catch return null;
    client.* = .{ .app = app };
    return client;
}

export fn smithers_client_free(handle: c.smithers_client_t) callconv(.c) void {
    const client = clientFrom(handle) orelse return;
    alloc.destroy(client);
}

export fn smithers_client_call(
    handle: c.smithers_client_t,
    method: [*c]const u8,
    _: [*c]const u8,
    out_err: [*c]c.smithers_error_s,
) callconv(.c) c.smithers_string_s {
    const client = clientFrom(handle) orelse return makeString("null");
    setOk(out_err);
    const name = spanZ(method);
    if (std.mem.eql(u8, name, "listWorkflows")) return makeString(workflows_json);
    if (std.mem.eql(u8, name, "listRuns")) return makeString(runs_json);
    if (std.mem.eql(u8, name, "inspectRun")) return makeString(inspect_json);
    if (std.mem.eql(u8, name, "listPendingApprovals")) return makeString(if (client.app.approval_pending) approvals_json else "[]");
    if (std.mem.eql(u8, name, "listAgents")) return makeString(agents_json);
    if (std.mem.eql(u8, name, "listWorkspaces")) return makeString(workspaces_json);
    if (std.mem.eql(u8, name, "runWorkflow")) return makeString("{\"runId\":\"stub-run-003\",\"status\":\"running\"}");
    if (std.mem.eql(u8, name, "approveNode") or std.mem.eql(u8, name, "denyNode")) {
        client.app.approval_pending = false;
        if (client.app.cfg.state_changed) |state_changed| state_changed(client.app.cfg.userdata);
        return makeString("{}");
    }
    return makeString("[]");
}

export fn smithers_client_stream(
    _: c.smithers_client_t,
    _: [*c]const u8,
    _: [*c]const u8,
    out_err: [*c]c.smithers_error_s,
) callconv(.c) c.smithers_event_stream_t {
    setOk(out_err);
    const stream = alloc.create(StubStream) catch return null;
    stream.* = .{};
    return stream;
}

export fn smithers_palette_new(handle: c.smithers_app_t) callconv(.c) c.smithers_palette_t {
    const app = appFrom(handle) orelse return null;
    const palette = alloc.create(StubPalette) catch return null;
    palette.* = .{ .app = app };
    return palette;
}

export fn smithers_palette_free(handle: c.smithers_palette_t) callconv(.c) void {
    const palette = paletteFrom(handle) orelse return;
    if (palette.query) |query| alloc.free(query);
    alloc.destroy(palette);
}

export fn smithers_palette_set_mode(handle: c.smithers_palette_t, mode: c.smithers_palette_mode_e) callconv(.c) void {
    const palette = paletteFrom(handle) orelse return;
    palette.mode = mode;
}

export fn smithers_palette_set_query(handle: c.smithers_palette_t, query: [*c]const u8) callconv(.c) void {
    const palette = paletteFrom(handle) orelse return;
    if (palette.query) |old| alloc.free(old);
    palette.query = alloc.dupe(u8, spanZ(query)) catch null;
}

export fn smithers_palette_items_json(_: c.smithers_palette_t) callconv(.c) c.smithers_string_s {
    return makeString(palette_json);
}

export fn smithers_palette_activate(_: c.smithers_palette_t, _: [*c]const u8) callconv(.c) c.smithers_error_s {
    return okError();
}

export fn smithers_slashcmd_parse(input: [*c]const u8) callconv(.c) c.smithers_string_s {
    const raw = spanZ(input);
    if (std.mem.startsWith(u8, raw, "/")) {
        return makeString("{\"command\":\"stub\",\"args\":[],\"mode\":\"command\"}");
    }
    return makeString("{\"command\":\"chat\",\"args\":[],\"mode\":\"text\"}");
}

export fn smithers_cwd_resolve(requested: [*c]const u8) callconv(.c) c.smithers_string_s {
    const req = spanZ(requested);
    if (req.len > 0) return makeString(req);
    const cwd = std.process.getCwdAlloc(alloc) catch return makeString(".");
    defer alloc.free(cwd);
    return makeString(cwd);
}

export fn smithers_persistence_open(_: [*c]const u8, out_err: [*c]c.smithers_error_s) callconv(.c) c.smithers_persistence_t {
    setOk(out_err);
    return @ptrFromInt(1);
}

export fn smithers_persistence_close(_: c.smithers_persistence_t) callconv(.c) void {}

export fn smithers_persistence_load_sessions(_: c.smithers_persistence_t, _: [*c]const u8) callconv(.c) c.smithers_string_s {
    return makeString("[]");
}

export fn smithers_persistence_save_sessions(_: c.smithers_persistence_t, _: [*c]const u8, _: [*c]const u8) callconv(.c) c.smithers_error_s {
    return okError();
}

const workflows_json =
    \\[
    \\ {"id":"wf-build","name":"Build Linux GTK MVP","relativePath":".smithers/workflows/linux-gtk.tsx","status":"active","updatedAt":"2026-04-21"},
    \\ {"id":"wf-smoke","name":"Smoke Test","relativePath":".smithers/workflows/smoke.tsx","status":"hot","updatedAt":"2026-04-21"},
    \\ {"id":"wf-release","name":"Release Notes","relativePath":".smithers/workflows/release.tsx","status":"draft","updatedAt":"2026-04-20"}
    \\]
;

const runs_json =
    \\[
    \\ {"runId":"stub-run-001","workflowName":"Build Linux GTK MVP","workflowPath":".smithers/workflows/linux-gtk.tsx","status":"running","startedAtMs":1776783600000,"summary":{"total":6,"finished":3,"failed":0}},
    \\ {"runId":"stub-run-002","workflowName":"Smoke Test","workflowPath":".smithers/workflows/smoke.tsx","status":"waiting-approval","startedAtMs":1776780000000,"summary":{"total":4,"finished":2,"failed":0}}
    \\]
;

const inspect_json =
    \\{
    \\ "run":{"runId":"stub-run-001","workflowName":"Build Linux GTK MVP","workflowPath":".smithers/workflows/linux-gtk.tsx","status":"running","startedAtMs":1776783600000,"summary":{"total":6,"finished":3,"failed":0}},
    \\ "tasks":[
    \\   {"nodeId":"read-contract","label":"Read contract","state":"finished"},
    \\   {"nodeId":"build-shell","label":"Build GTK shell","state":"running"},
    \\   {"nodeId":"verify","label":"Verify smoke tests","state":"blocked"}
    \\ ]
    \\}
;

const approvals_json =
    \\[
    \\ {"id":"approval-1","runId":"stub-run-002","nodeId":"deploy","gate":"Deploy preview","status":"pending","requestedAt":1776780000000,"source":"stub"}
    \\]
;

const agents_json =
    \\[
    \\ {"id":"codex","name":"Codex","command":"codex","binaryPath":"/usr/bin/codex","status":"binary-only","hasAuth":false,"hasAPIKey":false,"usable":true,"roles":["coding"],"version":"stub"},
    \\ {"id":"claude","name":"Claude Code","command":"claude","binaryPath":"/usr/bin/claude","status":"likely-subscription","hasAuth":true,"hasAPIKey":false,"usable":true,"roles":["coding"],"version":"stub"}
    \\]
;

const workspaces_json =
    \\[
    \\ {"id":"smithers-gui","name":"Smithers GUI","status":"active","createdAt":"2026-04-21"},
    \\ {"id":"jjhub-demo","name":"JJHub Demo","status":"suspended","createdAt":"2026-04-20"}
    \\]
;

const palette_json =
    \\[
    \\ {"id":"nav:dashboard","title":"Dashboard","subtitle":"Open dashboard","kind":"command","score":1.0},
    \\ {"id":"nav:workflows","title":"Workflows","subtitle":"List and launch workflows","kind":"command","score":0.98},
    \\ {"id":"nav:runs","title":"Runs","subtitle":"Inspect recent runs","kind":"command","score":0.96},
    \\ {"id":"nav:approvals","title":"Approvals","subtitle":"Review pending approval gates","kind":"command","score":0.94},
    \\ {"id":"new:terminal","title":"New Terminal","subtitle":"Open terminal session","kind":"session","score":0.92},
    \\ {"id":"new:chat","title":"New Chat","subtitle":"Open chat session","kind":"session","score":0.90},
    \\ {"id":"workflow:wf-build","title":"Build Linux GTK MVP","subtitle":".smithers/workflows/linux-gtk.tsx","kind":"workflow","score":0.88}
    \\]
;
