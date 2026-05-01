const std = @import("std");

const Value = std.json.Value;

const ScoreInput = struct {
    scorer_id: ?[]const u8,
    scorer_name: ?[]const u8,
    score: f64,
};

const NameMap = struct {
    key: []const u8,
    name: []const u8,
};

const ScoreGroup = struct {
    key: []const u8,
    display_name: []const u8,
    values: std.ArrayList(f64),
};

const KeyIndex = struct {
    key: []const u8,
    index: usize,
};

const ChatBlock = struct {
    id: ?[]const u8,
    item_id: ?[]const u8,
    run_id: ?[]const u8,
    node_id: ?[]const u8,
    attempt: ?i64,
    role: []const u8,
    content: []const u8,
    timestamp_ms: ?i64,
};

pub fn call(allocator: std.mem.Allocator, method: []const u8, args: Value) !?[]u8 {
    if (!std.mem.startsWith(u8, method, "models.")) return null;

    if (std.mem.eql(u8, method, "models.aggregateScores")) return try aggregateScoresCall(allocator, args);
    if (std.mem.eql(u8, method, "models.deduplicateChatMessageIndexes")) return try deduplicateChatMessageIndexesCall(allocator, args);
    if (std.mem.eql(u8, method, "models.deduplicateChatBlocks")) return try deduplicateChatBlocksCall(allocator, args);
    if (std.mem.eql(u8, method, "models.chatBlockCanMerge")) return try chatBlockCanMergeCall(allocator, args);
    if (std.mem.eql(u8, method, "models.chatBlockHasOverlap")) return try chatBlockHasOverlapCall(allocator, args);
    if (std.mem.eql(u8, method, "models.chatBlockMerge")) return try chatBlockMergeCall(allocator, args);
    if (std.mem.eql(u8, method, "models.chatBlockMergedStreamingContent")) return try mergedStreamingContentCall(allocator, args);
    if (std.mem.eql(u8, method, "models.sseFiltered")) return try sseFilteredCall(allocator, args);
    if (std.mem.eql(u8, method, "models.sseExtractRunId")) return try sseExtractRunIdCall(allocator, args);
    if (std.mem.eql(u8, method, "models.sseRunIdMatches")) return try sseRunIdMatchesCall(allocator, args);
    if (std.mem.eql(u8, method, "models.sseNormalizedRunId")) return try sseNormalizedRunIdCall(allocator, args);

    return null;
}

fn aggregateScoresCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const scores_json = arrayArg(args, "scores") orelse &.{};
    if (scores_json.len == 0) return try allocator.dupe(u8, "[]");

    var scores: std.ArrayList(ScoreInput) = .empty;
    defer scores.deinit(scratch);
    for (scores_json) |row| {
        const score = objectFloat(row, "score") orelse continue;
        try scores.append(scratch, .{
            .scorer_id = objectString(row, "scorerId") orelse objectString(row, "scorer_id"),
            .scorer_name = objectString(row, "scorerName") orelse objectString(row, "scorer_name"),
            .score = score,
        });
    }
    if (scores.items.len == 0) return try allocator.dupe(u8, "[]");

    var names_by_id: std.ArrayList(NameMap) = .empty;
    defer names_by_id.deinit(scratch);
    for (scores.items) |score| {
        const scorer_id = normalized(score.scorer_id) orelse continue;
        const scorer_name = normalized(score.scorer_name) orelse continue;
        const key = try lowerAlloc(scratch, scorer_id);
        try putNameMap(scratch, &names_by_id, key, scorer_name);
    }

    var groups: std.ArrayList(ScoreGroup) = .empty;
    defer {
        for (groups.items) |*group| group.values.deinit(scratch);
        groups.deinit(scratch);
    }

    for (scores.items) |score| {
        const key = try scorerGroupKey(scratch, score, names_by_id.items);
        const group_index = findGroup(groups.items, key) orelse blk: {
            const values: std.ArrayList(f64) = .empty;
            try groups.append(scratch, .{
                .key = key,
                .display_name = scorerGroupDisplayName(score, names_by_id.items),
                .values = values,
            });
            break :blk groups.items.len - 1;
        };
        try groups.items[group_index].values.append(scratch, score.score);
    }

    std.mem.sort(ScoreGroup, groups.items, {}, scoreGroupLess);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (groups.items, 0..) |group, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        const stats = try aggregateValues(scratch, group.values.items);
        try out.writer.print(
            "{{\"scorerName\":{f},\"count\":{},\"mean\":{d},\"min\":{d},\"max\":{d},\"p50\":{d}}}",
            .{
                std.json.fmt(group.display_name, .{}),
                group.values.items.len,
                stats.mean,
                stats.min,
                stats.max,
                stats.p50,
            },
        );
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn deduplicateChatMessageIndexesCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const messages = arrayArg(args, "messages") orelse &.{};
    var result: std.ArrayList(usize) = .empty;
    defer result.deinit(scratch);
    var indexes: std.ArrayList(KeyIndex) = .empty;
    defer indexes.deinit(scratch);

    for (messages, 0..) |message, message_index| {
        const item_id = firstNonEmpty(&.{
            objectString(message, "commandItemId"),
            objectString(message, "toolItemId"),
        });
        const item_id_value = item_id orelse {
            try result.append(scratch, message_index);
            continue;
        };

        if (findKeyIndex(indexes.items, item_id_value)) |existing| {
            result.items[existing] = message_index;
        } else {
            try indexes.append(scratch, .{ .key = item_id_value, .index = result.items.len });
            try result.append(scratch, message_index);
        }
    }

    return writeIndexArray(allocator, result.items);
}

