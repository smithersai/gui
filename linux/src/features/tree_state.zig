const std = @import("std");
const logx = @import("../log.zig");

const log = std.log.scoped(.smithers_gtk_tree_state);

const Value = std.json.Value;

pub const NodeType = enum {
    workflow,
    sequence,
    parallel,
    task,
    for_each,
    conditional,
    unknown,

    pub fn parse(raw: []const u8) NodeType {
        if (std.ascii.eqlIgnoreCase(raw, "workflow")) return .workflow;
        if (std.ascii.eqlIgnoreCase(raw, "sequence")) return .sequence;
        if (std.ascii.eqlIgnoreCase(raw, "parallel")) return .parallel;
        if (std.ascii.eqlIgnoreCase(raw, "task")) return .task;
        if (std.ascii.eqlIgnoreCase(raw, "forEach") or
            std.ascii.eqlIgnoreCase(raw, "for_each") or
            std.ascii.eqlIgnoreCase(raw, "foreach")) return .for_each;
        if (std.ascii.eqlIgnoreCase(raw, "conditional")) return .conditional;
        return .unknown;
    }

    pub fn label(self: NodeType) []const u8 {
        return switch (self) {
            .workflow => "Workflow",
            .sequence => "Sequence",
            .parallel => "Parallel",
            .task => "Task",
            .for_each => "ForEach",
            .conditional => "Conditional",
            .unknown => "Node",
        };
    }
};

pub const ExecutionState = enum {
    pending,
    running,
    finished,
    failed,
    blocked,
    waiting_approval,
    cancelled,
    unknown,

    pub fn parse(raw: ?[]const u8) ExecutionState {
        const value = raw orelse return .unknown;
        if (std.ascii.eqlIgnoreCase(value, "pending") or
            std.ascii.eqlIgnoreCase(value, "queued")) return .pending;
        if (std.ascii.eqlIgnoreCase(value, "running") or
            std.ascii.eqlIgnoreCase(value, "in-progress") or
            std.ascii.eqlIgnoreCase(value, "inprogress") or
            std.ascii.eqlIgnoreCase(value, "started")) return .running;
        if (std.ascii.eqlIgnoreCase(value, "finished") or
            std.ascii.eqlIgnoreCase(value, "complete") or
            std.ascii.eqlIgnoreCase(value, "completed") or
            std.ascii.eqlIgnoreCase(value, "success") or
            std.ascii.eqlIgnoreCase(value, "succeeded") or
            std.ascii.eqlIgnoreCase(value, "done")) return .finished;
        if (std.ascii.eqlIgnoreCase(value, "failed") or
            std.ascii.eqlIgnoreCase(value, "failure") or
            std.ascii.eqlIgnoreCase(value, "error") or
            std.ascii.eqlIgnoreCase(value, "errored")) return .failed;
        if (std.ascii.eqlIgnoreCase(value, "blocked") or
            std.ascii.eqlIgnoreCase(value, "paused")) return .blocked;
        if (std.ascii.eqlIgnoreCase(value, "waitingApproval") or
            std.ascii.eqlIgnoreCase(value, "waiting-approval") or
            std.ascii.eqlIgnoreCase(value, "waiting_approval")) return .waiting_approval;
        if (std.ascii.eqlIgnoreCase(value, "cancelled") or
            std.ascii.eqlIgnoreCase(value, "canceled")) return .cancelled;
        return .unknown;
    }

    pub fn label(self: ExecutionState) []const u8 {
        return switch (self) {
            .pending => "Pending",
            .running => "Running",
            .finished => "Finished",
            .failed => "Failed",
            .blocked => "Blocked",
            .waiting_approval => "Waiting Approval",
            .cancelled => "Cancelled",
            .unknown => "Unknown",
        };
    }

    pub fn isTerminal(self: ExecutionState) bool {
        return switch (self) {
            .finished, .failed, .cancelled => true,
            else => false,
        };
    }

    pub fn glyph(self: ExecutionState) []const u8 {
        return switch (self) {
            .pending => "o",
            .running => ">",
            .finished => "ok",
            .failed => "x",
            .blocked, .waiting_approval => "!",
            .cancelled => "-",
            .unknown => "?",
        };
    }

    pub fn cssClass(self: ExecutionState) [:0]const u8 {
        return switch (self) {
            .running => "accent",
            .finished => "success",
            .failed => "error",
            .blocked, .waiting_approval => "warning",
            .pending, .cancelled, .unknown => "dim-label",
        };
    }
};

pub const Prop = struct {
    key: []u8,
    rendered: []u8,
    string_value: ?[]u8 = null,

    pub fn deinit(self: *Prop, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.rendered);
        if (self.string_value) |value| alloc.free(value);
    }
};

pub const TaskInfo = struct {
    node_id: []u8,
    kind: []u8,
    agent: ?[]u8 = null,
    label: ?[]u8 = null,
    output_table_name: ?[]u8 = null,
    iteration: ?i64 = null,

    pub fn clone(self: TaskInfo, alloc: std.mem.Allocator) !TaskInfo {
        return .{
            .node_id = try alloc.dupe(u8, self.node_id),
            .kind = try alloc.dupe(u8, self.kind),
            .agent = if (self.agent) |v| try alloc.dupe(u8, v) else null,
            .label = if (self.label) |v| try alloc.dupe(u8, v) else null,
            .output_table_name = if (self.output_table_name) |v| try alloc.dupe(u8, v) else null,
            .iteration = self.iteration,
        };
    }

    pub fn deinit(self: *TaskInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.node_id);
        alloc.free(self.kind);
        if (self.agent) |v| alloc.free(v);
        if (self.label) |v| alloc.free(v);
        if (self.output_table_name) |v| alloc.free(v);
    }
};

