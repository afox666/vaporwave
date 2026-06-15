const std = @import("std");

const duckdb = @import("duckdb.zig");
const eastmoney = @import("eastmoney.zig");
const tencent = @import("tencent.zig");

const UpdateTask = struct {
    symbol: []const u8,
    last_date: []const u8,
};

pub fn run(allocator: std.mem.Allocator, db: *duckdb.Db, command: []const u8, years_arg: u16, limit: usize, since_date: ?[]const u8) !void {
    const years = if (years_arg > 0) years_arg else 10;

    if (std.mem.eql(u8, command, "names")) {
        _ = try syncNames(allocator, db);
    } else if (std.mem.eql(u8, command, "stats")) {
        try showStats(allocator, db);
    } else if (std.mem.eql(u8, command, "query")) {
        try querySample(allocator, db);
    } else if (std.mem.eql(u8, command, "backfill")) {
        try syncBackfill(allocator, db, years, limit);
    } else if (std.mem.eql(u8, command, "update")) {
        try syncIncremental(allocator, db, limit);
    } else if (std.mem.eql(u8, command, "update-since")) {
        try syncSince(allocator, db, since_date orelse return error.MissingSinceDate, limit);
    } else if (std.mem.eql(u8, command, "full")) {
        try syncBackfill(allocator, db, years, limit);
    } else {
        std.debug.print(
            \\用法:
            \\  --sync names                 仅同步股票名称
            \\  --sync backfill --years 10   回填最近 N 年日K
            \\  --sync update                增量更新
            \\  --sync update-since --since YYYY-MM-DD
            \\  --sync stats                 数据库统计
            \\  --sync query                 示例查询
            \\
        , .{});
        return error.InvalidSyncCommand;
    }
}

fn syncSince(allocator: std.mem.Allocator, db: *duckdb.Db, since_date: []const u8, limit: usize) !void {
    if (!isSafeDate(since_date)) return error.InvalidSinceDate;

    std.debug.print("============================================================\n", .{});
    std.debug.print("指定日期后同步 - 更新 {s} 之后日K\n", .{since_date});
    std.debug.print("============================================================\n", .{});

    try ensureStockPool(allocator, db);

    const symbols = try symbolsNeedingSince(allocator, db, since_date);
    defer freeStringList(allocator, symbols);
    const days = try fetchDaysSince(allocator, db, since_date);

    const process_count = if (limit > 0) @min(limit, symbols.len) else symbols.len;
    std.debug.print("需处理 {d} 只股票\n", .{symbols.len});
    std.debug.print("拉取最近 {d} 天日K\n", .{days});
    if (limit > 0) {
        std.debug.print("本次限制处理: {d} 只\n", .{process_count});
    }

    var total_rows: usize = 0;
    var success_count: usize = 0;
    var fail_count: usize = 0;

    for (symbols[0..process_count], 0..) |symbol, idx| {
        const written = syncSymbolRecent(allocator, db, symbol, days, since_date) catch |err| blk: {
            std.debug.print("  {s} 指定日期后同步失败: {any}\n", .{ symbol, err });
            break :blk 0;
        };
        if (written > 0) {
            total_rows += written;
            success_count += 1;
        } else {
            fail_count += 1;
        }

        if ((idx + 1) % 50 == 0 or idx + 1 == process_count) {
            std.debug.print("  进度: {d}/{d} | 已写入/更新 {d} 条 | 成功{d} 空数据{d}\n", .{ idx + 1, process_count, total_rows, success_count, fail_count });
        }
        if ((idx + 1) % 200 == 0) {
            std.Thread.sleep(3 * std.time.ns_per_s);
        } else {
            std.Thread.sleep(120 * std.time.ns_per_ms);
        }
    }

    std.debug.print("\n完成: 共写入/更新 {d} 条数据\n", .{total_rows});
}