fn deduplicateChatBlocksCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const blocks_json = arrayArg(args, "blocks") orelse &.{};
    var result: std.ArrayList(ChatBlock) = .empty;
    defer result.deinit(scratch);
    var index_by_lifecycle_id: std.ArrayList(KeyIndex) = .empty;
    defer index_by_lifecycle_id.deinit(scratch);

    for (blocks_json) |block_json| {
        const block = parseChatBlock(block_json);
        if (lifecycleId(block)) |id| {
            if (findKeyIndex(index_by_lifecycle_id.items, id)) |existing_index| {
                const existing = result.items[existing_index];
                result.items[existing_index] = if (canMergeAssistantStream(existing, block))
                    try mergeChatBlocks(scratch, existing, block)
                else
                    block;
                if (lifecycleId(result.items[existing_index])) |merged_id| {
                    try putKeyIndex(scratch, &index_by_lifecycle_id, merged_id, existing_index);
                }
                continue;
            }
        }

        if (result.items.len > 0) {
            const last_index = result.items.len - 1;
            const existing = result.items[last_index];
            const can_correlate_stream = lifecycleId(existing) != null or lifecycleId(block) != null;
            if (can_correlate_stream and
                canMergeAssistantStream(existing, block) and
                hasStreamingContentOverlap(existing.content, block.content))
            {
                result.items[last_index] = try mergeChatBlocks(scratch, existing, block);
                if (lifecycleId(existing)) |id| try putKeyIndex(scratch, &index_by_lifecycle_id, id, last_index);
                if (lifecycleId(block)) |id| try putKeyIndex(scratch, &index_by_lifecycle_id, id, last_index);
                if (lifecycleId(result.items[last_index])) |id| try putKeyIndex(scratch, &index_by_lifecycle_id, id, last_index);
                continue;
            }
        }

        try result.append(scratch, block);
        if (lifecycleId(block)) |id| try putKeyIndex(scratch, &index_by_lifecycle_id, id, result.items.len - 1);
    }

    return writeChatBlockArray(allocator, result.items);
}

fn chatBlockCanMergeCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    const existing = parseChatBlock(objectValue(args, "existing") orelse Value.null);
    const incoming = parseChatBlock(objectValue(args, "incoming") orelse Value.null);
    return try boolJson(allocator, canMergeAssistantStream(existing, incoming));
}

fn chatBlockHasOverlapCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    const existing = parseChatBlock(objectValue(args, "existing") orelse Value.null);
    const incoming = parseChatBlock(objectValue(args, "incoming") orelse Value.null);
    return try boolJson(allocator, hasStreamingContentOverlap(existing.content, incoming.content));
}

fn chatBlockMergeCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const existing = parseChatBlock(objectValue(args, "existing") orelse Value.null);
    const incoming = parseChatBlock(objectValue(args, "incoming") orelse Value.null);
    const merged = try mergeChatBlocks(scratch, existing, incoming);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeChatBlock(&out.writer, merged);
    return out.toOwnedSlice();
}

