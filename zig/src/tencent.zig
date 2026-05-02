const std = @import("std");
const eastmoney = @import("eastmoney.zig");

pub const TencentStockInfo = struct {
    symbol: []const u8,
    name: []const u8,
    price: f64,
    change_pct: ?f64 = null,
    market_cap: ?f64 = null,
    float_market_cap: ?f64 = null,
    total_shares: ?f64 = null,
    float_shares: ?f64 = null,
    open: f64 = 0,
    prev_close: f64 = 0,
    high: f64 = 0,
    low: f64 = 0,
    volume: f64 = 0,

    pub fn deinit(self: *TencentStockInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Convert GBK-encoded bytes to UTF-8 using system iconv command
fn gbkToUtf8(allocator: std.mem.Allocator, gbk: []const u8) ![]u8 {
    return eastmoney.gbkToUtf8(allocator, gbk);
}

// Tencent stock API: http://qt.gtimg.cn/q=sh600519
pub fn getStockInfo(allocator: std.mem.Allocator, symbol: []const u8) !TencentStockInfo {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prefix = if (symbol[0] == '6' or symbol[0] == '5') "sh" else "sz";

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://qt.gtimg.cn/q={s}{s}", .{ prefix, symbol });

    const response = try eastmoney.httpGet(arena.allocator(), url);

    const start = std.mem.indexOf(u8, response, "\"") orelse return error.ParseError;
    const end = std.mem.lastIndexOfLinear(u8, response, "\"") orelse return error.ParseError;
    if (start >= end) return error.ParseError;

    const data = response[start + 1 .. end];

    var parts = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer parts.deinit(allocator);

    var iter = std.mem.splitSequence(u8, data, "~");
    while (iter.next()) |part| {
        try parts.append(allocator, part);
    }

    if (parts.items.len < 50) return error.ParseError;

    const p = parts.items;

    // Convert GBK-encoded name to UTF-8
    const name_utf8 = try gbkToUtf8(allocator, p[1]);

    const price = std.fmt.parseFloat(f64, p[3]) catch 0;
    const open = std.fmt.parseFloat(f64, p[5]) catch 0;
    const prev_close = std.fmt.parseFloat(f64, p[4]) catch 0;
    const high = std.fmt.parseFloat(f64, p[11]) catch 0;
    const low = std.fmt.parseFloat(f64, p[12]) catch 0;
    const volume = std.fmt.parseFloat(f64, p[6]) catch 0;

    var result = TencentStockInfo{
        .symbol = symbol,
        .name = name_utf8,
        .price = price,
        .change_pct = if (prev_close != 0) (price - prev_close) / prev_close * 100.0 else null,
        .open = open,
        .prev_close = prev_close,
        .high = high,
        .low = low,
        .volume = volume,
    };

    if (p.len > 45) {
        result.market_cap = std.fmt.parseFloat(f64, p[45]) catch null;
        if (result.market_cap) |cap| {
            result.market_cap = cap * 1e8;
        }
    }

    if (p.len > 44) {
        result.float_market_cap = std.fmt.parseFloat(f64, p[44]) catch null;
        if (result.float_market_cap) |cap| {
            result.float_market_cap = cap * 1e8;
        }
    }

    if (p.len > 73 and p[73].len > 0) {
        result.total_shares = std.fmt.parseFloat(f64, p[73]) catch null;
    }
    if (p.len > 72 and p[72].len > 0) {
        result.float_shares = std.fmt.parseFloat(f64, p[72]) catch null;
    }

    return result;
}

/// Tencent adjusted daily K-line fallback.
/// The endpoint reliably returns recent bars, but caps long ranges; use it as
/// a degradation path when EastMoney/Sina-style history is unavailable.
pub fn getDailyK(allocator: std.mem.Allocator, symbol: []const u8, days: u16) !eastmoney.KlineResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const prefix = if (symbol[0] == '6' or symbol[0] == '5' or symbol[0] == '8' or symbol[0] == '4') "sh" else "sz";
    const limit: u16 = @intCast(@min(@as(usize, if (days > 0) days else 500), 800));
    const key = try std.fmt.allocPrint(arena.allocator(), "{s}{s}", .{ prefix, symbol });
    const url = try std.fmt.allocPrint(
        arena.allocator(),
        "http://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param={s},day,,,{d},qfq",
        .{ key, limit },
    );

    const response = try eastmoney.httpGet(arena.allocator(), url);
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});

    const data_val = parsed.object.get("data") orelse return eastmoney.KlineResult{ .items = &.{}, .err_msg = "no data" };
    if (data_val != .object) return eastmoney.KlineResult{ .items = &.{}, .err_msg = "no data" };
    const stock_val = data_val.object.get(key) orelse return eastmoney.KlineResult{ .items = &.{}, .err_msg = "no symbol data" };
    if (stock_val != .object) return eastmoney.KlineResult{ .items = &.{}, .err_msg = "no symbol data" };
    const day_val = stock_val.object.get("qfqday") orelse stock_val.object.get("day") orelse return eastmoney.KlineResult{ .items = &.{}, .err_msg = "no kline data" };
    if (day_val != .array) return eastmoney.KlineResult{ .items = &.{}, .err_msg = "no kline data" };

    var items = std.ArrayList(eastmoney.KlineItem){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);
    errdefer {
        for (items.items) |item| allocator.free(item.date);
    }

    var prev_close: ?f64 = null;
    for (day_val.array.items) |row_val| {
        if (row_val != .array or row_val.array.items.len < 6) continue;
        const row = row_val.array.items;
        if (row[0] != .string) continue;

        const open = valueToF64(row[1]) orelse continue;
        const close = valueToF64(row[2]) orelse continue;
        const high = valueToF64(row[3]) orelse continue;
        const low = valueToF64(row[4]) orelse continue;
        const volume = valueToF64(row[5]) orelse 0;
        const change_pct = if (prev_close) |prev|
            if (prev != 0) (close - prev) / prev * 100.0 else null
        else
            null;
        prev_close = close;

        try items.append(allocator, eastmoney.KlineItem{
            .date = try allocator.dupe(u8, row[0].string),
            .open = open,
            .close = close,
            .high = high,
            .low = low,
            .volume = volume,
            .amount = null,
            .change_pct = change_pct,
        });
    }

    return eastmoney.KlineResult{ .items = try items.toOwnedSlice(allocator) };
}

fn valueToF64(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        .string => |v| std.fmt.parseFloat(f64, v) catch null,
        else => null,
    };
}