fn syncNames(allocator: std.mem.Allocator, db: *duckdb.Db) !usize {
    std.debug.print("同步股票名称...\n", .{});

    var result = eastmoney.getAShareSpot(allocator, 0) catch |err| {
        const fallback = try queryCount(allocator, db,
            \\SELECT COUNT(*) AS cnt FROM (
            \\    SELECT symbol FROM stock_info WHERE length(symbol) = 6
            \\    UNION
            \\    SELECT DISTINCT symbol FROM daily_k WHERE length(symbol) = 6
            \\)
        );
        std.debug.print("  实时列表获取失败: {any}，沿用本地股票池 {d} 只\n", .{ err, fallback });
        return fallback;
    };
    defer result.deinit(allocator);

    if (result.err_msg != null or result.items.len == 0) {
        const fallback = try queryCount(allocator, db,
            \\SELECT COUNT(*) AS cnt FROM (
            \\    SELECT symbol FROM stock_info WHERE length(symbol) = 6
            \\    UNION
            \\    SELECT DISTINCT symbol FROM daily_k WHERE length(symbol) = 6
            \\)
        );
        std.debug.print("  实时列表为空，沿用本地股票池 {d} 只\n", .{fallback});
        return fallback;
    }

    try db.exec("BEGIN TRANSACTION");
    var committed = false;
    errdefer if (!committed) db.exec("ROLLBACK") catch {};

    for (result.items) |item| {
        if (!isSafeSymbol(item.symbol)) continue;
        const name = try sqlEscape(allocator, item.name);
        defer allocator.free(name);

        const query = try std.fmt.allocPrint(
            allocator,
            "INSERT OR REPLACE INTO stock_info (symbol, name, updated_at) VALUES ('{s}', '{s}', CURRENT_TIMESTAMP)",
            .{ item.symbol, name },
        );
        defer allocator.free(query);
        try db.exec(query);
    }

    try db.exec("COMMIT");
    committed = true;

    const count = try queryCount(allocator, db, "SELECT COUNT(*) AS cnt FROM stock_info");
    std.debug.print("  stock_info 已更新: {d} 只股票\n", .{count});
    return count;
}

fn syncBackfill(allocator: std.mem.Allocator, db: *duckdb.Db, years: u16, limit: usize) !void {
    std.debug.print("============================================================\n", .{});
    std.debug.print("历史回填 - 拉取全部A股最近 {d} 年日K\n", .{years});
    std.debug.print("============================================================\n", .{});

    try ensureStockPool(allocator, db);

    const latest = try latestBusinessDate(allocator, db);
    defer allocator.free(latest);
    const target_start = try targetStartDate(allocator, db, latest, years);
    defer allocator.free(target_start);

    const total_symbols = try universeCount(allocator, db);
    const pending = try pendingBackfillSymbols(allocator, db, target_start, latest);
    defer freeStringList(allocator, pending);

    const process_count = if (limit > 0) @min(limit, pending.len) else pending.len;
    const skipped = if (total_symbols > pending.len) total_symbols - pending.len else 0;
    const days: u16 = @intCast(@min(@as(usize, years) * 366 + 30, 65000));

    std.debug.print("共 {d} 只股票\n", .{total_symbols});
    std.debug.print("目标覆盖区间: {s} ~ {s}\n", .{ target_start, latest });
    std.debug.print("已满足覆盖: {d} 只，还需回填/更新: {d} 只\n", .{ skipped, pending.len });
    if (limit > 0) {
        std.debug.print("本次限制处理: {d} 只\n", .{process_count});
    }

    var total_rows: usize = 0;
    var success_count: usize = 0;
    var fail_count: usize = 0;

    for (pending[0..process_count], 0..) |symbol, idx| {
        const written = syncSymbol(allocator, db, symbol, days, null) catch |err| blk: {
            std.debug.print("  {s} 回填失败: {any}\n", .{ symbol, err });
            break :blk 0;
        };
        if (written > 0) {
            total_rows += written;
            success_count += 1;
        } else {
            fail_count += 1;
        }

        if ((idx + 1) % 20 == 0 or idx + 1 == process_count) {
            std.debug.print("  回填进度: {d}/{d} | 本次写入 {d} 条 | 成功{d} 失败{d}\n", .{ idx + 1, process_count, total_rows, success_count, fail_count });
        }
    }

    std.debug.print("\n回填完成: 成功 {d}，失败/空数据 {d}，写入/更新 {d} 条\n", .{ success_count, fail_count, total_rows });
}