fn mergedStreamingContentCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    const existing = stringArg(args, "existing") orelse "";
    const incoming = stringArg(args, "incoming") orelse "";
    const existing_timestamp_ms = intArg(args, "existingTimestampMs");
    const incoming_timestamp_ms = intArg(args, "incomingTimestampMs");
    const merged = try mergedStreamingContent(allocator, existing, incoming, existing_timestamp_ms, incoming_timestamp_ms);
    defer allocator.free(merged);
    return try jsonStringAlloc(allocator, merged);
}

fn sseFilteredCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const event = stringArg(args, "event");
    const data = stringArg(args, "data") orelse "";
    const expected_run_id = try normalizedRunIdAlloc(scratch, stringArg(args, "expectedRunId"));
    const event_run_id = try normalizedRunIdAlloc(scratch, stringArg(args, "eventRunId"));
    const payload_run_id = try extractRunIdFromData(scratch, data);
    const require_attributed = boolArg(args, "requireAttributedRunId") orelse false;

    if (event_run_id != null and payload_run_id != null and !std.mem.eql(u8, event_run_id.?, payload_run_id.?)) {
        return try allocator.dupe(u8, "null");
    }

    const resolved_run_id = event_run_id orelse payload_run_id;
    if (require_attributed and expected_run_id != null and resolved_run_id == null) {
        return try allocator.dupe(u8, "null");
    }
    if (!runIdMatches(resolved_run_id, expected_run_id)) return try allocator.dupe(u8, "null");

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"event\":");
    try writeNullableString(&out.writer, event);
    try out.writer.print(",\"data\":{f},\"runId\":", .{std.json.fmt(data, .{})});
    try writeNullableString(&out.writer, resolved_run_id orelse expected_run_id);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn sseExtractRunIdCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const run_id = try extractRunIdFromData(arena.allocator(), stringArg(args, "data") orelse "");
    if (run_id) |id| return try jsonStringAlloc(allocator, id);
    return try allocator.dupe(u8, "null");
}

fn sseRunIdMatchesCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const actual = try normalizedRunIdAlloc(scratch, stringArg(args, "actualRunId"));
    const expected = try normalizedRunIdAlloc(scratch, stringArg(args, "expectedRunId"));
    return try boolJson(allocator, runIdMatches(actual, expected));
}

fn sseNormalizedRunIdCall(allocator: std.mem.Allocator, args: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (try normalizedRunIdAlloc(arena.allocator(), stringArg(args, "runId"))) |run_id| {
        return try jsonStringAlloc(allocator, run_id);
    }
    return try allocator.dupe(u8, "null");
}

fn putNameMap(allocator: std.mem.Allocator, map: *std.ArrayList(NameMap), key: []const u8, name: []const u8) !void {
    for (map.items) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            entry.name = name;
            return;
        }
    }
    try map.append(allocator, .{ .key = key, .name = name });
}

fn scorerGroupKey(allocator: std.mem.Allocator, score: ScoreInput, names_by_id: []const NameMap) ![]const u8 {
    if (normalized(score.scorer_name)) |name| return try lowerAlloc(allocator, name);
    const scorer_id = normalized(score.scorer_id) orelse return "unknown";
    if (findNameMap(names_by_id, scorer_id)) |name| return try lowerAlloc(allocator, name);
    return try lowerAlloc(allocator, scorer_id);
}

fn scorerGroupDisplayName(score: ScoreInput, names_by_id: []const NameMap) []const u8 {
    if (normalized(score.scorer_name)) |name| return name;
    if (normalized(score.scorer_id)) |scorer_id| {
        if (findNameMap(names_by_id, scorer_id)) |name| return name;
        return scorer_id;
    }
    return "Unknown";
}

fn findNameMap(names_by_id: []const NameMap, scorer_id: []const u8) ?[]const u8 {
    var key_buf: [256]u8 = undefined;
    const len = @min(scorer_id.len, key_buf.len);
    for (scorer_id[0..len], 0..) |c, idx| key_buf[idx] = std.ascii.toLower(c);
    const key = key_buf[0..len];
    for (names_by_id) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.name;
    }
    return null;
}

