const std = @import("std");

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
            return err;
        };
        defer parsed.deinit();
        try self.applyValue(&parsed.value);
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

    fn walk(self: *SearchIndex, node: *const Node, query: []const u8) !void {
        if (try nodeMatches(self.matched.allocator, node, query)) try self.matched.put(node.id, {});
        for (node.children.items) |child| try self.walk(child, query);
    }
};

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