fn syncIncremental(allocator: std.mem.Allocator, db: *duckdb.Db, limit: usize) !void {
    std.debug.print("============================================================\n", .{});
    std.debug.print("增量同步 - 更新最新交易日数据\n", .{});
    std.debug.print("============================================================\n", .{});

    try ensureStockPool(allocator, db);

    const latest = try latestBusinessDate(allocator, db);
    defer allocator.free(latest);

    const spot_written = patchLatestSpotBars(allocator, db, latest, limit) catch |err| blk: {
        std.debug.print("最新交易日实时成交额补齐失败: {any}\n", .{err});
        break :blk 0;
    };
    std.debug.print("最新交易日实时成交额补齐: {d} 条\n", .{spot_written});

    const tasks = try staleUpdateTasks(allocator, db, latest);
    defer freeUpdateTasks(allocator, tasks);

    const process_count = if (limit > 0) @min(limit, tasks.len) else tasks.len;
    std.debug.print("最新交易日: {s}\n", .{latest});
    std.debug.print("需要更新 {d} 只股票\n", .{tasks.len});
    if (limit > 0) {
        std.debug.print("本次限制处理: {d} 只\n", .{process_count});
    }

    if (process_count == 0) {
        std.debug.print("所有股票已是最新\n", .{});
        return;
    }

    var total_rows: usize = 0;
    var success_count: usize = 0;
    var fail_count: usize = 0;

    for (tasks[0..process_count], 0..) |task, idx| {
        const written = syncSymbol(allocator, db, task.symbol, 500, task.last_date) catch |err| blk: {
            std.debug.print("  {s} 增量失败: {any}\n", .{ task.symbol, err });
            break :blk 0;
        };
        if (written > 0) {
            total_rows += written;
            success_count += 1;
        } else {
            fail_count += 1;
        }

        if ((idx + 1) % 50 == 0 or idx + 1 == process_count) {
            std.debug.print("  进度: {d}/{d} | 已更新 {d} 条 | 成功{d} 空数据{d}\n", .{ idx + 1, process_count, total_rows, success_count, fail_count });
        }
    }

    std.debug.print("\n完成: 共更新 {d} 条数据\n", .{total_rows});
}

fn syncSymbol(allocator: std.mem.Allocator, db: *duckdb.Db, symbol: []const u8, days: u16, start_after: ?[]const u8) !usize {
    if (!isSafeSymbol(symbol)) return 0;

    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        var result = fetchDailyK(allocator, symbol, days) catch {
            continue;
        };
        defer result.deinit(allocator);

        if (result.err_msg != null or result.items.len == 0) {
            return 0;
        }

        const written = try upsertBars(allocator, db, symbol, result.items, start_after);
        if (written > 0) {
            if (latestBarDate(result.items, start_after)) |date| {
                try updateSyncLog(allocator, db, symbol, date);
            }
        }
        return written;
    }

    return error.FetchDailyKFailed;
}

fn syncSymbolRecent(allocator: std.mem.Allocator, db: *duckdb.Db, symbol: []const u8, days: u16, start_after: ?[]const u8) !usize {
    if (!isSafeSymbol(symbol)) return 0;

    var attempt: usize = 0;
    while (attempt < 2) : (attempt += 1) {
        var result = tencent.getDailyK(allocator, symbol, days) catch {
            continue;
        };
        defer result.deinit(allocator);

        if (result.err_msg != null or result.items.len == 0) {
            return 0;
        }

        const written = try upsertBars(allocator, db, symbol, result.items, start_after);
        if (written > 0) {
            if (latestBarDate(result.items, start_after)) |date| {
                try updateSyncLog(allocator, db, symbol, date);
            }
        }
        return written;
    }

    return 0;
}

fn ensureStockPool(allocator: std.mem.Allocator, db: *duckdb.Db) !void {
    const local_count = try universeCount(allocator, db);
    if (local_count > 0) {
        std.debug.print("使用本地股票池: {d} 只\n", .{local_count});
        return;
    }
    _ = try syncNames(allocator, db);
}

fn fetchDailyK(allocator: std.mem.Allocator, symbol: []const u8, days: u16) !eastmoney.KlineResult {
    var primary = eastmoney.getDailyK(allocator, symbol, days) catch |err| {
        std.debug.print("  {s} 东方财富日K失败: {any}，尝试腾讯备用源\n", .{ symbol, err });
        return tencent.getDailyK(allocator, symbol, days);
    };

    if (primary.err_msg == null and primary.items.len > 0) {
        return primary;
    }

    primary.deinit(allocator);
    std.debug.print("  {s} 东方财富日K无数据，尝试腾讯备用源\n", .{symbol});
    return tencent.getDailyK(allocator, symbol, days);
}

const SpotBar = struct {
    symbol: []const u8,
    open: f64,
    close: f64,
    high: f64,
    low: f64,
    volume: f64,
    amount: f64,
    change_pct: ?f64,
};