fn findGroup(groups: []const ScoreGroup, key: []const u8) ?usize {
    for (groups, 0..) |group, idx| {
        if (std.mem.eql(u8, group.key, key)) return idx;
    }
    return null;
}

fn scoreGroupLess(_: void, lhs: ScoreGroup, rhs: ScoreGroup) bool {
    return asciiLessIgnoreCase(lhs.display_name, rhs.display_name);
}

fn aggregateValues(allocator: std.mem.Allocator, values: []const f64) !struct { mean: f64, min: f64, max: f64, p50: f64 } {
    const sorted = try allocator.dupe(f64, values);
    std.mem.sort(f64, sorted, {}, struct {
        fn lessThan(_: void, lhs: f64, rhs: f64) bool {
            return lhs < rhs;
        }
    }.lessThan);

    var sum: f64 = 0;
    for (values) |value| sum += value;
    const middle = sorted.len / 2;
    const p50 = if (sorted.len % 2 == 0)
        (sorted[middle - 1] + sorted[middle]) / 2.0
    else
        sorted[middle];
    return .{
        .mean = sum / @as(f64, @floatFromInt(values.len)),
        .min = sorted[0],
        .max = sorted[sorted.len - 1],
        .p50 = p50,
    };
}

fn parseChatBlock(value: Value) ChatBlock {
    return .{
        .id = objectString(value, "id"),
        .item_id = objectString(value, "itemId") orelse objectString(value, "item_id"),
        .run_id = objectString(value, "runId") orelse objectString(value, "run_id"),
        .node_id = objectString(value, "nodeId") orelse objectString(value, "node_id"),
        .attempt = objectInt(value, "attempt"),
        .role = objectString(value, "role") orelse "",
        .content = objectString(value, "content") orelse "",
        .timestamp_ms = objectInt(value, "timestampMs") orelse objectInt(value, "timestamp_ms"),
    };
}

fn lifecycleId(block: ChatBlock) ?[]const u8 {
    if (normalized(block.item_id)) |item_id| return item_id;
    if (normalized(block.id)) |id| return id;
    return null;
}

fn attemptIndex(block: ChatBlock) i64 {
    return @max(0, block.attempt orelse 0);
}

fn isAssistantLike(block: ChatBlock) bool {
    const role = normalized(block.role) orelse "";
    return std.ascii.eqlIgnoreCase(role, "assistant") or std.ascii.eqlIgnoreCase(role, "agent");
}

fn canMergeAssistantStream(existing: ChatBlock, incoming: ChatBlock) bool {
    if (!isAssistantLike(existing) or !isAssistantLike(incoming)) return false;
    if (attemptIndex(existing) != attemptIndex(incoming)) return false;
    if (!compatibleIdentifier(existing.run_id, incoming.run_id)) return false;
    if (!compatibleIdentifier(existing.node_id, incoming.node_id)) return false;
    return true;
}

fn hasStreamingContentOverlap(existing: []const u8, incoming: []const u8) bool {
    if (existing.len == 0 or incoming.len == 0) return false;
    if (std.mem.eql(u8, existing, incoming)) return true;
    if (std.mem.startsWith(u8, existing, incoming) or std.mem.startsWith(u8, incoming, existing)) return true;
    if (std.mem.indexOf(u8, existing, incoming) != null or std.mem.indexOf(u8, incoming, existing) != null) return true;
    if (mergeUsingInferredOffsetRange(existing, incoming) != null) return true;
    return suffixPrefixOverlap(existing, incoming) > 0 or suffixPrefixOverlap(incoming, existing) > 0;
}

fn mergeChatBlocks(allocator: std.mem.Allocator, existing: ChatBlock, incoming: ChatBlock) !ChatBlock {
    const should_merge_content = hasStreamingContentOverlap(existing.content, incoming.content) or
        (existing.timestamp_ms != null and incoming.timestamp_ms != null);
    const merged_content = if (should_merge_content)
        try mergedStreamingContent(allocator, existing.content, incoming.content, existing.timestamp_ms, incoming.timestamp_ms)
    else
        incoming.content;
    return .{
        .id = incoming.id orelse existing.id,
        .item_id = incoming.item_id orelse existing.item_id,
        .run_id = incoming.run_id orelse existing.run_id,
        .node_id = incoming.node_id orelse existing.node_id,
        .attempt = incoming.attempt orelse existing.attempt,
        .role = incoming.role,
        .content = merged_content,
        .timestamp_ms = incoming.timestamp_ms orelse existing.timestamp_ms,
    };
}