pub const Node = struct {
    id: i64,
    node_type: NodeType,
    name: []u8,
    props: std.ArrayList(Prop) = .empty,
    task: ?TaskInfo = null,
    children: std.ArrayList(*Node) = .empty,
    depth: usize = 0,

    pub fn deinit(self: *Node, alloc: std.mem.Allocator) void {
        for (self.props.items) |*prop| prop.deinit(alloc);
        self.props.deinit(alloc);
        if (self.task) |*task| task.deinit(alloc);
        for (self.children.items) |child| {
            child.deinit(alloc);
            alloc.destroy(child);
        }
        self.children.deinit(alloc);
        alloc.free(self.name);
    }

    pub fn clone(self: *const Node, alloc: std.mem.Allocator) !*Node {
        const copied = try alloc.create(Node);
        errdefer alloc.destroy(copied);
        copied.* = .{
            .id = self.id,
            .node_type = self.node_type,
            .name = try alloc.dupe(u8, self.name),
            .task = if (self.task) |task| try task.clone(alloc) else null,
            .depth = self.depth,
        };
        errdefer copied.deinit(alloc);

        try copied.props.ensureUnusedCapacity(alloc, self.props.items.len);
        for (self.props.items) |prop| {
            copied.props.appendAssumeCapacity(.{
                .key = try alloc.dupe(u8, prop.key),
                .rendered = try alloc.dupe(u8, prop.rendered),
                .string_value = if (prop.string_value) |v| try alloc.dupe(u8, v) else null,
            });
        }

        try copied.children.ensureUnusedCapacity(alloc, self.children.items.len);
        for (self.children.items) |child| {
            copied.children.appendAssumeCapacity(try child.clone(alloc));
        }
        return copied;
    }

    pub fn find(self: *Node, id: i64) ?*Node {
        if (self.id == id) return self;
        for (self.children.items) |child| {
            if (child.find(id)) |found| return found;
        }
        return null;
    }

    pub fn findConst(self: *const Node, id: i64) ?*const Node {
        if (self.id == id) return self;
        for (self.children.items) |child| {
            if (child.findConst(id)) |found| return found;
        }
        return null;
    }

    pub fn findParentConst(self: *const Node, id: i64) ?*const Node {
        for (self.children.items) |child| {
            if (child.id == id) return self;
            if (child.findParentConst(id)) |found| return found;
        }
        return null;
    }

    pub fn removeChildRecursive(self: *Node, alloc: std.mem.Allocator, id: i64) bool {
        for (self.children.items, 0..) |child, index| {
            if (child.id == id) {
                const removed = self.children.orderedRemove(index);
                removed.deinit(alloc);
                alloc.destroy(removed);
                return true;
            }
            if (child.removeChildRecursive(alloc, id)) return true;
        }
        return false;
    }

    pub fn state(self: *const Node) ExecutionState {
        return ExecutionState.parse(self.stringProp("state"));
    }

    pub fn stringProp(self: *const Node, key: []const u8) ?[]const u8 {
        for (self.props.items) |prop| {
            if (std.mem.eql(u8, prop.key, key)) return prop.string_value orelse prop.rendered;
        }
        return null;
    }

    pub fn numberProp(self: *const Node, key: []const u8) ?f64 {
        const text = self.stringProp(key) orelse return null;
        return std.fmt.parseFloat(f64, text) catch null;
    }

    pub fn count(self: *const Node) usize {
        var total: usize = 1;
        for (self.children.items) |child| total += child.count();
        return total;
    }

    pub fn hasChildren(self: *const Node) bool {
        return self.children.items.len > 0;
    }
};

pub const Snapshot = struct {
    frame_no: i64,
    seq: i64,
    root: *Node,

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        self.root.deinit(alloc);
        alloc.destroy(self.root);
    }
};

pub const RunStatus = enum {
    running,
    waiting_approval,
    finished,
    failed,
    cancelled,
    stale,
    orphaned,
    unknown,

    pub fn parse(raw: ?[]const u8) RunStatus {
        const value = raw orelse return .unknown;
        if (std.ascii.eqlIgnoreCase(value, "waiting-approval") or
            std.ascii.eqlIgnoreCase(value, "waitingApproval") or
            std.ascii.eqlIgnoreCase(value, "blocked") or
            std.ascii.eqlIgnoreCase(value, "paused")) return .waiting_approval;
        if (std.ascii.eqlIgnoreCase(value, "finished") or
            std.ascii.eqlIgnoreCase(value, "complete") or
            std.ascii.eqlIgnoreCase(value, "completed") or
            std.ascii.eqlIgnoreCase(value, "success") or
            std.ascii.eqlIgnoreCase(value, "succeeded") or
            std.ascii.eqlIgnoreCase(value, "done")) return .finished;
        if (std.ascii.eqlIgnoreCase(value, "failed") or
            std.ascii.eqlIgnoreCase(value, "failure") or
            std.ascii.eqlIgnoreCase(value, "error") or
            std.ascii.eqlIgnoreCase(value, "errored")) return .failed;
        if (std.ascii.eqlIgnoreCase(value, "cancelled") or
            std.ascii.eqlIgnoreCase(value, "canceled")) return .cancelled;
        if (std.ascii.eqlIgnoreCase(value, "running") or
            std.ascii.eqlIgnoreCase(value, "in-progress") or
            std.ascii.eqlIgnoreCase(value, "inprogress") or
            std.ascii.eqlIgnoreCase(value, "started") or
            std.ascii.eqlIgnoreCase(value, "recovering")) return .running;
        if (std.ascii.eqlIgnoreCase(value, "stale")) return .stale;
        if (std.ascii.eqlIgnoreCase(value, "orphaned")) return .orphaned;
        return .unknown;
    }

    pub fn fromExecution(state: ExecutionState) RunStatus {
        return switch (state) {
            .running, .pending => .running,
            .waiting_approval, .blocked => .waiting_approval,
            .finished => .finished,
            .failed => .failed,
            .cancelled => .cancelled,
            .unknown => .unknown,
        };
    }

    pub fn label(self: RunStatus) []const u8 {
        return switch (self) {
            .running => "RUNNING",
            .waiting_approval => "APPROVAL",
            .finished => "FINISHED",
            .failed => "FAILED",
            .cancelled => "CANCELLED",
            .stale => "STALE",
            .orphaned => "ORPHANED",
            .unknown => "UNKNOWN",
        };
    }

    pub fn isTerminal(self: RunStatus) bool {
        return switch (self) {
            .finished, .failed, .cancelled => true,
            else => false,
        };
    }
};

pub const ChatBlock = struct {
    id: []u8,
    node_id: ?[]u8 = null,
    role: []u8,
    content: []u8,
    timestamp_ms: ?i64 = null,

    pub fn deinit(self: *ChatBlock, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        if (self.node_id) |v| alloc.free(v);
        alloc.free(self.role);
        alloc.free(self.content);
    }
};