fn patchLatestSpotBars(allocator: std.mem.Allocator, db: *duckdb.Db, latest: []const u8, limit: usize) !usize {
    const symbols = try latestAmountPatchSymbols(allocator, db, latest, limit);
    defer freeStringList(allocator, symbols);
    if (symbols.len == 0) return 0;

    const chunk_size: usize = 100;
    var total_written: usize = 0;
    var start: usize = 0;
    while (start < symbols.len) : (start += chunk_size) {
        const end = @min(start + chunk_size, symbols.len);
        const written = patchLatestSpotChunk(allocator, db, latest, symbols[start..end]) catch |err| blk: {
            std.debug.print("  实时成交额批次失败 {d}-{d}: {any}\n", .{ start + 1, end, err });
            break :blk 0;
        };
        total_written += written;
    }
    return total_written;
}

fn latestAmountPatchSymbols(allocator: std.mem.Allocator, db: *duckdb.Db, latest: []const u8, limit: usize) ![]const []const u8 {
    const limit_clause = if (limit > 0)
        try std.fmt.allocPrint(allocator, "LIMIT {d}", .{limit})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(limit_clause);

    const query = try std.fmt.allocPrint(allocator,
        \\WITH universe AS (
        \\    SELECT symbol FROM stock_info WHERE length(symbol) = 6
        \\    UNION
        \\    SELECT DISTINCT symbol FROM daily_k WHERE length(symbol) = 6
        \\)
        \\SELECT u.symbol
        \\FROM universe u
        \\LEFT JOIN daily_k k
        \\  ON k.symbol = u.symbol
        \\ AND k.date = CAST('{s}' AS DATE)
        \\ORDER BY
        \\  CASE WHEN k.amount IS NULL OR k.amount <= 0 THEN 0 ELSE 1 END,
        \\  u.symbol
        \\{s}
    , .{ latest, limit_clause });
    defer allocator.free(query);

    return querySymbolList(allocator, db, query);
}

fn patchLatestSpotChunk(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    latest: []const u8,
    symbols: []const []const u8,
) !usize {
    if (symbols.len == 0) return 0;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var query = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer query.deinit(aa);
    for (symbols, 0..) |symbol, idx| {
        if (idx > 0) try query.append(aa, ',');
        const prefix = if (symbol[0] == '6' or symbol[0] == '5') "sh" else "sz";
        try query.writer(aa).print("{s}{s}", .{ prefix, symbol });
    }

    const url = try std.fmt.allocPrint(aa, "http://qt.gtimg.cn/q={s}", .{query.items});
    const response = try eastmoney.httpGet(aa, url);

    var bars = std.ArrayList(SpotBar){ .items = &.{}, .capacity = 0 };
    defer bars.deinit(aa);

    var line_iter = std.mem.splitScalar(u8, response, ';');
    while (line_iter.next()) |line| {
        if (parseTencentSpotBar(line)) |bar| {
            try bars.append(aa, bar);
        }
    }
    if (bars.items.len == 0) return 0;

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("BEGIN TRANSACTION; ");
    try w.writeAll("INSERT INTO daily_k (symbol, date, open, close, high, low, volume, amount, change_pct, updated_at) VALUES ");
    for (bars.items, 0..) |bar, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.print("('{s}', CAST('{s}' AS DATE), {d}, {d}, {d}, {d}, {d}, {d}, ", .{
            bar.symbol,
            latest,
            bar.open,
            bar.close,
            bar.high,
            bar.low,
            bar.volume,
            bar.amount,
        });
        try writeSqlNullableF64(w, bar.change_pct);
        try w.writeAll(", now())");
    }
    try w.writeAll(
        \\ ON CONFLICT (symbol, date) DO UPDATE SET
        \\ open = excluded.open,
        \\ close = excluded.close,
        \\ high = excluded.high,
        \\ low = excluded.low,
        \\ volume = excluded.volume,
        \\ amount = excluded.amount,
        \\ change_pct = COALESCE(excluded.change_pct, daily_k.change_pct),
        \\ updated_at = now();
        \\
    );
    try w.writeAll("INSERT OR REPLACE INTO sync_log (symbol, last_date, updated_at) VALUES ");
    for (bars.items, 0..) |bar, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.print("('{s}', CAST('{s}' AS DATE), CURRENT_TIMESTAMP)", .{ bar.symbol, latest });
    }
    try w.writeAll("; COMMIT");
    try db.exec(out.written());
    return bars.items.len;
}