fn mergedStreamingContent(
    allocator: std.mem.Allocator,
    existing: []const u8,
    incoming: []const u8,
    existing_timestamp_ms: ?i64,
    incoming_timestamp_ms: ?i64,
) ![]u8 {
    if (existing.len == 0) return try allocator.dupe(u8, incoming);
    if (incoming.len == 0) return try allocator.dupe(u8, existing);
    if (std.mem.eql(u8, existing, incoming)) return try allocator.dupe(u8, existing);
    if (std.mem.startsWith(u8, incoming, existing)) {
        const continuation = incoming[existing.len..];
        if (try collapsedRetransmittedContinuation(allocator, existing, continuation)) |collapsed| return collapsed;
        return try allocator.dupe(u8, incoming);
    }
    if (std.mem.startsWith(u8, existing, incoming)) return try allocator.dupe(u8, existing);
    if (std.mem.indexOf(u8, existing, incoming) != null) return try allocator.dupe(u8, existing);
    if (std.mem.indexOf(u8, incoming, existing) != null) return try allocator.dupe(u8, incoming);

    const forward_overlap = suffixPrefixOverlap(existing, incoming);
    const reverse_overlap = suffixPrefixOverlap(incoming, existing);
    if (forward_overlap > 0 or reverse_overlap > 0) {
        if (reverse_overlap > forward_overlap) return try concat(allocator, incoming, existing[reverse_overlap..]);
        return try concat(allocator, existing, incoming[forward_overlap..]);
    }

    if (try mergeUsingInferredOffset(allocator, existing, incoming)) |merged| return merged;

    if (existing_timestamp_ms != null and incoming_timestamp_ms != null and incoming_timestamp_ms.? < existing_timestamp_ms.?) {
        return try concat(allocator, incoming, existing);
    }
    return try concat(allocator, existing, incoming);
}

fn collapsedRetransmittedContinuation(allocator: std.mem.Allocator, existing: []const u8, continuation: []const u8) !?[]u8 {
    if (continuation.len == 0) return try allocator.dupe(u8, existing);
    const overlap = suffixPrefixOverlap(existing, continuation);
    if (overlap < minimumReliableOverlapLength(existing, continuation)) return null;
    return try concat(allocator, existing, continuation[overlap..]);
}

fn mergeUsingInferredOffset(allocator: std.mem.Allocator, existing: []const u8, incoming: []const u8) !?[]u8 {
    const range = mergeUsingInferredOffsetRange(existing, incoming) orelse return null;
    return try concat(allocator, existing[0..range.existing_end], incoming[range.incoming_offset..]);
}

fn mergeUsingInferredOffsetRange(existing: []const u8, incoming: []const u8) ?struct { existing_end: usize, incoming_offset: usize } {
    const max_length = @min(existing.len, incoming.len);
    const minimum_length = minimumReliableOverlapLength(existing, incoming);
    if (minimum_length == 0 or max_length < minimum_length) return null;

    var length = max_length;
    while (length >= minimum_length) : (length -= 1) {
        const prefix = incoming[0..length];
        const match = lastIndexOf(existing, prefix) orelse {
            if (length == minimum_length) break;
            continue;
        };
        if (match + length < existing.len) {
            return .{ .existing_end = match + length, .incoming_offset = length };
        }
        if (length == minimum_length) break;
    }
    return null;
}

fn minimumReliableOverlapLength(existing: []const u8, incoming: []const u8) usize {
    const shortest = @min(existing.len, incoming.len);
    if (shortest < 6) return 0;
    return @min(24, @max(6, shortest / 3));
}

fn suffixPrefixOverlap(lhs: []const u8, rhs: []const u8) usize {
    const max_length = @min(lhs.len, rhs.len);
    if (max_length == 0) return 0;
    var length = max_length;
    while (length > 0) : (length -= 1) {
        if (std.mem.eql(u8, lhs[lhs.len - length ..], rhs[0..length])) return length;
    }
    return 0;
}

fn compatibleIdentifier(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    const lhs_value = normalized(lhs) orelse return true;
    const rhs_value = normalized(rhs) orelse return true;
    return std.mem.eql(u8, lhs_value, rhs_value);
}