pub const LiveState = struct {
    allocator: std.mem.Allocator,
    run_id: []u8,
    workflow_name: []u8,
    root: ?*Node = null,
    live_root: ?*Node = null,
    selected_id: ?i64 = null,
    seq: i64 = 0,
    latest_frame_no: i64 = 0,
    displayed_frame_no: i64 = 0,
    mode: Mode = .live,
    status: RunStatus = .unknown,
    started_at_ms: ?i64 = null,
    last_event_ms: ?i64 = null,
    decode_error_count: usize = 0,
    stream_error: ?[]u8 = null,
    frames: std.ArrayList(Snapshot) = .empty,
    logs: std.ArrayList(ChatBlock) = .empty,

    pub const Mode = union(enum) {
        live,
        historical: i64,
    };

    pub fn init(alloc: std.mem.Allocator, run_id: []const u8) !LiveState {
        return .{
            .allocator = alloc,
            .run_id = try alloc.dupe(u8, run_id),
            .workflow_name = try alloc.dupe(u8, "Live Run"),
        };
    }

    pub fn deinit(self: *LiveState) void {
        if (self.root) |root| {
            root.deinit(self.allocator);
            self.allocator.destroy(root);
        }
        if (self.live_root) |root| {
            root.deinit(self.allocator);
            self.allocator.destroy(root);
        }
        for (self.frames.items) |*snapshot| snapshot.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        for (self.logs.items) |*block| block.deinit(self.allocator);
        self.logs.deinit(self.allocator);
        if (self.stream_error) |err| self.allocator.free(err);
        self.allocator.free(self.workflow_name);
        self.allocator.free(self.run_id);
    }

    pub fn selectedNode(self: *LiveState) ?*Node {
        const id = self.selected_id orelse return null;
        const root = self.root orelse return null;
        return root.find(id);
    }

    pub fn selectedNodeConst(self: *const LiveState) ?*const Node {
        const id = self.selected_id orelse return null;
        const root = self.root orelse return null;
        return root.findConst(id);
    }

    pub fn applyPayload(self: *LiveState, payload: []const u8) !void {
        var parsed = std.json.parseFromSlice(Value, self.allocator, payload, .{}) catch |err| {
            self.decode_error_count += 1;
            log.err("applyPayload decode failed run_id={s} bytes={d} err={s} total_errs={d}", .{
                self.run_id, payload.len, @errorName(err), self.decode_error_count,
            });
            return err;
        };
        defer parsed.deinit();
        self.applyValue(&parsed.value) catch |err| {
            log.warn("applyPayload applyValue failed run_id={s} err={s}", .{ self.run_id, @errorName(err) });
            return err;
        };
        self.last_event_ms = nowMs();
    }

    pub fn applyError(self: *LiveState, payload: []const u8) !void {
        if (self.stream_error) |old| self.allocator.free(old);
        self.stream_error = try self.allocator.dupe(u8, payload);
        self.last_event_ms = nowMs();
    }

    pub fn selectFirstIfNeeded(self: *LiveState) void {
        if (self.selected_id != null) return;
        if (self.root) |root| self.selected_id = root.id;
    }

    pub fn select(self: *LiveState, id: ?i64) void {
        if (id) |value| {
            if (self.root) |root| {
                if (root.find(value) != null) {
                    self.selected_id = value;
                    return;
                }
            }
        }
        self.selected_id = null;
    }

    pub fn scrubTo(self: *LiveState, frame_no: i64) !void {
        if (frame_no >= self.latest_frame_no) {
            try self.returnToLive();
            return;
        }
        for (self.frames.items) |*snapshot| {
            if (snapshot.frame_no == frame_no) {
                try self.replaceDisplayedRoot(try snapshot.root.clone(self.allocator));
                self.seq = snapshot.seq;
                self.displayed_frame_no = snapshot.frame_no;
                self.mode = .{ .historical = snapshot.frame_no };
                self.status = RunStatus.fromExecution(self.root.?.state());
                return;
            }
        }
        return error.FrameNotAvailable;
    }

    pub fn returnToLive(self: *LiveState) !void {
        self.mode = .live;
        self.displayed_frame_no = self.latest_frame_no;
        if (self.live_root) |root| {
            try self.replaceDisplayedRoot(try root.clone(self.allocator));
            self.status = RunStatus.fromExecution(root.state());
        }
    }

    pub fn runningLeafCount(self: *const LiveState) usize {
        const root = self.root orelse return 0;
        return runningLeafCountNode(root);
    }

    pub fn isHistorical(self: *const LiveState) bool {
        return switch (self.mode) {
            .historical => true,
            .live => false,
        };
    }

    pub fn historicalFrameNo(self: *const LiveState) ?i64 {
        return switch (self.mode) {
            .historical => |frame| frame,
            .live => null,
        };
    }

    fn applyValue(self: *LiveState, value: *Value) !void {
        const obj = object(value) orelse {
            try self.appendLooseLog(value);
            return;
        };

        if (obj.get("event")) |event_value| {
            var event_copy = event_value;
            if (object(&event_copy) != null) return self.applyValue(&event_copy);
        }
        if (obj.get("data")) |data_value| {
            var data_copy = data_value;
            if (object(&data_copy)) |_| {
                if (obj.get("type") == null or stringFieldBorrowed(obj, &.{"type"}) == null) {
                    return self.applyValue(&data_copy);
                }
            }
        }

        const event_type = stringFieldBorrowed(obj, &.{"type"});
        if (event_type) |kind| {
            if (std.mem.eql(u8, kind, "snapshot")) return self.applySnapshot(obj);
            if (std.mem.eql(u8, kind, "delta")) return self.applyDelta(obj);
            if (std.mem.eql(u8, kind, "runStatus") or std.mem.eql(u8, kind, "status")) {
                self.status = RunStatus.parse(stringFieldBorrowed(obj, &.{"status"}));
                return;
            }
            if (std.mem.eql(u8, kind, "chat") or std.mem.eql(u8, kind, "log")) {
                try self.appendChatBlock(obj);
                return;
            }
        }

        if (obj.get("root") != null and (obj.get("seq") != null or obj.get("frameNo") != null or obj.get("frame_no") != null)) {
            return self.applySnapshot(obj);
        }
        if (obj.get("ops") != null) return self.applyDelta(obj);
        if (obj.get("block")) |block_value| {
            var block_copy = block_value;
            if (object(&block_copy)) |block_obj| return self.appendChatBlock(block_obj);
        }

        try self.appendLooseLog(value);
    }

    fn applySnapshot(self: *LiveState, obj: *std.json.ObjectMap) !void {
        if (stringFieldBorrowed(obj, &.{ "runId", "run_id" })) |incoming_run_id| {
            if (self.run_id.len > 0 and !std.mem.eql(u8, self.run_id, incoming_run_id)) {
                return error.RunIdMismatch;
            }
        }

        const root_value = obj.get("root") orelse return error.MissingRoot;
        var root_copy = root_value;
        const root_obj = object(&root_copy) orelse return error.MissingRoot;
        const parsed_root = try parseNode(self.allocator, root_obj, 0);
        errdefer {
            parsed_root.deinit(self.allocator);
            self.allocator.destroy(parsed_root);
        }

        const seq = intField(obj, &.{"seq"}) orelse self.seq + 1;
        if (seq <= self.seq and self.live_root != null) return;

        const frame_no = intField(obj, &.{ "frameNo", "frame_no" }) orelse seq;
        self.seq = seq;
        self.latest_frame_no = @max(self.latest_frame_no, frame_no);
        self.displayed_frame_no = switch (self.mode) {
            .live => frame_no,
            .historical => |frame| frame,
        };
        if (stringFieldBorrowed(obj, &.{ "workflowName", "workflow_name", "workflow" })) |workflow| {
            try self.setWorkflowName(workflow);
        }

        try self.replaceLiveRoot(parsed_root);
        try self.recordFrame(frame_no, seq);

        if (self.mode == .live) {
            try self.replaceDisplayedRoot(try self.live_root.?.clone(self.allocator));
        }
        self.status = RunStatus.fromExecution(self.live_root.?.state());
        self.selectFirstIfNeeded();
        log.debug("snapshot applied run_id={s} seq={d} frame={d} nodes={d}", .{
            self.run_id, self.seq, self.latest_frame_no, self.live_root.?.count(),
        });
    }

    fn applyDelta(self: *LiveState, obj: *std.json.ObjectMap) !void {
        const seq = intField(obj, &.{"seq"}) orelse self.seq + 1;
        if (seq <= self.seq and self.live_root != null) return;

        const ops_value = obj.get("ops") orelse return error.MissingOps;
        var ops_copy = ops_value;
        const ops = array(&ops_copy) orelse return error.MissingOps;
        for (ops) |*op_value| {
            const op_obj = object(op_value) orelse continue;
            try self.applyOp(op_obj);
        }

        self.seq = seq;
        self.latest_frame_no = @max(self.latest_frame_no, intField(obj, &.{ "frameNo", "frame_no" }) orelse seq);
        if (self.mode == .live) self.displayed_frame_no = self.latest_frame_no;
        if (self.live_root) |root| self.status = RunStatus.fromExecution(root.state());
        try self.recordFrame(self.latest_frame_no, seq);
        if (self.mode == .live and self.live_root != null) {
            try self.replaceDisplayedRoot(try self.live_root.?.clone(self.allocator));
        }
        if (self.live_root) |root| {
            log.debug("delta applied run_id={s} seq={d} frame={d} nodes={d}", .{
                self.run_id, self.seq, self.latest_frame_no, root.count(),
            });
        }
    }

    fn applyOp(self: *LiveState, obj: *std.json.ObjectMap) !void {
        const op = stringFieldBorrowed(obj, &.{"op"}) orelse return;
        if (std.mem.eql(u8, op, "addNode")) {
            const parent_id = intField(obj, &.{"parentId"}) orelse return error.MissingParent;
            const index = intField(obj, &.{"index"}) orelse 0;
            const node_value = obj.get("node") orelse return error.MissingNode;
            var node_copy = node_value;
            const node_obj = object(&node_copy) orelse return error.MissingNode;
            const node = try parseNode(self.allocator, node_obj, 0);
            errdefer {
                node.deinit(self.allocator);
                self.allocator.destroy(node);
            }
            if (self.live_root == null) {
                if (parent_id == -1) {
                    self.live_root = node;
                    return;
                }
                return error.UnknownParent;
            }
            const parent = self.live_root.?.find(parent_id) orelse return error.UnknownParent;
            node.depth = parent.depth + 1;
            const insert_at: usize = if (index < 0) 0 else @min(@as(usize, @intCast(index)), parent.children.items.len);
            try parent.children.insert(self.allocator, insert_at, node);
        } else if (std.mem.eql(u8, op, "removeNode")) {
            const id = intField(obj, &.{"id"}) orelse return error.MissingNode;
            const root = self.live_root orelse return;
            if (root.id == id) {
                root.deinit(self.allocator);
                self.allocator.destroy(root);
                self.live_root = null;
                return;
            }
            _ = root.removeChildRecursive(self.allocator, id);
        } else if (std.mem.eql(u8, op, "updateProps")) {
            const id = intField(obj, &.{"id"}) orelse return error.MissingNode;
            const root = self.live_root orelse return error.UnknownNode;
            const node = root.find(id) orelse return error.UnknownNode;
            const props_value = obj.get("props") orelse return;
            var props_copy = props_value;
            const props_obj = object(&props_copy) orelse return;
            try mergeProps(self.allocator, node, props_obj);
        } else if (std.mem.eql(u8, op, "updateTask")) {
            const id = intField(obj, &.{"id"}) orelse return error.MissingNode;
            const root = self.live_root orelse return error.UnknownNode;
            const node = root.find(id) orelse return error.UnknownNode;
            if (node.task) |*task| {
                task.deinit(self.allocator);
                node.task = null;
            }
            if (obj.get("task")) |task_value| {
                var task_copy = task_value;
                if (object(&task_copy)) |task_obj| node.task = try parseTask(self.allocator, task_obj);
            }
        }
    }

    fn appendLooseLog(self: *LiveState, value: *Value) !void {
        const rendered = try renderJson(self.allocator, value);
        errdefer self.allocator.free(rendered);
        try self.logs.append(self.allocator, .{
            .id = try std.fmt.allocPrint(self.allocator, "event-{d}", .{self.logs.items.len + 1}),
            .role = try self.allocator.dupe(u8, "event"),
            .content = rendered,
            .timestamp_ms = nowMs(),
        });
    }

    fn appendChatBlock(self: *LiveState, obj: *std.json.ObjectMap) !void {
        const content = stringFieldBorrowed(obj, &.{ "content", "text", "message", "markdown" }) orelse return;
        try self.logs.append(self.allocator, .{
            .id = try ownedStringField(self.allocator, obj, &.{ "itemId", "item_id", "id" }) orelse
                try std.fmt.allocPrint(self.allocator, "log-{d}", .{self.logs.items.len + 1}),
            .node_id = try ownedStringField(self.allocator, obj, &.{ "nodeId", "node_id" }),
            .role = try ownedStringField(self.allocator, obj, &.{"role"}) orelse try self.allocator.dupe(u8, "log"),
            .content = try self.allocator.dupe(u8, content),
            .timestamp_ms = intField(obj, &.{ "timestampMs", "timestamp_ms" }) orelse nowMs(),
        });
    }

    fn replaceLiveRoot(self: *LiveState, root: *Node) !void {
        if (self.live_root) |old| {
            old.deinit(self.allocator);
            self.allocator.destroy(old);
        }
        self.live_root = root;
    }

    fn replaceDisplayedRoot(self: *LiveState, root: *Node) !void {
        if (self.root) |old| {
            old.deinit(self.allocator);
            self.allocator.destroy(old);
        }
        self.root = root;
        if (self.selected_id) |selected| {
            if (root.find(selected) == null) self.selected_id = root.id;
        }
    }

    fn recordFrame(self: *LiveState, frame_no: i64, seq: i64) !void {
        const root = self.live_root orelse return;
        const copied = try root.clone(self.allocator);
        errdefer {
            copied.deinit(self.allocator);
            self.allocator.destroy(copied);
        }
        for (self.frames.items) |*snapshot| {
            if (snapshot.frame_no == frame_no) {
                snapshot.deinit(self.allocator);
                snapshot.* = .{ .frame_no = frame_no, .seq = seq, .root = copied };
                return;
            }
        }
        try self.frames.append(self.allocator, .{ .frame_no = frame_no, .seq = seq, .root = copied });
        if (self.frames.items.len > 256) {
            var old = self.frames.orderedRemove(0);
            old.deinit(self.allocator);
        }
    }

    fn setWorkflowName(self: *LiveState, workflow: []const u8) !void {
        self.allocator.free(self.workflow_name);
        self.workflow_name = try self.allocator.dupe(u8, workflow);
    }
};