fn parseTencentSpotBar(line: []const u8) ?SpotBar {
    const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const last_quote = std.mem.lastIndexOfScalar(u8, line, '"') orelse return null;
    if (first_quote >= last_quote) return null;

    const payload = line[first_quote + 1 .. last_quote];
    var field_iter = std.mem.splitScalar(u8, payload, '~');
    var field_index: usize = 0;
    var symbol: ?[]const u8 = null;
    var close: ?f64 = null;
    var prev_close: ?f64 = null;
    var open: ?f64 = null;
    var volume: ?f64 = null;
    var high: ?f64 = null;
    var low: ?f64 = null;
    var amount: ?f64 = null;
    var change_pct: ?f64 = null;

    while (field_iter.next()) |field| : (field_index += 1) {
        switch (field_index) {
            2 => symbol = field,
            3 => close = std.fmt.parseFloat(f64, field) catch null,
            4 => prev_close = std.fmt.parseFloat(f64, field) catch null,
            5 => open = std.fmt.parseFloat(f64, field) catch null,
            6 => volume = std.fmt.parseFloat(f64, field) catch null,
            32 => change_pct = std.fmt.parseFloat(f64, field) catch null,
            33 => high = std.fmt.parseFloat(f64, field) catch null,
            34 => low = std.fmt.parseFloat(f64, field) catch null,
            35 => {
                var amount_iter = std.mem.splitScalar(u8, field, '/');
                _ = amount_iter.next();
                _ = amount_iter.next();
                if (amount_iter.next()) |amount_str| {
                    amount = std.fmt.parseFloat(f64, amount_str) catch null;
                }
            },
            else => {},
        }
        if (field_index > 35) break;
    }

    const code = symbol orelse return null;
    if (!isSafeSymbol(code)) return null;
    const close_value = close orelse return null;
    const amount_value = amount orelse return null;
    if (close_value <= 0 or amount_value <= 0) return null;

    const open_value = open orelse close_value;
    var high_value = high orelse close_value;
    var low_value = low orelse close_value;
    if (high_value <= 0) high_value = close_value;
    if (low_value <= 0) low_value = close_value;
    const pct = change_pct orelse if (prev_close) |prev|
        if (prev != 0) (close_value - prev) / prev * 100.0 else null
    else
        null;

    return SpotBar{
        .symbol = code,
        .open = if (open_value > 0) open_value else close_value,
        .close = close_value,
        .high = high_value,
        .low = low_value,
        .volume = volume orelse 0,
        .amount = amount_value,
        .change_pct = pct,
    };
}

fn upsertBars(allocator: std.mem.Allocator, db: *duckdb.Db, symbol: []const u8, bars: []const eastmoney.KlineItem, start_after: ?[]const u8) !usize {
    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();

    const w = &out.writer;
    try w.writeAll("INSERT INTO daily_k (symbol, date, open, close, high, low, volume, amount, change_pct, updated_at) VALUES ");

    var count: usize = 0;
    for (bars) |bar| {
        if (start_after) |min_date| {
            if (std.mem.order(u8, bar.date, min_date) != .gt) continue;
        }

        if (count > 0) try w.writeAll(", ");
        try w.print("('{s}', CAST('{s}' AS DATE), {d}, {d}, {d}, {d}, {d}, ", .{
            symbol,
            bar.date,
            bar.open,
            bar.close,
            bar.high,
            bar.low,
            bar.volume,
        });
        try writeSqlNullableF64(w, bar.amount);
        try w.writeAll(", ");
        try writeSqlNullableF64(w, bar.change_pct);
        try w.writeAll(", now())");
        count += 1;
    }

    if (count == 0) return 0;
    try w.writeAll(
        \\ ON CONFLICT (symbol, date) DO UPDATE SET
        \\ open = excluded.open,
        \\ close = excluded.close,
        \\ high = excluded.high,
        \\ low = excluded.low,
        \\ volume = excluded.volume,
        \\ amount = COALESCE(excluded.amount, daily_k.amount),
        \\ change_pct = COALESCE(excluded.change_pct, daily_k.change_pct),
        \\ updated_at = now()
    );
    try db.exec(out.written());
    return count;
}

