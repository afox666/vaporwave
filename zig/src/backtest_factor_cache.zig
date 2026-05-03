const std = @import("std");
const duckdb = @import("duckdb.zig");
const config = @import("backtest_config.zig");

const Factor = config.Factor;
const parseFactor = config.parseFactor;
const factorName = config.factorName;

pub const VERSION = "zig-factor-v1";
const SOURCE = "zig";

pub const Stats = struct {
    enabled: bool = false,
    requested: usize = 0,
    cacheable: usize = 0,
    hits: usize = 0,
    misses: usize = 0,
    unavailable: usize = 0,
    writes: usize = 0,
    hit_rate: f64 = 0,
};

pub const Cache = struct {
    values: std.StringHashMap(f64),
    stats: Stats,

    pub fn init(allocator: std.mem.Allocator, stats: Stats) Cache {
        return Cache{
            .values = std.StringHashMap(f64).init(allocator),
            .stats = stats,
        };
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        var it = self.values.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        self.values.deinit();
    }
};

pub const Record = struct {
    symbol: []const u8,
    date: []const u8,
    factor: Factor,
    value: f64,
};

fn stringListSql(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    for (values, 0..) |value, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        const part = try std.fmt.allocPrint(allocator, "'{s}'", .{value});
        defer allocator.free(part);
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

fn factorListSql(allocator: std.mem.Allocator, factors: []const Factor) ![]u8 {
    var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    for (factors, 0..) |factor, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        const part = try std.fmt.allocPrint(allocator, "'{s}'", .{factorName(factor)});
        defer allocator.free(part);
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

pub fn keyBuf(buf: []u8, symbol: []const u8, date: []const u8, factor: Factor) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{s}|{s}|{s}", .{ symbol, date, factorName(factor) });
}

pub fn load(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    symbols: []const []const u8,
    dates: []const []const u8,
    factors: []const Factor,
) !Cache {
    const stats = Stats{
        .enabled = true,
        .requested = symbols.len * dates.len * factors.len,
        .misses = symbols.len * dates.len * factors.len,
        .unavailable = symbols.len * dates.len * factors.len,
    };
    var cache = Cache.init(allocator, stats);
    errdefer cache.deinit(allocator);
    if (stats.requested == 0) return cache;

    const symbol_sql = try stringListSql(allocator, symbols);
    defer allocator.free(symbol_sql);
    const date_sql = try stringListSql(allocator, dates);
    defer allocator.free(date_sql);
    const factor_sql = try factorListSql(allocator, factors);
    defer allocator.free(factor_sql);

    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT symbol, CAST(date AS VARCHAR) AS date, factor_name, factor_value
        \\FROM factor_daily
        \\WHERE symbol IN ({s})
        \\  AND date IN ({s})
        \\  AND factor_name IN ({s})
        \\  AND calc_version = '{s}'
        \\  AND factor_value IS NOT NULL
    , .{ symbol_sql, date_sql, factor_sql, VERSION });
    defer allocator.free(sql);

    var rows = db.queryRows(allocator, sql) catch |err| {
        std.debug.print("Factor cache read failed: {any}\n", .{err});
        cache.stats.enabled = false;
        return cache;
    };
    defer rows.deinit(allocator);

    var i: usize = 0;
    while (i < rows.rows.items.len) : (i += 1) {
        const symbol = rows.getStr(i, "symbol") orelse continue;
        const date = rows.getStr(i, "date") orelse continue;
        const factor_name = rows.getStr(i, "factor_name") orelse continue;
        const factor = parseFactor(factor_name) orelse continue;
        const value = rows.getF64(i, "factor_value") orelse continue;
        if (!std.math.isFinite(value)) continue;
        const key = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ symbol, date[0..@min(date.len, 10)], factorName(factor) });
        try cache.values.put(key, value);
    }
    cache.stats.hits = cache.values.count();
    cache.stats.misses = if (cache.stats.requested > cache.stats.hits) cache.stats.requested - cache.stats.hits else 0;
    cache.stats.cacheable = cache.stats.hits;
    cache.stats.unavailable = cache.stats.misses;
    cache.stats.hit_rate = if (cache.stats.cacheable > 0)
        @as(f64, @floatFromInt(cache.stats.hits)) / @as(f64, @floatFromInt(cache.stats.cacheable))
    else
        0;
    return cache;
}

pub fn upsert(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    records: []const Record,
) !usize {
    if (records.len == 0) return 0;
    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("INSERT OR REPLACE INTO factor_daily (symbol, date, factor_name, factor_value, calc_version, source, updated_at) VALUES ");
    for (records, 0..) |record, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.print("('{s}', CAST('{s}' AS DATE), '{s}', {d}, '{s}', '{s}', CURRENT_TIMESTAMP)", .{
            record.symbol,
            record.date,
            factorName(record.factor),
            record.value,
            VERSION,
            SOURCE,
        });
    }
    db.exec(out.written()) catch |err| {
        std.debug.print("Factor cache write failed: {any}\n", .{err});
        return 0;
    };
    return records.len;
}