pub const AncestorErrorIndex = struct {
    failed_ancestors: std.AutoHashMap(i64, usize),

    pub fn init(alloc: std.mem.Allocator, root: ?*const Node) !AncestorErrorIndex {
        var index = AncestorErrorIndex{ .failed_ancestors = .init(alloc) };
        if (root) |node| {
            var path: std.ArrayList(i64) = .empty;
            defer path.deinit(alloc);
            try index.walk(alloc, node, &path);
        }
        return index;
    }

    pub fn deinit(self: *AncestorErrorIndex) void {
        self.failed_ancestors.deinit();
    }

    pub fn count(self: *const AncestorErrorIndex, id: i64) usize {
        return self.failed_ancestors.get(id) orelse 0;
    }

    fn walk(self: *AncestorErrorIndex, alloc: std.mem.Allocator, node: *const Node, path: *std.ArrayList(i64)) !void {
        if (node.state() == .failed) {
            for (path.items) |ancestor| {
                const current = self.failed_ancestors.get(ancestor) orelse 0;
                try self.failed_ancestors.put(ancestor, current + 1);
            }
        }
        try path.append(alloc, node.id);
        defer _ = path.pop();
        for (node.children.items) |child| try self.walk(alloc, child, path);
    }
};

pub const ExpandedSet = struct {
    ids: std.AutoHashMap(i64, void),
    user_collapsed: std.AutoHashMap(i64, void),

    pub fn init(alloc: std.mem.Allocator) ExpandedSet {
        return .{
            .ids = .init(alloc),
            .user_collapsed = .init(alloc),
        };
    }

    pub fn deinit(self: *ExpandedSet) void {
        self.ids.deinit();
        self.user_collapsed.deinit();
    }

    pub fn contains(self: *const ExpandedSet, id: i64) bool {
        return self.ids.contains(id);
    }

    pub fn expand(self: *ExpandedSet, id: i64) !void {
        try self.ids.put(id, {});
        _ = self.user_collapsed.remove(id);
    }

    pub fn collapse(self: *ExpandedSet, id: i64) !void {
        _ = self.ids.remove(id);
        try self.user_collapsed.put(id, {});
    }

    pub fn toggle(self: *ExpandedSet, id: i64) !void {
        if (self.contains(id)) {
            try self.collapse(id);
        } else {
            try self.expand(id);
        }
    }

    pub fn expandAll(self: *ExpandedSet, root: ?*const Node) !void {
        if (root) |node| try self.expandAllNode(node);
    }

    pub fn collapseAll(self: *ExpandedSet) void {
        self.ids.clearRetainingCapacity();
        self.user_collapsed.clearRetainingCapacity();
    }

    pub fn expandPathTo(self: *ExpandedSet, root: ?*const Node, target_id: i64) !void {
        const node = root orelse return;
        var path: std.ArrayList(i64) = .empty;
        defer path.deinit(self.ids.allocator);
        if (!try collectPathTo(self.ids.allocator, node, target_id, &path)) return;
        if (path.items.len <= 1) return;
        for (path.items[0 .. path.items.len - 1]) |id| try self.expand(id);
    }

    pub fn autoExpandRunningPaths(self: *ExpandedSet, root: ?*const Node) !void {
        const node = root orelse return;
        var path: std.ArrayList(i64) = .empty;
        defer path.deinit(self.ids.allocator);
        try self.walkRunning(node, &path);
    }

    fn expandAllNode(self: *ExpandedSet, node: *const Node) !void {
        if (node.children.items.len > 0) try self.expand(node.id);
        for (node.children.items) |child| try self.expandAllNode(child);
    }

    fn walkRunning(self: *ExpandedSet, node: *const Node, path: *std.ArrayList(i64)) !void {
        if (node.state() == .running) {
            for (path.items) |ancestor| {
                if (!self.user_collapsed.contains(ancestor)) try self.ids.put(ancestor, {});
            }
            if (node.children.items.len > 0 and !self.user_collapsed.contains(node.id)) try self.ids.put(node.id, {});
        }
        try path.append(self.ids.allocator, node.id);
        defer _ = path.pop();
        for (node.children.items) |child| try self.walkRunning(child, path);
    }
};

