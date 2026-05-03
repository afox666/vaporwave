const std = @import("std");
const duckdb = @import("duckdb.zig");

const RESULT_CACHE_VERSION = "zig-result-v1";

fn sha256Hex(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const out = try allocator.alloc(u8, 24);
    @memcpy(out, hex[0..24]);
    return out;
}

fn queryDataFingerprint(allocator: std.mem.Allocator, db: ?*duckdb.Db) ![]const u8 {
    const d = db orelse return try allocator.dupe(u8, "daily_k:no-db");
    var rows = d.queryRows(
        allocator,
        "SELECT COUNT(*) AS cnt, COALESCE(CAST(MAX(date) AS VARCHAR), '') AS max_date, COALESCE(CAST(MAX(updated_at) AS VARCHAR), '') AS max_updated FROM daily_k",
    ) catch {
        return try allocator.dupe(u8, "daily_k:unknown");
    };
    defer rows.deinit(allocator);
    const cnt = rows.getStr(0, "cnt") orelse "0";
    const max_date = rows.getStr(0, "max_date") orelse "";
    const max_updated = rows.getStr(0, "max_updated") orelse "";
    return std.fmt.allocPrint(allocator, "daily_k:{s}:{s}:{s}", .{ cnt, max_date, max_updated });
}

pub fn makeKey(
    allocator: std.mem.Allocator,
    body: []const u8,
    db: ?*duckdb.Db,
) ![]const u8 {
    const fingerprint = try queryDataFingerprint(allocator, db);
    defer allocator.free(fingerprint);
    var raw = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer raw.deinit(allocator);
    try raw.appendSlice(allocator, RESULT_CACHE_VERSION);
    try raw.append(allocator, '\n');
    try raw.appendSlice(allocator, fingerprint);
    try raw.append(allocator, '\n');
    try raw.appendSlice(allocator, std.mem.trim(u8, body, " \t\r\n"));
    return sha256Hex(allocator, raw.items);
}

fn cacheDir(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.backtest_result_cache/zig", .{workspace_dir});
}

fn cachePath(allocator: std.mem.Allocator, workspace_dir: []const u8, cache_key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.backtest_result_cache/zig/{s}.json", .{ workspace_dir, cache_key });
}

pub fn load(allocator: std.mem.Allocator, workspace_dir: []const u8, cache_key: []const u8) !?[]u8 {
    const path = try cachePath(allocator, workspace_dir, cache_key);
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, 20 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => null,
        else => null,
    };
}

pub fn save(allocator: std.mem.Allocator, workspace_dir: []const u8, cache_key: []const u8, result: []const u8) void {
    const dir = cacheDir(allocator, workspace_dir) catch return;
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch |err| {
        std.debug.print("Backtest result cache mkdir failed: {any}\n", .{err});
        return;
    };
    const path = cachePath(allocator, workspace_dir, cache_key) catch return;
    defer allocator.free(path);
    const tmp_path = std.fmt.allocPrint(allocator, "{s}.tmp", .{path}) catch return;
    defer allocator.free(tmp_path);
    std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = result }) catch |err| {
        std.debug.print("Backtest result cache write failed: {any}\n", .{err});
        return;
    };
    std.fs.cwd().rename(tmp_path, path) catch |err| {
        std.debug.print("Backtest result cache rename failed: {any}\n", .{err});
    };
}