fn updateSyncLog(allocator: std.mem.Allocator, db: *duckdb.Db, symbol: []const u8, last_date: []const u8) !void {
    const query = try std.fmt.allocPrint(
        allocator,
        "INSERT OR REPLACE INTO sync_log (symbol, last_date, updated_at) VALUES ('{s}', CAST('{s}' AS DATE), CURRENT_TIMESTAMP)",
        .{ symbol, last_date },
    );
    defer allocator.free(query);
    try db.exec(query);
}

fn latestBarDate(bars: []const eastmoney.KlineItem, start_after: ?[]const u8) ?[]const u8 {
    var latest: ?[]const u8 = null;
    for (bars) |bar| {
        if (start_after) |min_date| {
            if (std.mem.order(u8, bar.date, min_date) != .gt) continue;
        }
        if (latest == null or std.mem.order(u8, bar.date, latest.?) == .gt) {
            latest = bar.date;
        }
    }
    return latest;
}

fn showStats(allocator: std.mem.Allocator, db: *duckdb.Db) !void {
    var stats = try db.queryRows(allocator,
        \\SELECT
        \\    COUNT(*) AS rows,
        \\    COUNT(DISTINCT symbol) AS symbols,
        \\    CAST(MIN(date) AS VARCHAR) AS min_date,
        \\    CAST(MAX(date) AS VARCHAR) AS max_date
        \\FROM daily_k
    );
    defer stats.deinit(allocator);

    const size_mb = fileSizeMb(db.path);

    std.debug.print("============================================================\n", .{});
    std.debug.print("数据库统计\n", .{});
    std.debug.print("============================================================\n", .{});
    if (stats.rows.items.len > 0) {
        std.debug.print("  股票数量: {s}\n", .{stats.getStr(0, "symbols") orelse "0"});
        std.debug.print("  记录总数: {s}\n", .{stats.getStr(0, "rows") orelse "0"});
        std.debug.print("  日期范围: {s} ~ {s}\n", .{ stats.getStr(0, "min_date") orelse "", stats.getStr(0, "max_date") orelse "" });
        std.debug.print("  文件大小: {d:.1} MB\n", .{size_mb});
    }

    var recent = try db.queryRows(allocator,
        \\SELECT CAST(date AS VARCHAR) AS date, COUNT(*) AS cnt
        \\FROM daily_k
        \\GROUP BY date
        \\ORDER BY date DESC
        \\LIMIT 10
    );
    defer recent.deinit(allocator);

    std.debug.print("\n  最近交易日:\n", .{});
    for (recent.rows.items, 0..) |_, i| {
        std.debug.print("    {s}: {s} 只\n", .{ recent.getStr(i, "date") orelse "", recent.getStr(i, "cnt") orelse "0" });
    }
}

fn querySample(allocator: std.mem.Allocator, db: *duckdb.Db) !void {
    var rows = try db.queryRows(allocator,
        \\SELECT CAST(date AS VARCHAR) AS date, open, close, high, low, volume, change_pct
        \\FROM daily_k
        \\WHERE symbol = '002460'
        \\ORDER BY date DESC
        \\LIMIT 20
    );
    defer rows.deinit(allocator);

    std.debug.print("============================================================\n", .{});
    std.debug.print("示例: 002460 最近20天日K\n", .{});
    std.debug.print("============================================================\n", .{});
    std.debug.print("date        open      close     high      low       volume       change_pct\n", .{});
    for (rows.rows.items, 0..) |_, i| {
        std.debug.print("{s}  {s}  {s}  {s}  {s}  {s}  {s}\n", .{
            rows.getStr(i, "date") orelse "",
            rows.getStr(i, "open") orelse "",
            rows.getStr(i, "close") orelse "",
            rows.getStr(i, "high") orelse "",
            rows.getStr(i, "low") orelse "",
            rows.getStr(i, "volume") orelse "",
            rows.getStr(i, "change_pct") orelse "",
        });
    }
}

fn pendingBackfillSymbols(allocator: std.mem.Allocator, db: *duckdb.Db, target_start: []const u8, latest: []const u8) ![]const []const u8 {
    const query = try std.fmt.allocPrint(allocator,
        \\WITH universe AS (
        \\    SELECT symbol FROM stock_info WHERE length(symbol) = 6
        \\    UNION
        \\    SELECT DISTINCT symbol FROM daily_k WHERE length(symbol) = 6
        \\),
        \\coverage AS (
        \\    SELECT symbol, MIN(date) AS min_date, MAX(date) AS max_date
        \\    FROM daily_k
        \\    GROUP BY symbol
        \\)
        \\SELECT u.symbol
        \\FROM universe u
        \\LEFT JOIN coverage c ON c.symbol = u.symbol
        \\WHERE c.symbol IS NULL
        \\   OR c.min_date > CAST('{s}' AS DATE)
        \\   OR c.max_date < CAST('{s}' AS DATE)
        \\ORDER BY u.symbol
    , .{ target_start, latest });
    defer allocator.free(query);

    return querySymbolList(allocator, db, query);
}