pub const VisibleRows = struct {
    items: std.ArrayList(*const Node) = .empty,

    pub fn deinit(self: *VisibleRows, alloc: std.mem.Allocator) void {
        self.items.deinit(alloc);
    }
};

pub fn collectVisibleRows(alloc: std.mem.Allocator, root: ?*const Node, expanded: *const ExpandedSet) !VisibleRows {
    var rows = VisibleRows{};
    if (root) |node| try collectVisibleNode(alloc, node, expanded, &rows.items);
    return rows;
}

fn collectVisibleNode(
    alloc: std.mem.Allocator,
    node: *const Node,
    expanded: *const ExpandedSet,
    rows: *std.ArrayList(*const Node),
) !void {
    try rows.append(alloc, node);
    if (!expanded.contains(node.id)) return;
    for (node.children.items) |child| try collectVisibleNode(alloc, child, expanded, rows);
}

fn collectPathTo(
    alloc: std.mem.Allocator,
    node: *const Node,
    target_id: i64,
    path: *std.ArrayList(i64),
) !bool {
    try path.append(alloc, node.id);
    if (node.id == target_id) return true;
    for (node.children.items) |child| {
        if (try collectPathTo(alloc, child, target_id, path)) return true;
    }
    _ = path.pop();
    return false;
}

pub const TreeKeyboardAction = enum {
    move_up,
    move_down,
    collapse,
    expand,
    move_first,
    move_last,
    focus_inspector,
    focus_search,
    clear_search,
};

pub const FocusTarget = enum {
    inspector,
    search,
    clear_search,
};

pub const ExpandChange = union(enum) {
    expand: i64,
    collapse: i64,
};

pub const TreeKeyboardResult = struct {
    selected_id: ?i64 = null,
    expand_change: ?ExpandChange = null,
    focus: ?FocusTarget = null,
};

pub fn handleTreeKeyboard(
    action: TreeKeyboardAction,
    selected_id: ?i64,
    visible_rows: []const *const Node,
    expanded: *const ExpandedSet,
    root: ?*const Node,
) TreeKeyboardResult {
    switch (action) {
        .move_up => return moveBy(selected_id, visible_rows, -1),
        .move_down => return moveBy(selected_id, visible_rows, 1),
        .move_first => return .{ .selected_id = if (visible_rows.len > 0) visible_rows[0].id else selected_id },
        .move_last => return .{ .selected_id = if (visible_rows.len > 0) visible_rows[visible_rows.len - 1].id else selected_id },
        .collapse => {
            const id = selected_id orelse return .{};
            const node = if (root) |r| r.findConst(id) else null;
            if (node) |n| {
                if (n.children.items.len > 0 and expanded.contains(id)) return .{ .selected_id = id, .expand_change = .{ .collapse = id } };
            }
            if (root) |r| {
                if (r.findParentConst(id)) |parent| return .{ .selected_id = parent.id };
            }
            return .{ .selected_id = id };
        },
        .expand => {
            const id = selected_id orelse return .{};
            const index = rowIndex(visible_rows, id) orelse return .{ .selected_id = id };
            const node = visible_rows[index];
            if (node.children.items.len > 0 and !expanded.contains(id)) return .{ .selected_id = id, .expand_change = .{ .expand = id } };
            if (node.children.items.len > 0 and index + 1 < visible_rows.len) return .{ .selected_id = visible_rows[index + 1].id };
            return .{ .selected_id = id };
        },
        .focus_inspector => return .{ .selected_id = selected_id, .focus = .inspector },
        .focus_search => return .{ .selected_id = selected_id, .focus = .search },
        .clear_search => return .{ .selected_id = selected_id, .focus = .clear_search },
    }
}