fn extractRunIdFromData(allocator: std.mem.Allocator, data: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, data, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    const parsed = std.json.parseFromSlice(Value, allocator, trimmed, .{}) catch return null;
    return try extractRunIdFromValue(allocator, parsed.value);
}

fn extractRunIdFromValue(allocator: std.mem.Allocator, value: Value) !?[]const u8 {
    switch (value) {
        .object => |object| {
            const direct_keys = [_][]const u8{ "runId", "run_id", "workflowRunId", "workflow_run_id" };
            for (direct_keys) |key| {
                if (try normalizedRunIdValue(allocator, object.get(key))) |run_id| return run_id;
            }

            const preferred_keys = [_][]const u8{ "event", "data", "block", "payload", "message" };
            for (preferred_keys) |key| {
                if (object.get(key)) |nested| {
                    if (try extractRunIdFromValue(allocator, nested)) |run_id| return run_id;
                }
            }

            var it = object.iterator();
            while (it.next()) |entry| {
                if (isPreferredRunIdNestedKey(entry.key_ptr.*)) continue;
                if (try extractRunIdFromValue(allocator, entry.value_ptr.*)) |run_id| return run_id;
            }
        },
        .array => |array| {
            for (array.items) |nested| {
                if (try extractRunIdFromValue(allocator, nested)) |run_id| return run_id;
            }
        },
        .string => |string| {
            const trimmed = std.mem.trim(u8, string, &std.ascii.whitespace);
            if (trimmed.len == 0 or (trimmed[0] != '{' and trimmed[0] != '[')) return null;
            const parsed = std.json.parseFromSlice(Value, allocator, trimmed, .{}) catch return null;
            return try extractRunIdFromValue(allocator, parsed.value);
        },
        else => {},
    }
    return null;
}

fn normalizedRunIdValue(allocator: std.mem.Allocator, value: ?Value) !?[]const u8 {
    const found = value orelse return null;
    switch (found) {
        .string => |string| return normalizedRunIdAlloc(allocator, string),
        .integer => |integer| return normalizedRunIdAlloc(allocator, try std.fmt.allocPrint(allocator, "{}", .{integer})),
        .float => |float| return normalizedRunIdAlloc(allocator, try std.fmt.allocPrint(allocator, "{d}", .{float})),
        .number_string => |string| return normalizedRunIdAlloc(allocator, string),
        else => return null,
    }
}

fn normalizedRunIdAlloc(allocator: std.mem.Allocator, run_id: ?[]const u8) !?[]const u8 {
    const value = normalized(run_id) orelse return null;
    return try allocator.dupe(u8, value);
}

fn runIdMatches(actual_run_id: ?[]const u8, expected_run_id: ?[]const u8) bool {
    const expected = expected_run_id orelse return true;
    const actual = actual_run_id orelse return true;
    return std.mem.eql(u8, actual, expected);
}

fn isPreferredRunIdNestedKey(key: []const u8) bool {
    const preferred_keys = [_][]const u8{ "event", "data", "block", "payload", "message" };
    for (preferred_keys) |preferred| {
        if (std.mem.eql(u8, key, preferred)) return true;
    }
    return false;
}

fn writeChatBlockArray(allocator: std.mem.Allocator, blocks: []const ChatBlock) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (blocks, 0..) |block, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        try writeChatBlock(&out.writer, block);
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn writeChatBlock(writer: *std.Io.Writer, block: ChatBlock) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"id\":");
    try writeNullableString(writer, block.id);
    try writer.writeAll(",\"itemId\":");
    try writeNullableString(writer, block.item_id);
    try writer.writeAll(",\"runId\":");
    try writeNullableString(writer, block.run_id);
    try writer.writeAll(",\"nodeId\":");
    try writeNullableString(writer, block.node_id);
    try writer.writeAll(",\"attempt\":");
    if (block.attempt) |attempt| {
        try writer.print("{}", .{attempt});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"role\":{f},\"content\":{f},\"timestampMs\":", .{
        std.json.fmt(block.role, .{}),
        std.json.fmt(block.content, .{}),
    });
    if (block.timestamp_ms) |timestamp| {
        try writer.print("{}", .{timestamp});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn writeIndexArray(allocator: std.mem.Allocator, indexes: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (indexes, 0..) |index, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        try out.writer.print("{}", .{index});
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn writeNullableString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try writer.print("{f}", .{std.json.fmt(text, .{})});
    } else {
        try writer.writeAll("null");
    }
}