fn symbolsNeedingSince(allocator: std.mem.Allocator, db: *duckdb.Db, since_date: []const u8) ![]const []const u8 {
    const query = try std.fmt.allocPrint(allocator,
        \\WITH universe AS (
        \\    SELECT symbol FROM stock_info WHERE length(symbol) = 6
        \\    UNION
        \\    SELECT DISTINCT symbol FROM daily_k WHERE length(symbol) = 6
        \\),
        \\coverage AS (
        \\    SELECT
        \\        symbol,
        \\        COUNT(*) FILTER (WHERE date > CAST('{s}' AS DATE)) AS rows_after_since
        \\    FROM daily_k
        \\    GROUP BY symbol
        \\)
        \\SELECT u.symbol
        \\FROM universe u
        \\LEFT JOIN coverage c ON c.symbol = u.symbol
        \\WHERE COALESCE(c.rows_after_since, 0) < 5
        \\ORDER BY u.symbol
    , .{since_date});
    defer allocator.free(query);

    return querySymbolList(allocator, db, query);
}

fn staleUpdateTasks(allocator: std.mem.Allocator, db: *duckdb.Db, latest: []const u8) ![]const UpdateTask {
    const query = try std.fmt.allocPrint(allocator,
        \\WITH universe AS (
        \\    SELECT symbol FROM stock_info WHERE length(symbol) = 6
        \\    UNION
        \\    SELECT DISTINCT symbol FROM daily_k WHERE length(symbol) = 6
        \\),
        \\coverage AS (
        \\    SELECT
        \\        symbol,
        \\        MAX(date) AS max_date,
        \\        MAX(CASE WHEN amount IS NOT NULL AND amount > 0 THEN date END) AS max_amount_date
        \\    FROM daily_k
        \\    GROUP BY symbol
        \\)
        \\SELECT
        \\    u.symbol,
        \\    CAST(LEAST(
        \\        COALESCE(l.last_date, c.max_date, DATE '1900-01-01'),
        \\        COALESCE(c.max_amount_date, DATE '1900-01-01')
        \\    ) AS VARCHAR) AS last_date
        \\FROM universe u
        \\LEFT JOIN sync_log l ON l.symbol = u.symbol
        \\LEFT JOIN coverage c ON c.symbol = u.symbol
        \\WHERE COALESCE(l.last_date, c.max_date, DATE '1900-01-01') < CAST('{s}' AS DATE)
        \\   OR COALESCE(c.max_amount_date, DATE '1900-01-01') < CAST('{s}' AS DATE)
        \\ORDER BY u.symbol
    , .{ latest, latest });
    defer allocator.free(query);

    var rows = try db.queryRows(allocator, query);
    defer rows.deinit(allocator);

    var tasks = std.ArrayList(UpdateTask){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (tasks.items) |task| {
            allocator.free(task.symbol);
            allocator.free(task.last_date);
        }
        tasks.deinit(allocator);
    }

    for (rows.rows.items, 0..) |_, i| {
        const symbol = rows.getStr(i, "symbol") orelse continue;
        if (!isSafeSymbol(symbol)) continue;
        try tasks.append(allocator, UpdateTask{
            .symbol = try allocator.dupe(u8, symbol),
            .last_date = try allocator.dupe(u8, rows.getStr(i, "last_date") orelse "1900-01-01"),
        });
    }

    return try tasks.toOwnedSlice(allocator);
}

fn universeCount(allocator: std.mem.Allocator, db: *duckdb.Db) !usize {
    return queryCount(allocator, db,
        \\SELECT COUNT(*) AS cnt FROM (
        \\    SELECT symbol FROM stock_info WHERE length(symbol) = 6
        \\    UNION
        \\    SELECT DISTINCT symbol FROM daily_k WHERE length(symbol) = 6
        \\)
    );
}