fn moveBy(selected_id: ?i64, visible_rows: []const *const Node, delta: i32) TreeKeyboardResult {
    if (visible_rows.len == 0) return .{};
    const selected = selected_id orelse return .{ .selected_id = if (delta < 0) visible_rows[visible_rows.len - 1].id else visible_rows[0].id };
    const index = rowIndex(visible_rows, selected) orelse return .{ .selected_id = visible_rows[0].id };
    if (delta < 0) {
        if (index == 0) return .{ .selected_id = selected };
        return .{ .selected_id = visible_rows[index - 1].id };
    }
    if (index + 1 >= visible_rows.len) return .{ .selected_id = selected };
    return .{ .selected_id = visible_rows[index + 1].id };
}

fn rowIndex(rows: []const *const Node, id: i64) ?usize {
    for (rows, 0..) |row, index| {
        if (row.id == id) return index;
    }
    return null;
}

pub const SearchIndex = struct {
    matched: std.AutoHashMap(i64, void),
    active: bool = false,

    pub fn init(alloc: std.mem.Allocator, root: ?*const Node, query: []const u8) !SearchIndex {
        const trimmed = std.mem.trim(u8, query, &std.ascii.whitespace);
        var index = SearchIndex{ .matched = .init(alloc), .active = trimmed.len > 0 };
        if (!index.active) return index;
        const normalized = try std.ascii.allocLowerString(alloc, trimmed);
        defer alloc.free(normalized);
        if (root) |node| try index.walk(node, normalized);
        return index;
    }

    pub fn deinit(self: *SearchIndex) void {
        self.matched.deinit();
    }

    pub fn isMatch(self: *const SearchIndex, id: i64) bool {
        return !self.active or self.matched.contains(id);
    }

    pub fn isDimmed(self: *const SearchIndex, id: i64) bool {
        return self.active and !self.matched.contains(id);
    }

    pub fn hasMatches(self: *const SearchIndex) bool {
        return !self.active or self.matched.count() > 0;
    }

    fn walk(self: *SearchIndex, node: *const Node, query: []const u8) !void {
        if (try nodeMatches(self.matched.allocator, node, query)) try self.matched.put(node.id, {});
        for (node.children.items) |child| try self.walk(child, query);
    }
};

pub fn propMatchesSearch(prop: Prop, query: []const u8, alloc: std.mem.Allocator) !bool {
    const trimmed = std.mem.trim(u8, query, &std.ascii.whitespace);
    if (trimmed.len == 0) return true;
    const lowered_query = try std.ascii.allocLowerString(alloc, trimmed);
    defer alloc.free(lowered_query);
    const lower_key = try std.ascii.allocLowerString(alloc, prop.key);
    defer alloc.free(lower_key);
    if (std.mem.indexOf(u8, lower_key, lowered_query) != null) return true;
    const lower_value = try std.ascii.allocLowerString(alloc, prop.rendered);
    defer alloc.free(lower_value);
    return std.mem.indexOf(u8, lower_value, lowered_query) != null;
}

pub fn rawPropValue(alloc: std.mem.Allocator, prop: Prop) ![]u8 {
    if (prop.string_value) |value| return alloc.dupe(u8, value);
    return alloc.dupe(u8, prop.rendered);
}

pub fn singleLinePreview(alloc: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var last_was_space = false;
    for (text) |ch| {
        const is_space = std.ascii.isWhitespace(ch);
        if (is_space) {
            if (!last_was_space and out.written().len > 0) {
                try out.writer.writeByte(' ');
                last_was_space = true;
            }
        } else {
            try out.writer.writeByte(ch);
            last_was_space = false;
        }
        if (out.written().len >= max_len) break;
    }
    const owned = try out.toOwnedSlice();
    errdefer alloc.free(owned);
    const trimmed = std.mem.trimRight(u8, owned, " ");
    if (owned.len == max_len and text.len > max_len) {
        const prefix_len = @max(trimmed.len, 3) - 3;
        const truncated = try std.fmt.allocPrint(alloc, "{s}...", .{trimmed[0..prefix_len]});
        alloc.free(owned);
        return truncated;
    }
    if (trimmed.len == owned.len) return owned;
    const result = try alloc.dupe(u8, trimmed);
    alloc.free(owned);
    return result;
}

pub fn lastLogForTask(state: *const LiveState, node_id: []const u8) ?*const ChatBlock {
    var i = state.logs.items.len;
    while (i > 0) {
        i -= 1;
        const block = &state.logs.items[i];
        const block_node = block.node_id orelse continue;
        if (std.mem.eql(u8, block_node, node_id)) return block;
        if (std.mem.startsWith(u8, block_node, node_id) and block_node.len > node_id.len and block_node[node_id.len] == ':') return block;
    }
    return null;
}

pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,

    pub fn parse(raw: []const u8) ?LogLevel {
        if (std.ascii.eqlIgnoreCase(raw, "trace")) return .trace;
        if (std.ascii.eqlIgnoreCase(raw, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(raw, "info") or std.ascii.eqlIgnoreCase(raw, "log")) return .info;
        if (std.ascii.eqlIgnoreCase(raw, "warn") or std.ascii.eqlIgnoreCase(raw, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(raw, "error") or std.ascii.eqlIgnoreCase(raw, "err") or std.ascii.eqlIgnoreCase(raw, "stderr")) return .err;
        return null;
    }

    pub fn label(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "trace",
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }
};

pub fn logBlockLevel(block: ChatBlock) LogLevel {
    if (LogLevel.parse(block.role)) |level| return level;
    const trimmed = std.mem.trimLeft(u8, block.content, &std.ascii.whitespace);
    const levels = [_]LogLevel{ .trace, .debug, .info, .warn, .err };
    for (levels) |level| {
        if (std.ascii.startsWithIgnoreCase(trimmed, level.label())) return level;
    }
    return .info;
}

pub fn logMatches(block: ChatBlock, node_id: ?[]const u8, level: ?LogLevel, query: []const u8, alloc: std.mem.Allocator) !bool {
    if (node_id) |id| {
        const block_node = block.node_id orelse return false;
        if (!std.mem.eql(u8, block_node, id) and !(std.mem.startsWith(u8, block_node, id) and block_node.len > id.len and block_node[id.len] == ':')) return false;
    }
    if (level) |wanted| {
        if (logBlockLevel(block) != wanted) return false;
    }
    const trimmed = std.mem.trim(u8, query, &std.ascii.whitespace);
    if (trimmed.len == 0) return true;
    const lower_query = try std.ascii.allocLowerString(alloc, trimmed);
    defer alloc.free(lower_query);
    const lower_content = try std.ascii.allocLowerString(alloc, block.content);
    defer alloc.free(lower_content);
    if (std.mem.indexOf(u8, lower_content, lower_query) != null) return true;
    const lower_role = try std.ascii.allocLowerString(alloc, block.role);
    defer alloc.free(lower_role);
    if (std.mem.indexOf(u8, lower_role, lower_query) != null) return true;
    if (block.node_id) |block_node| {
        const lower_node = try std.ascii.allocLowerString(alloc, block_node);
        defer alloc.free(lower_node);
        return std.mem.indexOf(u8, lower_node, lower_query) != null;
    }
    return false;
}

pub const Page = struct {
    index: usize,
    count: usize,
    start: usize,
    end: usize,
};

pub fn pageFor(total: usize, page_index: usize, page_size: usize) Page {
    const size = @max(page_size, 1);
    const count = @max(@divTrunc(total + size - 1, size), 1);
    const index = @min(page_index, count - 1);
    const start = @min(index * size, total);
    const end = @min(start + size, total);
    return .{ .index = index, .count = count, .start = start, .end = end };
}

pub fn looksLikeMarkdown(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "```") != null or
        std.mem.indexOf(u8, text, "\n# ") != null or
        std.mem.startsWith(u8, text, "# ") or
        std.mem.indexOf(u8, text, "\n- ") != null;
}