fn boolJson(allocator: std.mem.Allocator, value: bool) ![]u8 {
    return try allocator.dupe(u8, if (value) "true" else "false");
}

fn jsonStringAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(text, .{})});
}

fn putKeyIndex(allocator: std.mem.Allocator, indexes: *std.ArrayList(KeyIndex), key: []const u8, index: usize) !void {
    for (indexes.items) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            entry.index = index;
            return;
        }
    }
    try indexes.append(allocator, .{ .key = key, .index = index });
}

fn findKeyIndex(indexes: []const KeyIndex, key: []const u8) ?usize {
    for (indexes) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.index;
    }
    return null;
}

fn firstNonEmpty(values: []const ?[]const u8) ?[]const u8 {
    for (values) |value| {
        if (normalized(value)) |text| return text;
    }
    return null;
}

fn normalized(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

fn lowerAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, value);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn asciiLessIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    const min_len = @min(lhs.len, rhs.len);
    for (0..min_len) |idx| {
        const l = std.ascii.toLower(lhs[idx]);
        const r = std.ascii.toLower(rhs[idx]);
        if (l < r) return true;
        if (l > r) return false;
    }
    return lhs.len < rhs.len;
}

fn concat(allocator: std.mem.Allocator, lhs: []const u8, rhs: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, lhs.len + rhs.len);
    @memcpy(out[0..lhs.len], lhs);
    @memcpy(out[lhs.len..], rhs);
    return out;
}

fn lastIndexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var idx = haystack.len - needle.len + 1;
    while (idx > 0) {
        idx -= 1;
        if (std.mem.eql(u8, haystack[idx .. idx + needle.len], needle)) return idx;
    }
    return null;
}

fn arrayArg(value: Value, key: []const u8) ?[]Value {
    const found = objectValue(value, key) orelse return null;
    return if (found == .array) found.array.items else null;
}

fn boolArg(value: Value, key: []const u8) ?bool {
    const found = objectValue(value, key) orelse return null;
    return if (found == .bool) found.bool else null;
}

fn stringArg(value: Value, key: []const u8) ?[]const u8 {
    return objectString(value, key);
}

fn intArg(value: Value, key: []const u8) ?i64 {
    return objectInt(value, key);
}

fn objectValue(value: Value, key: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn objectString(value: Value, key: []const u8) ?[]const u8 {
    const found = objectValue(value, key) orelse return null;
    return if (found == .string) found.string else null;
}

fn objectInt(value: Value, key: []const u8) ?i64 {
    const found = objectValue(value, key) orelse return null;
    return intValue(found);
}

fn objectFloat(value: Value, key: []const u8) ?f64 {
    const found = objectValue(value, key) orelse return null;
    return floatValue(found);
}

fn intValue(value: Value) ?i64 {
    return switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn floatValue(value: Value) ?f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

test "models aggregates scores by scorer identity" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Value, allocator,
        \\{"scores":[
        \\{"scorerId":"quality-v1","scorerName":"Quality","score":0.8},
        \\{"scorerId":"quality-v2","scorerName":"Quality","score":1.0},
        \\{"scorerId":"lint","scorerName":"Lint","score":0.5},
        \\{"scorerId":"lint","scorerName":"Lint","score":0.7}
        \\]}
    , .{});
    defer parsed.deinit();

    const result = try aggregateScoresCall(allocator, parsed.value);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"scorerName\":\"Lint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"mean\":6e-1") != null or std.mem.indexOf(u8, result, "\"mean\":0.6") != null);
}

test "models merges chat stream overlap" {
    const allocator = std.testing.allocator;
    const merged = try mergedStreamingContent(allocator, "Hello wor", "world", null, null);
    defer allocator.free(merged);
    try std.testing.expectEqualStrings("Hello world", merged);
}

test "models extracts nested SSE run id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_id = try extractRunIdFromData(arena.allocator(), "{\"payload\":{\"run_id\":\"run-1\"}}");
    try std.testing.expectEqualStrings("run-1", run_id.?);
}