fn latestBusinessDate(allocator: std.mem.Allocator, db: *duckdb.Db) ![]const u8 {
    return querySingleString(allocator, db,
        \\SELECT CAST(CAST(
        \\    CASE strftime(CURRENT_DATE, '%w')
        \\        WHEN '0' THEN CURRENT_DATE - INTERVAL 2 DAY
        \\        WHEN '6' THEN CURRENT_DATE - INTERVAL 1 DAY
        \\        ELSE CURRENT_DATE
        \\    END
        \\AS DATE) AS VARCHAR) AS d
    , "1970-01-01");
}

fn targetStartDate(allocator: std.mem.Allocator, db: *duckdb.Db, latest: []const u8, years: u16) ![]const u8 {
    const days: u32 = @as(u32, years) * 365;
    const query = try std.fmt.allocPrint(
        allocator,
        "SELECT CAST(CAST(CAST('{s}' AS DATE) - INTERVAL {d} DAY AS DATE) AS VARCHAR) AS d",
        .{ latest, days },
    );
    defer allocator.free(query);
    return querySingleString(allocator, db, query, "1970-01-01");
}

fn fetchDaysSince(allocator: std.mem.Allocator, db: *duckdb.Db, since_date: []const u8) !u16 {
    const latest = try latestBusinessDate(allocator, db);
    defer allocator.free(latest);
    const query = try std.fmt.allocPrint(allocator,
        \\SELECT CAST(
        \\    GREATEST(40, LEAST(800, date_diff('day', CAST('{s}' AS DATE), CAST('{s}' AS DATE)) + 30))
        \\AS VARCHAR) AS cnt
    , .{ since_date, latest });
    defer allocator.free(query);

    const days = try queryCount(allocator, db, query);
    return @intCast(@min(days, 800));
}

fn querySymbolList(allocator: std.mem.Allocator, db: *duckdb.Db, query: []const u8) ![]const []const u8 {
    var rows = try db.queryRows(allocator, query);
    defer rows.deinit(allocator);

    var list = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (list.items) |symbol| allocator.free(symbol);
        list.deinit(allocator);
    }

    for (rows.rows.items, 0..) |_, i| {
        const symbol = rows.getStr(i, "symbol") orelse continue;
        if (!isSafeSymbol(symbol)) continue;
        try list.append(allocator, try allocator.dupe(u8, symbol));
    }
    return try list.toOwnedSlice(allocator);
}

fn querySingleString(allocator: std.mem.Allocator, db: *duckdb.Db, query: []const u8, default_value: []const u8) ![]const u8 {
    var rows = try db.queryRows(allocator, query);
    defer rows.deinit(allocator);

    if (rows.rows.items.len == 0 or rows.rows.items[0].items.len == 0 or rows.rows.items[0].items[0].len == 0) {
        return allocator.dupe(u8, default_value);
    }
    return allocator.dupe(u8, rows.rows.items[0].items[0]);
}

fn queryCount(allocator: std.mem.Allocator, db: *duckdb.Db, query: []const u8) !usize {
    var rows = try db.queryRows(allocator, query);
    defer rows.deinit(allocator);

    if (rows.rows.items.len == 0 or rows.rows.items[0].items.len == 0) return 0;
    return std.fmt.parseInt(usize, rows.rows.items[0].items[0], 10) catch 0;
}

fn sqlEscape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);

    for (input) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, ch);
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn writeSqlNullableF64(writer: anytype, value: ?f64) !void {
    if (value) |v| {
        try writer.print("{d}", .{v});
    } else {
        try writer.writeAll("NULL");
    }
}

fn fileSizeMb(path: []const u8) f64 {
    const stat = std.fs.cwd().statFile(path) catch return 0;
    return @as(f64, @floatFromInt(stat.size)) / 1024.0 / 1024.0;
}

fn isSafeSymbol(s: []const u8) bool {
    if (s.len != 6) return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn isSafeDate(s: []const u8) bool {
    if (s.len != 10) return false;
    for (s, 0..) |ch, idx| {
        if (idx == 4 or idx == 7) {
            if (ch != '-') return false;
        } else if (ch < '0' or ch > '9') {
            return false;
        }
    }
    return true;
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn freeUpdateTasks(allocator: std.mem.Allocator, tasks: []const UpdateTask) void {
    for (tasks) |task| {
        allocator.free(task.symbol);
        allocator.free(task.last_date);
    }
    allocator.free(tasks);
}
