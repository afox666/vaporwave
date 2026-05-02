const std = @import("std");

pub const PersistedFile = struct {
    name: []const u8,
    mtime: i128,
};

pub fn newer(_: void, a: PersistedFile, b: PersistedFile) bool {
    return a.mtime > b.mtime;
}

pub fn storeDir(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.backtest_tasks/zig", .{workspace_dir});
}

pub fn storePath(allocator: std.mem.Allocator, workspace_dir: []const u8, task_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.backtest_tasks/zig/{s}.json", .{ workspace_dir, task_id });
}

pub fn writeJson(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    task_id: []const u8,
    body: []const u8,
) void {
    const dir = storeDir(allocator, workspace_dir) catch return;
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch |err| {
        std.debug.print("Backtest task store mkdir failed: {any}\n", .{err});
        return;
    };

    const path = storePath(allocator, workspace_dir, task_id) catch return;
    defer allocator.free(path);
    const tmp_path = std.fmt.allocPrint(allocator, "{s}.tmp", .{path}) catch return;
    defer allocator.free(tmp_path);

    std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = body }) catch |err| {
        std.debug.print("Backtest task store write failed: {any}\n", .{err});
        return;
    };
    std.fs.cwd().rename(tmp_path, path) catch |err| {
        std.debug.print("Backtest task store rename failed: {any}\n", .{err});
    };
}

fn jsonStringField(json: []const u8, field: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, json, search_from, field)) |idx| {
        search_from = idx + field.len;
        if (idx == 0 or json[idx - 1] != '"') continue;
        if (idx + field.len >= json.len or json[idx + field.len] != '"') continue;

        var pos = idx + field.len + 1;
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\n' or json[pos] == '\r')) : (pos += 1) {}
        if (pos >= json.len or json[pos] != ':') continue;
        pos += 1;
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t' or json[pos] == '\n' or json[pos] == '\r')) : (pos += 1) {}
        if (pos >= json.len or json[pos] != '"') continue;
        pos += 1;

        const value_start = pos;
        var escaped = false;
        while (pos < json.len) : (pos += 1) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (json[pos] == '\\') {
                escaped = true;
                continue;
            }
            if (json[pos] == '"') return json[value_start..pos];
        }
    }
    return null;
}

fn isNonTerminal(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, "\"status\":\"queued\"") != null or
        std.mem.indexOf(u8, raw, "\"status\":\"running\"") != null or
        std.mem.indexOf(u8, raw, "\"status\":\"cancelling\"") != null;
}

fn allocTaskTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()});
}

fn interruptedJson(
    allocator: std.mem.Allocator,
    raw: []const u8,
    fallback_task_id: []const u8,
    running_count: usize,
    max_concurrent: usize,
) ![]u8 {
    const task_id = jsonStringField(raw, "task_id") orelse fallback_task_id;
    const created_at = jsonStringField(raw, "created_at") orelse "";
    const cache_key = jsonStringField(raw, "cache_key") orelse "";
    const updated_at = try allocTaskTimestamp(allocator);
    defer allocator.free(updated_at);

    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginObject();
    try s.objectField("task_id");
    try s.write(task_id);
    try s.objectField("status");
    try s.write("failed");
    try s.objectField("progress");
    try s.write(@as(f64, 0.0));
    try s.objectField("stage");
    try s.write("interrupted");
    try s.objectField("message");
    try s.write("服务重启，任务已中断");
    try s.objectField("created_at");
    try s.write(created_at);
    try s.objectField("updated_at");
    try s.write(updated_at);
    try s.objectField("cache_key");
    try s.write(cache_key);
    try s.objectField("cache_hit");
    try s.write(false);
    try s.objectField("queue_position");
    try s.write(@as(usize, 0));
    try s.objectField("running_count");
    try s.write(running_count);
    try s.objectField("max_concurrent");
    try s.write(max_concurrent);
    try s.objectField("error");
    try s.write("服务重启，任务已中断");
    try s.endObject();
    return out.toOwnedSlice();
}

pub fn loadJson(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    task_id: []const u8,
    running_count: usize,
    max_concurrent: usize,
) !?[]u8 {
    const path = try storePath(allocator, workspace_dir, task_id);
    defer allocator.free(path);
    const raw = std.fs.cwd().readFileAlloc(allocator, path, 20 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    if (!isNonTerminal(raw)) return raw;

    const interrupted = try interruptedJson(allocator, raw, task_id, running_count, max_concurrent);
    writeJson(allocator, workspace_dir, task_id, interrupted);
    allocator.free(raw);
    return interrupted;
}