pub fn looksLikeJson(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    return (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') or
        (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']');
}

fn nodeMatches(alloc: std.mem.Allocator, node: *const Node, query: []const u8) !bool {
    const lower_name = try std.ascii.allocLowerString(alloc, node.name);
    defer alloc.free(lower_name);
    if (std.mem.indexOf(u8, lower_name, query) != null) return true;
    if (node.task) |task| {
        const lower_node_id = try std.ascii.allocLowerString(alloc, task.node_id);
        defer alloc.free(lower_node_id);
        if (std.mem.indexOf(u8, lower_node_id, query) != null) return true;
        if (task.label) |label| {
            const lower_label = try std.ascii.allocLowerString(alloc, label);
            defer alloc.free(lower_label);
            if (std.mem.indexOf(u8, lower_label, query) != null) return true;
        }
    }
    for (node.props.items) |prop| {
        const lower_key = try std.ascii.allocLowerString(alloc, prop.key);
        defer alloc.free(lower_key);
        if (std.mem.indexOf(u8, lower_key, query) != null) return true;
        const lower_value = try std.ascii.allocLowerString(alloc, prop.rendered);
        defer alloc.free(lower_value);
        if (std.mem.indexOf(u8, lower_value, query) != null) return true;
    }
    return false;
}

pub fn keyPropsSummary(alloc: std.mem.Allocator, node: *const Node, max_len: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;
    var needs_space = false;
    if (node.stringProp("id")) |id| {
        try writer.print("id=\"{s}\"", .{id});
        needs_space = true;
    }
    if (node.stringProp("name")) |name| {
        if (needs_space) try writer.writeByte(' ');
        try writer.print("name=\"{s}\"", .{name});
        needs_space = true;
    }
    if (node.task) |task| {
        if (task.label) |label| {
            if (needs_space) try writer.writeByte(' ');
            try writer.writeAll(label);
            needs_space = true;
        }
        if (task.agent) |agent| {
            if (needs_space) try writer.writeByte(' ');
            try writer.print("agent={s}", .{agent});
            needs_space = true;
        }
        if (task.iteration) |iteration| if (iteration > 0) {
            if (needs_space) try writer.writeByte(' ');
            try writer.print("iter={d}", .{iteration});
        };
    }
    const written = out.written();
    if (written.len <= max_len) return try out.toOwnedSlice();
    return try std.fmt.allocPrint(alloc, "{s}...", .{written[0 .. max_len - 3]});
}

pub fn elapsedText(alloc: std.mem.Allocator, node: *const Node, now_ms: i64) !?[]u8 {
    const started = node.numberProp("startedAtMs") orelse return null;
    const finished = node.numberProp("finishedAtMs");
    const end_ms: f64 = finished orelse @floatFromInt(now_ms);
    if (end_ms < started) return null;
    const total_seconds: i64 = @intFromFloat((end_ms - started) / 1000.0);
    const minutes = @divTrunc(total_seconds, 60);
    const seconds = @mod(total_seconds, 60);
    if (minutes > 0) return try std.fmt.allocPrint(alloc, "{d}:{d:0>2}", .{ minutes, seconds });
    return try std.fmt.allocPrint(alloc, "{d}s", .{seconds});
}

pub fn formatElapsed(alloc: std.mem.Allocator, seconds_raw: i64) ![]u8 {
    const seconds = @max(seconds_raw, 0);
    const hours = @divTrunc(seconds, 3600);
    const minutes = @divTrunc(@mod(seconds, 3600), 60);
    const secs = @mod(seconds, 60);
    if (hours > 0) return try std.fmt.allocPrint(alloc, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, secs });
    return try std.fmt.allocPrint(alloc, "{d:0>2}:{d:0>2}", .{ minutes, secs });
}

pub fn heartbeatColor(now_ms: i64, last_event_ms: ?i64, heartbeat_ms: i64) ExecutionState {
    if (heartbeat_ms <= 0) return .failed;
    const last = last_event_ms orelse return .failed;
    const elapsed = now_ms - last;
    if (elapsed < 0) return .running;
    if (elapsed <= heartbeat_ms * 2) return .running;
    if (elapsed < heartbeat_ms * 5) return .blocked;
    return .failed;
}

fn parseNode(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, fallback_depth: usize) !*Node {
    const node = try alloc.create(Node);
    errdefer alloc.destroy(node);

    const node_type = NodeType.parse(stringFieldBorrowed(obj, &.{"type"}) orelse "unknown");
    const name = try ownedStringField(alloc, obj, &.{"name"}) orelse try alloc.dupe(u8, node_type.label());
    node.* = .{
        .id = intField(obj, &.{"id"}) orelse 0,
        .node_type = node_type,
        .name = name,
        .depth = @intCast(intField(obj, &.{"depth"}) orelse @as(i64, @intCast(fallback_depth))),
    };
    errdefer node.deinit(alloc);

    if (obj.get("props")) |props_value| {
        var props_copy = props_value;
        if (object(&props_copy)) |props_obj| try mergeProps(alloc, node, props_obj);
    }
    if (obj.get("task")) |task_value| {
        var task_copy = task_value;
        if (object(&task_copy)) |task_obj| node.task = try parseTask(alloc, task_obj);
    }
    if (obj.get("children")) |children_value| {
        var children_copy = children_value;
        if (array(&children_copy)) |children| {
            try node.children.ensureUnusedCapacity(alloc, children.len);
            for (children) |*child_value| {
                const child_obj = object(child_value) orelse continue;
                node.children.appendAssumeCapacity(try parseNode(alloc, child_obj, node.depth + 1));
            }
        }
    }
    return node;
}

fn parseTask(alloc: std.mem.Allocator, obj: *std.json.ObjectMap) !TaskInfo {
    return .{
        .node_id = try ownedStringField(alloc, obj, &.{ "nodeId", "node_id", "id" }) orelse try alloc.dupe(u8, ""),
        .kind = try ownedStringField(alloc, obj, &.{"kind"}) orelse try alloc.dupe(u8, "task"),
        .agent = try ownedStringField(alloc, obj, &.{"agent"}),
        .label = try ownedStringField(alloc, obj, &.{"label"}),
        .output_table_name = try ownedStringField(alloc, obj, &.{ "outputTableName", "output_table_name" }),
        .iteration = intField(obj, &.{"iteration"}),
    };
}

fn mergeProps(alloc: std.mem.Allocator, node: *Node, obj: *std.json.ObjectMap) !void {
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const rendered = try renderJson(alloc, entry.value_ptr);
        errdefer alloc.free(rendered);
        const string_value = switch (entry.value_ptr.*) {
            .string => |s| try alloc.dupe(u8, s),
            .number_string => |s| try alloc.dupe(u8, s),
            .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
            .bool => |b| try alloc.dupe(u8, if (b) "true" else "false"),
            else => null,
        };
        errdefer if (string_value) |v| alloc.free(v);
        const key = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer alloc.free(key);

        for (node.props.items) |*prop| {
            if (std.mem.eql(u8, prop.key, entry.key_ptr.*)) {
                prop.deinit(alloc);
                prop.* = .{ .key = key, .rendered = rendered, .string_value = string_value };
                break;
            }
        } else {
            try node.props.append(alloc, .{ .key = key, .rendered = rendered, .string_value = string_value });
        }
    }
}

fn renderJson(alloc: std.mem.Allocator, value: *const Value) ![]u8 {
    if (value.* == .string) return alloc.dupe(u8, value.string);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value.*, .{}, &out.writer);
    return try out.toOwnedSlice();
}

fn runningLeafCountNode(node: *const Node) usize {
    var count: usize = 0;
    if (node.node_type == .task and node.children.items.len == 0 and node.state() == .running) count += 1;
    for (node.children.items) |child| count += runningLeafCountNode(child);
    return count;
}

fn object(value: *Value) ?*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*obj| obj,
        else => null,
    };
}

fn array(value: *Value) ?[]Value {
    return switch (value.*) {
        .array => |arr| arr.items,
        else => null,
    };
}

fn stringFieldBorrowed(obj: *std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .string, .number_string => |s| return s,
            else => {},
        }
    }
    return null;
}

fn ownedStringField(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, keys: []const []const u8) !?[]u8 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .string, .number_string => |s| if (s.len > 0) return try alloc.dupe(u8, s),
            .integer => |i| return try std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| return try std.fmt.allocPrint(alloc, "{d}", .{f}),
            .bool => |b| return try alloc.dupe(u8, if (b) "true" else "false"),
            else => {},
        }
    }
    return null;
}

fn intField(obj: *std.json.ObjectMap, keys: []const []const u8) ?i64 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .integer => |i| return i,
            .float => |f| return @intFromFloat(f),
            .number_string, .string => |s| return std.fmt.parseInt(i64, s, 10) catch null,
            else => {},
        }
    }
    return null;
}

pub fn nowMs() i64 {
    return @divFloor(std.time.milliTimestamp(), 1);
}

test "applies snapshot and delta events" {
    const alloc = std.testing.allocator;
    var state = try LiveState.init(alloc, "run-1");
    defer state.deinit();

    try state.applyPayload(
        \\{"type":"snapshot","runId":"run-1","frameNo":1,"seq":1,"root":{"id":1,"type":"workflow","name":"Workflow","props":{"state":"running"},"children":[]}}
    );
    try std.testing.expectEqual(@as(i64, 1), state.seq);
    try std.testing.expectEqual(RunStatus.running, state.status);

    try state.applyPayload(
        \\{"type":"delta","baseSeq":1,"seq":2,"ops":[{"op":"addNode","parentId":1,"index":0,"node":{"id":2,"type":"task","name":"Task","props":{"state":"running"},"task":{"nodeId":"task:a","kind":"agent","label":"A"},"children":[]}}]}
    );
    try std.testing.expectEqual(@as(usize, 2), state.root.?.count());
    try std.testing.expectEqual(@as(usize, 1), state.runningLeafCount());
}

test "scrubs to recorded historical frame" {
    const alloc = std.testing.allocator;
    var state = try LiveState.init(alloc, "run-1");
    defer state.deinit();

    try state.applyPayload(
        \\{"type":"snapshot","runId":"run-1","frameNo":1,"seq":1,"root":{"id":1,"type":"workflow","name":"Workflow","props":{"state":"running"},"children":[]}}
    );
    try state.applyPayload(
        \\{"type":"delta","baseSeq":1,"seq":2,"ops":[{"op":"updateProps","id":1,"props":{"state":"finished"}}]}
    );

    try state.scrubTo(1);
    try std.testing.expect(state.isHistorical());
    try std.testing.expectEqual(@as(i64, 1), state.displayed_frame_no);
    try std.testing.expectEqual(ExecutionState.running, state.root.?.state());
    try state.returnToLive();
    try std.testing.expectEqual(ExecutionState.finished, state.root.?.state());
}

test "indexes failed descendants" {
    const alloc = std.testing.allocator;
    var state = try LiveState.init(alloc, "run-1");
    defer state.deinit();
    try state.applyPayload(
        \\{"type":"snapshot","runId":"run-1","frameNo":1,"seq":1,"root":{"id":1,"type":"workflow","name":"Workflow","props":{"state":"running"},"children":[{"id":2,"type":"task","name":"Task","props":{"state":"failed"},"children":[]}]}}
    );

    var index = try AncestorErrorIndex.init(alloc, state.root);
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 1), index.count(1));
    try std.testing.expectEqual(@as(usize, 0), index.count(2));
}

test "search index trims and matches task metadata" {
    const alloc = std.testing.allocator;
    var state = try LiveState.init(alloc, "run-1");
    defer state.deinit();
    try state.applyPayload(
        \\{"type":"snapshot","runId":"run-1","frameNo":1,"seq":1,"root":{"id":1,"type":"workflow","name":"Workflow","props":{"state":"running"},"children":[{"id":2,"type":"task","name":"Compile","props":{"state":"running"},"task":{"nodeId":"task:build","kind":"agent","label":"Build Linux"},"children":[]}]}}
    );

    var index = try SearchIndex.init(alloc, state.root, "  linux ");
    defer index.deinit();
    try std.testing.expect(index.active);
    try std.testing.expect(index.isMatch(2));
    try std.testing.expect(index.isDimmed(1));
}
