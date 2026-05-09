const std = @import("std");
const duckdb = @import("duckdb.zig");
const baidu = @import("baidu.zig");
const config = @import("backtest_config.zig");
const factor_cache_config = @import("backtest_factor_cache.zig");
const custom_factor_math = @import("backtest_custom_factors.zig");
const factor_math = @import("backtest_factors.zig");
const hook_config = @import("backtest_hooks.zig");
const types = @import("backtest_types.zig");

const MAX_FACTORS = config.MAX_FACTORS;
const MAX_COMPONENTS = config.factor_specs.MAX_COMPONENTS;
const Factor = config.Factor;
const FactorSpec = config.FactorSpec;
const Request = config.Request;
const parseRequest = config.parseRequest;
const isDate = config.isDate;
const executionModeName = config.executionModeName;
const poolModeName = config.poolModeName;
const factorName = config.factorName;
const maxLookback = config.maxLookback;
const hasFactor = config.hasFactor;

const FactorCacheStats = factor_cache_config.Stats;
const FactorCache = factor_cache_config.Cache;
const FactorCacheRecord = factor_cache_config.Record;
const FACTOR_CACHE_VERSION = factor_cache_config.VERSION;
const factorCacheKeyBuf = factor_cache_config.keyBuf;
const loadFactorCache = factor_cache_config.load;
const upsertFactorCache = factor_cache_config.upsert;

const computeFactor = factor_math.compute;
const lastPeDateOnOrBefore = factor_math.lastPeDateOnOrBefore;
const sampleStd = factor_math.sampleStd;

pub const ProgressCallback = hook_config.ProgressCallback;
pub const CancelCallback = hook_config.CancelCallback;
pub const Hooks = hook_config.Hooks;
const emitProgress = hook_config.emitProgress;
const checkCancelled = hook_config.checkCancelled;

const PriceRow = types.PriceRow;
const PePoint = types.PePoint;
const StockData = types.StockData;

const Observation = struct {
    stock_index: usize,
    date: []const u8,
    factor_date: []const u8,
    pe_max_date: ?[]const u8 = null,
    entry_date: []const u8,
    exit_date: []const u8,
    next_rebalance_date: ?[]const u8 = null,
    history_days: usize,
    forward_return: f64,
    entry_price: f64,
    exit_price: f64,
    in_pool: bool = false,
    factors: [MAX_FACTORS]f64 = [_]f64{0} ** MAX_FACTORS,
    factor_scores: [MAX_FACTORS]f64 = [_]f64{0} ** MAX_FACTORS,
    custom_components: [MAX_FACTORS][MAX_COMPONENTS]f64 = [_][MAX_COMPONENTS]f64{[_]f64{0} ** MAX_COMPONENTS} ** MAX_FACTORS,
    score: f64 = 0,
    tradable: bool = true,
    buyable: bool = true,
    sellable: bool = true,
};

const Holding = struct {
    stock_index: usize,
    symbol: []const u8,
    weight: f64,
    score: f64,
    forward_return: f64,
    factors: [MAX_FACTORS]f64,
    factor_scores: [MAX_FACTORS]f64,
    buyable: bool,
    sellable: bool,
    carried: bool = false,
    entry_price: f64,
    exit_price: f64,
};

const PortfolioRow = struct {
    date: []const u8,
    long_return: f64,
    short_return: f64,
    ls_return: f64,
    gross_return: f64,
    net_return: f64,
    benchmark_return: f64,
    excess_return: f64,
    turnover: f64,
    buy_turnover: f64,
    sell_turnover: f64,
    cost: f64,
    n_stocks: usize,
    n_long: usize,
    n_short: usize,
    n_buy_blocked: usize,
    n_sell_blocked: usize,
    n_benchmark: usize,
    net_value: f64 = 1,
    benchmark_net_value: f64 = 1,
    excess_net_value: f64 = 1,
    cumulative_return: f64 = 0,
    drawdown: f64 = 0,
    long_holdings: std.ArrayList(Holding),
    short_holdings: std.ArrayList(Holding),
};

const PoolMembers = struct {
    date: []const u8,
    symbols: std.ArrayList([]const u8),

    fn deinit(self: *PoolMembers, allocator: std.mem.Allocator) void {
        allocator.free(self.date);
        for (self.symbols.items) |sym| allocator.free(sym);
        self.symbols.deinit(allocator);
    }
};

const StockPools = struct {
    source: []const u8,
    pools: std.ArrayList(PoolMembers),
    union_symbols: std.ArrayList([]const u8),

    fn deinit(self: *StockPools, allocator: std.mem.Allocator) void {
        for (self.pools.items) |*pool| pool.deinit(allocator);
        self.pools.deinit(allocator);
        for (self.union_symbols.items) |sym| allocator.free(sym);
        self.union_symbols.deinit(allocator);
    }
};

const IcResult = struct {
    mean: f64,
    std: f64,
    icir: f64,
    positive_ratio: f64,
};

const Metrics = struct {
    total_return: f64,
    annualized_return: f64,
    benchmark_total_return: f64,
    benchmark_annualized_return: f64,
    excess_total_return: f64,
    max_drawdown: f64,
    sharpe_ratio: f64,
    information_ratio: f64,
    num_periods: usize,
    periods_per_year: f64,
};

pub fn run(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    body: []const u8,
    workspace_dir: []const u8,
) ![]u8 {
    return runWithHooks(allocator, db, body, workspace_dir, .{});
}

pub fn runWithHooks(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    body: []const u8,
    workspace_dir: []const u8,
    hooks: Hooks,
) ![]u8 {
    emitProgress(hooks, "init", 0.02, "初始化回测参数");
    var req = try parseRequest(allocator, body);
    defer req.deinit(allocator);

    try checkCancelled(hooks);
    const max_lookback = maxLookback(req.factors.items);
    const buffer_days = @as(usize, @intFromFloat(@as(f64, @floatFromInt(max_lookback)) * 2.2)) + 30;
    const lookback_start = try queryLookbackStart(allocator, db, req.start_date, buffer_days);
    defer allocator.free(lookback_start);

    try checkCancelled(hooks);
    var trading_dates = try loadMarketTradingDates(allocator, db, req.start_date, req.end_date);
    defer {
        for (trading_dates.items) |date| allocator.free(date);
        trading_dates.deinit(allocator);
    }
    if (trading_dates.items.len < 2) return error.TooFewTradingDates;

    var rebalance_dates = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer rebalance_dates.deinit(allocator);
    var di: usize = 0;
    while (di < trading_dates.items.len) : (di += req.rebalance_period) {
        try rebalance_dates.append(allocator, trading_dates.items[di]);
    }
    if (rebalance_dates.items.len < 2) return error.TooFewRebalanceDates;
    emitProgress(hooks, "dates", 0.08, "生成调仓日期");

    try checkCancelled(hooks);
    var stock_pools = try buildStockPools(allocator, db, req, rebalance_dates.items);
    defer stock_pools.deinit(allocator);
    if (stock_pools.union_symbols.items.len == 0) return error.NoStockPool;
    emitProgress(hooks, "stock_pool", 0.15, "构建股票池");

    try checkCancelled(hooks);
    var factor_cache = try loadFactorCache(allocator, db, stock_pools.union_symbols.items, rebalance_dates.items, req.factors.items);
    defer factor_cache.deinit(allocator);
    emitProgress(hooks, "factor_cache", 0.18, "读取因子缓存");

    try checkCancelled(hooks);
    emitProgress(hooks, "data_loading", 0.20, "加载历史行情");
    var stocks = try loadPriceData(allocator, db, stock_pools.union_symbols.items, lookback_start, req.end_date);
    defer {
        for (stocks.items) |*stock| stock.deinit(allocator);
        stocks.deinit(allocator);
    }
    if (stocks.items.len == 0) return error.NoPriceData;
    emitProgress(hooks, "data_loading", 0.40, "历史行情加载完成");

    try checkCancelled(hooks);
    if (hasFactor(req.factors.items, .pe_percentile)) {
        try loadPeData(allocator, &stocks);
    }
    emitProgress(hooks, "data_loading", 0.45, "估值数据加载完成");

    var observations = std.ArrayList(Observation){ .items = &.{}, .capacity = 0 };
    defer observations.deinit(allocator);
    var factor_cache_records = std.ArrayList(FactorCacheRecord){ .items = &.{}, .capacity = 0 };
    defer factor_cache_records.deinit(allocator);

    for (rebalance_dates.items, 0..) |date, ri| {
        try checkCancelled(hooks);
        const next_date = if (ri + 1 < rebalance_dates.items.len) rebalance_dates.items[ri + 1] else null;
        const entry_date = nextTradingDate(trading_dates.items, date);
        const pool = &stock_pools.pools.items[ri];
        for (stocks.items, 0..) |*stock, si| {
            const in_pool = poolContainsSymbol(pool, stock.symbol);
            if (try computeObservation(allocator, stock, si, date, entry_date, next_date, req, max_lookback, in_pool, &factor_cache, &factor_cache_records)) |obs| {
                try observations.append(allocator, obs);
            }
        }
        emitProgress(
            hooks,
            "factor_calc",
            0.45 + 0.30 * (@as(f64, @floatFromInt(ri + 1)) / @as(f64, @floatFromInt(rebalance_dates.items.len))),
            "计算因子",
        );
    }
    try checkCancelled(hooks);
    factor_cache.stats.writes = try upsertFactorCache(allocator, db, factor_cache_records.items);
    factor_cache.stats.cacheable = factor_cache.stats.hits + factor_cache.stats.writes;
    factor_cache.stats.unavailable = if (factor_cache.stats.requested > factor_cache.stats.cacheable)
        factor_cache.stats.requested - factor_cache.stats.cacheable
    else
        0;
    factor_cache.stats.hit_rate = if (factor_cache.stats.cacheable > 0)
        @as(f64, @floatFromInt(factor_cache.stats.hits)) / @as(f64, @floatFromInt(factor_cache.stats.cacheable))
    else
        0;
    if (observations.items.len == 0) return error.NoFactorData;
    emitProgress(hooks, "factor_calc", 0.76, "因子计算完成");

    try checkCancelled(hooks);
    var portfolio = try buildPortfolio(allocator, stocks.items, &observations, rebalance_dates.items, req, hooks);
    defer deinitPortfolio(allocator, &portfolio);
    if (portfolio.items.len == 0) return error.PortfolioFailed;

    try checkCancelled(hooks);
    emitProgress(hooks, "metrics", 0.92, "计算绩效和数据质量");
    const metrics = computeMetrics(portfolio.items, req.rebalance_period);
    const ic_results = try computeIc(allocator, observations.items, rebalance_dates.items, req.factors.items);
    defer allocator.free(ic_results);

    const output = try renderOutput(
        allocator,
        req,
        stock_pools.source,
        &stock_pools,
        stocks.items,
        lookback_start,
        trading_dates.items[0],
        trading_dates.items[trading_dates.items.len - 1],
        trading_dates.items,
        observations.items,
        rebalance_dates.items,
        portfolio.items,
        metrics,
        ic_results,
        factor_cache.stats,
    );

    saveHistory(allocator, workspace_dir, req, metrics) catch |err| {
        std.debug.print("Backtest history save failed: {any}\n", .{err});
    };

    emitProgress(hooks, "done", 1.0, "回测完成");
    return output;
}

pub fn validateRequest(allocator: std.mem.Allocator, body: []const u8) !void {
    var req = try parseRequest(allocator, body);
    defer req.deinit(allocator);
}

pub fn history(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    const history_dir = try std.fmt.allocPrint(allocator, "{s}/.backtest_history", .{workspace_dir});
    defer allocator.free(history_dir);

    var dir = std.fs.openDirAbsolute(history_dir, .{ .iterate = true }) catch {
        return try allocator.dupe(u8, "[]");
    };
    defer dir.close();

    var out = std.io.Writer.Allocating.init(allocator);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginArray();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (std.mem.indexOf(u8, entry.name, "_full") != null) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ history_dir, entry.name });
        defer allocator.free(path);
        const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch continue;
        defer allocator.free(content);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, content, .{}) catch continue;
        try s.write(parsed);
    }

    try s.endArray();
    return out.toOwnedSlice();
}

fn queryLookbackStart(allocator: std.mem.Allocator, db: *duckdb.Db, start_date: []const u8, buffer_days: usize) ![]u8 {
    const sql = try std.fmt.allocPrint(
        allocator,
        "SELECT CAST(CAST((DATE '{s}' - INTERVAL {d} DAY) AS DATE) AS VARCHAR) AS lookback_start",
        .{ start_date, buffer_days },
    );
    defer allocator.free(sql);
    var result = try db.queryRows(allocator, sql);
    defer result.deinit(allocator);
    return try allocator.dupe(u8, result.getStr(0, "lookback_start") orelse start_date);
}

fn buildStockPool(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    start_date: []const u8,
    pool_size: usize,
    source: *[]const u8,
) !std.ArrayList([]const u8) {
    var symbols = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (symbols.items) |sym| allocator.free(sym);
        symbols.deinit(allocator);
    }

    const sql = try std.fmt.allocPrint(allocator,
        \\WITH recent_dates AS (
        \\    SELECT DISTINCT date
        \\    FROM daily_k
        \\    WHERE date < DATE '{s}'
        \\      AND amount IS NOT NULL
        \\      AND amount > 0
        \\    ORDER BY date DESC
        \\    LIMIT 20
        \\)
        \\SELECT symbol, AVG(amount) AS avg_amount
        \\FROM daily_k
        \\WHERE date IN (SELECT date FROM recent_dates)
        \\GROUP BY symbol
        \\HAVING AVG(amount) > 0
        \\ORDER BY avg_amount DESC
        \\LIMIT {d}
    , .{ start_date, pool_size });
    defer allocator.free(sql);

    var result = db.queryRows(allocator, sql) catch null;
    if (result) |*rows| {
        defer rows.deinit(allocator);
        var i: usize = 0;
        while (i < rows.rows.items.len) : (i += 1) {
            const sym = rows.getStr(i, "symbol") orelse continue;
            if (validSymbol(sym)) try symbols.append(allocator, try allocator.dupe(u8, sym));
        }
    }
    if (symbols.items.len > 0) {
        source.* = "local_amount";
        return symbols;
    }

    const fallback_sql = try std.fmt.allocPrint(
        allocator,
        "SELECT DISTINCT symbol FROM daily_k ORDER BY symbol LIMIT {d}",
        .{pool_size},
    );
    defer allocator.free(fallback_sql);
    var fallback = try db.queryRows(allocator, fallback_sql);
    defer fallback.deinit(allocator);
    var i: usize = 0;
    while (i < fallback.rows.items.len) : (i += 1) {
        const sym = fallback.getStr(i, "symbol") orelse continue;
        if (validSymbol(sym)) try symbols.append(allocator, try allocator.dupe(u8, sym));
    }
    source.* = "local_daily_k";
    return symbols;
}

fn buildStockPools(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    req: Request,
    dates: []const []const u8,
) !StockPools {
    return switch (req.pool_mode) {
        .dynamic => try buildDynamicStockPools(allocator, db, dates, req.pool_size),
        .static => try buildStaticStockPools(allocator, db, req.start_date, dates, req.pool_size),
    };
}

fn buildDynamicStockPools(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    dates: []const []const u8,
    pool_size: usize,
) !StockPools {
    var out = StockPools{
        .source = "dynamic_local_amount",
        .pools = std.ArrayList(PoolMembers){ .items = &.{}, .capacity = 0 },
        .union_symbols = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
    };
    errdefer out.deinit(allocator);

    var union_seen = std.StringHashMap(void).init(allocator);
    defer union_seen.deinit();

    for (dates) |date| {
        var pool = PoolMembers{
            .date = try allocator.dupe(u8, date),
            .symbols = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
        };
        errdefer pool.deinit(allocator);

        try loadAmountPoolForDate(allocator, db, date, pool_size, &pool.symbols);
        if (pool.symbols.items.len == 0) {
            try loadFallbackPool(allocator, db, pool_size, &pool.symbols);
            out.source = "dynamic_local_daily_k_fallback";
        }

        for (pool.symbols.items) |sym| {
            if (!union_seen.contains(sym)) {
                const owned = try allocator.dupe(u8, sym);
                try out.union_symbols.append(allocator, owned);
                try union_seen.put(owned, {});
            }
        }
        try out.pools.append(allocator, pool);
    }
    return out;
}

fn buildStaticStockPools(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    start_date: []const u8,
    dates: []const []const u8,
    pool_size: usize,
) !StockPools {
    var source: []const u8 = "local_amount";
    var symbols = try buildStockPool(allocator, db, start_date, pool_size, &source);
    defer {
        for (symbols.items) |sym| allocator.free(sym);
        symbols.deinit(allocator);
    }

    var out = StockPools{
        .source = source,
        .pools = std.ArrayList(PoolMembers){ .items = &.{}, .capacity = 0 },
        .union_symbols = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
    };
    errdefer out.deinit(allocator);

    for (symbols.items) |sym| try out.union_symbols.append(allocator, try allocator.dupe(u8, sym));
    for (dates) |date| {
        var pool = PoolMembers{
            .date = try allocator.dupe(u8, date),
            .symbols = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
        };
        errdefer pool.deinit(allocator);
        for (symbols.items) |sym| try pool.symbols.append(allocator, try allocator.dupe(u8, sym));
        try out.pools.append(allocator, pool);
    }
    return out;
}

fn loadAmountPoolForDate(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    date: []const u8,
    pool_size: usize,
    symbols: *std.ArrayList([]const u8),
) !void {
    const sql = try std.fmt.allocPrint(allocator,
        \\WITH recent_dates AS (
        \\    SELECT DISTINCT date
        \\    FROM daily_k
        \\    WHERE date < DATE '{s}'
        \\      AND amount IS NOT NULL
        \\      AND amount > 0
        \\    ORDER BY date DESC
        \\    LIMIT 20
        \\)
        \\SELECT symbol, AVG(amount) AS avg_amount
        \\FROM daily_k
        \\WHERE date IN (SELECT date FROM recent_dates)
        \\GROUP BY symbol
        \\HAVING AVG(amount) > 0
        \\ORDER BY avg_amount DESC
        \\LIMIT {d}
    , .{ date, pool_size });
    defer allocator.free(sql);

    var rows = db.queryRows(allocator, sql) catch return;
    defer rows.deinit(allocator);
    var i: usize = 0;
    while (i < rows.rows.items.len) : (i += 1) {
        const sym = rows.getStr(i, "symbol") orelse continue;
        if (validSymbol(sym)) try symbols.append(allocator, try allocator.dupe(u8, sym));
    }
}

fn loadFallbackPool(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    pool_size: usize,
    symbols: *std.ArrayList([]const u8),
) !void {
    const sql = try std.fmt.allocPrint(
        allocator,
        "SELECT DISTINCT symbol FROM daily_k ORDER BY symbol LIMIT {d}",
        .{pool_size},
    );
    defer allocator.free(sql);
    var rows = try db.queryRows(allocator, sql);
    defer rows.deinit(allocator);
    var i: usize = 0;
    while (i < rows.rows.items.len) : (i += 1) {
        const sym = rows.getStr(i, "symbol") orelse continue;
        if (validSymbol(sym)) try symbols.append(allocator, try allocator.dupe(u8, sym));
    }
}

fn validSymbol(sym: []const u8) bool {
    if (sym.len != 6) return false;
    for (sym) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn symbolInListSql(allocator: std.mem.Allocator, symbols: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);
    for (symbols, 0..) |sym, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        const part = try std.fmt.allocPrint(allocator, "'{s}'", .{sym});
        defer allocator.free(part);
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

fn loadPriceData(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    symbols: []const []const u8,
    lookback_start: []const u8,
    end_date: []const u8,
) !std.ArrayList(StockData) {
    var stocks = std.ArrayList(StockData){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (stocks.items) |*stock| stock.deinit(allocator);
        stocks.deinit(allocator);
    }

    var index = std.StringHashMap(usize).init(allocator);
    defer index.deinit();
    for (symbols) |sym| {
        const stock = try StockData.init(allocator, sym);
        try index.put(stock.symbol, stocks.items.len);
        try stocks.append(allocator, stock);
    }

    const in_sql = try symbolInListSql(allocator, symbols);
    defer allocator.free(in_sql);
    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT symbol, CAST(date AS VARCHAR) AS date, open, close, high, low, volume, amount, change_pct
        \\FROM daily_k
        \\WHERE symbol IN ({s})
        \\  AND date >= DATE '{s}'
        \\  AND date <= DATE '{s}'
        \\ORDER BY symbol, date
    , .{ in_sql, lookback_start, end_date });
    defer allocator.free(sql);

    var rows = try db.queryRows(allocator, sql);
    defer rows.deinit(allocator);

    var r: usize = 0;
    while (r < rows.rows.items.len) : (r += 1) {
        const sym = rows.getStr(r, "symbol") orelse continue;
        const idx = index.get(sym) orelse continue;
        const date = rows.getStr(r, "date") orelse continue;
        try stocks.items[idx].prices.append(allocator, PriceRow{
            .date = try allocator.dupe(u8, date),
            .open = rows.getF64(r, "open") orelse 0,
            .close = rows.getF64(r, "close") orelse 0,
            .high = rows.getF64(r, "high") orelse 0,
            .low = rows.getF64(r, "low") orelse 0,
            .volume = rows.getF64(r, "volume") orelse 0,
            .amount = rows.getF64(r, "amount") orelse 0,
            .change_pct = rows.getF64(r, "change_pct") orelse 0,
        });
    }

    var filtered = std.ArrayList(StockData){ .items = &.{}, .capacity = 0 };
    errdefer filtered.deinit(allocator);
    for (stocks.items) |stock| {
        if (stock.prices.items.len > 0) {
            try filtered.append(allocator, stock);
        } else {
            var empty = stock;
            empty.deinit(allocator);
        }
    }
    stocks.deinit(allocator);
    return filtered;
}

fn loadTradingDates(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    symbols: []const []const u8,
    start_date: []const u8,
    end_date: []const u8,
) !std.ArrayList([]const u8) {
    var dates = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (dates.items) |date| allocator.free(date);
        dates.deinit(allocator);
    }
    const in_sql = try symbolInListSql(allocator, symbols);
    defer allocator.free(in_sql);
    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT DISTINCT CAST(date AS VARCHAR) AS date
        \\FROM daily_k
        \\WHERE symbol IN ({s})
        \\  AND date >= DATE '{s}'
        \\  AND date <= DATE '{s}'
        \\ORDER BY date
    , .{ in_sql, start_date, end_date });
    defer allocator.free(sql);
    var rows = try db.queryRows(allocator, sql);
    defer rows.deinit(allocator);
    var i: usize = 0;
    while (i < rows.rows.items.len) : (i += 1) {
        const date = rows.getStr(i, "date") orelse continue;
        try dates.append(allocator, try allocator.dupe(u8, date));
    }
    return dates;
}

fn loadMarketTradingDates(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    start_date: []const u8,
    end_date: []const u8,
) !std.ArrayList([]const u8) {
    var dates = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (dates.items) |date| allocator.free(date);
        dates.deinit(allocator);
    }
    const sql = try std.fmt.allocPrint(allocator,
        \\SELECT DISTINCT CAST(date AS VARCHAR) AS date
        \\FROM daily_k
        \\WHERE date >= DATE '{s}'
        \\  AND date <= DATE '{s}'
        \\ORDER BY date
    , .{ start_date, end_date });
    defer allocator.free(sql);
    var rows = try db.queryRows(allocator, sql);
    defer rows.deinit(allocator);
    var i: usize = 0;
    while (i < rows.rows.items.len) : (i += 1) {
        const date = rows.getStr(i, "date") orelse continue;
        try dates.append(allocator, try allocator.dupe(u8, date));
    }
    return dates;
}

fn nextTradingDate(dates: []const []const u8, date: []const u8) ?[]const u8 {
    for (dates) |candidate| {
        if (std.mem.order(u8, candidate, date) == .gt) return candidate;
    }
    return null;
}

fn poolContainsSymbol(pool: *const PoolMembers, symbol: []const u8) bool {
    for (pool.symbols.items) |sym| {
        if (std.mem.eql(u8, sym, symbol)) return true;
    }
    return false;
}

fn loadPeData(allocator: std.mem.Allocator, stocks: *std.ArrayList(StockData)) !void {
    for (stocks.items) |*stock| {
        var valuation = baidu.getValuation(allocator, stock.symbol) catch continue;
        defer valuation.deinit(allocator);

        var date_iter = std.mem.splitScalar(u8, valuation.dates, ',');
        var i: usize = 0;
        while (date_iter.next()) |date| : (i += 1) {
            if (i >= valuation.values.len) break;
            if (!isDate(date)) continue;
            try stock.pe_points.append(allocator, PePoint{
                .date = try allocator.dupe(u8, date),
                .value = valuation.values[i],
            });
        }
    }
}

fn computeObservation(
    allocator: std.mem.Allocator,
    stock: *StockData,
    stock_index: usize,
    date: []const u8,
    entry_date: ?[]const u8,
    next_date: ?[]const u8,
    req: Request,
    max_lookback: usize,
    in_pool: bool,
    factor_cache: *const FactorCache,
    factor_cache_records: *std.ArrayList(FactorCacheRecord),
) !?Observation {
    const hist_idx = lastPriceIndexOnOrBefore(stock.prices.items, date) orelse return null;
    if (hist_idx + 1 < max_lookback) return null;
    const current_row = stock.prices.items[hist_idx];

    const entry_idx = switch (req.execution_mode) {
        .close => hist_idx,
        .next_open => priceIndexOnDate(stock.prices.items, entry_date orelse return null) orelse return null,
    };
    const exit_idx = switch (req.execution_mode) {
        .close => futurePriceIndex(stock.prices.items, date, next_date) orelse return null,
        .next_open => futurePriceIndex(stock.prices.items, date, next_date) orelse return null,
    };
    if (exit_idx < entry_idx) return null;

    const entry_row = stock.prices.items[entry_idx];
    const entry_price = switch (req.execution_mode) {
        .close => current_row.close,
        .next_open => if (entry_row.open > 0) entry_row.open else entry_row.close,
    };
    const exit_row = stock.prices.items[exit_idx];
    const exit_price = exit_row.close;
    if (entry_price == 0 or exit_price == 0) return null;

    const has_buy_liquidity = entry_row.open > 0 and entry_row.close > 0 and entry_row.volume > 0 and entry_row.amount >= req.min_amount;
    const has_sell_liquidity = current_row.open > 0 and current_row.close > 0 and current_row.volume > 0 and current_row.amount >= req.min_amount;
    const listed_enough = hist_idx + 1 >= req.min_listed_days;
    const limit_up = entry_row.change_pct >= req.limit_pct;
    const limit_down = current_row.change_pct <= -req.limit_pct;
    const tradable = has_buy_liquidity and listed_enough;
    const sellable = has_sell_liquidity and listed_enough and !limit_down;

    var obs = Observation{
        .stock_index = stock_index,
        .date = date,
        .factor_date = current_row.date,
        .pe_max_date = lastPeDateOnOrBefore(stock.pe_points.items, date),
        .entry_date = entry_row.date,
        .exit_date = exit_row.date,
        .next_rebalance_date = next_date,
        .history_days = hist_idx + 1,
        .forward_return = (exit_price - entry_price) / entry_price,
        .entry_price = entry_price,
        .exit_price = exit_price,
        .in_pool = in_pool,
        .tradable = tradable,
        .buyable = tradable and !limit_up,
        .sellable = sellable,
    };

    for (req.factors.items, 0..) |factor, i| {
        switch (factor) {
            .builtin => |builtin| {
                var key_buf: [96]u8 = undefined;
                const key = factorCacheKeyBuf(&key_buf, stock.symbol, date, builtin) catch return null;
                const val = if (factor_cache.stats.enabled) factor_cache.values.get(key) orelse blk: {
                    const computed = computeFactor(stock, hist_idx, date, builtin) orelse return null;
                    if (!std.math.isFinite(computed)) return null;
                    try factor_cache_records.append(allocator, FactorCacheRecord{
                        .symbol = stock.symbol,
                        .date = date,
                        .factor = builtin,
                        .value = computed,
                    });
                    break :blk computed;
                } else computeFactor(stock, hist_idx, date, builtin) orelse return null;
                if (!std.math.isFinite(val)) return null;
                obs.factors[i] = val;
            },
            .custom => |custom| {
                for (custom.components, 0..) |component, ci| {
                    const val = custom_factor_math.computeComponent(stock, hist_idx, date, component) orelse return null;
                    if (!std.math.isFinite(val)) return null;
                    obs.custom_components[i][ci] = val;
                }
            },
        }
    }
    return obs;
}

fn lastPriceIndexOnOrBefore(prices: []const PriceRow, date: []const u8) ?usize {
    var out: ?usize = null;
    for (prices, 0..) |row, i| {
        if (std.mem.order(u8, row.date, date) != .gt) {
            out = i;
        } else {
            break;
        }
    }
    return out;
}

fn firstPriceIndexAfter(prices: []const PriceRow, date: []const u8) ?usize {
    for (prices, 0..) |row, i| {
        if (std.mem.order(u8, row.date, date) == .gt) return i;
    }
    return null;
}

fn priceIndexOnDate(prices: []const PriceRow, date: []const u8) ?usize {
    for (prices, 0..) |row, i| {
        const order = std.mem.order(u8, row.date, date);
        if (order == .eq) return i;
        if (order == .gt) return null;
    }
    return null;
}

fn futurePriceIndex(prices: []const PriceRow, date: []const u8, next_date: ?[]const u8) ?usize {
    var out: ?usize = null;
    for (prices, 0..) |row, i| {
        if (std.mem.order(u8, row.date, date) == .gt) {
            if (next_date) |nd| {
                if (std.mem.order(u8, row.date, nd) == .gt) break;
            }
            out = i;
        }
    }
    return out;
}

fn buildPortfolio(
    allocator: std.mem.Allocator,
    stocks: []const StockData,
    observations: *std.ArrayList(Observation),
    dates: []const []const u8,
    req: Request,
    hooks: Hooks,
) !std.ArrayList(PortfolioRow) {
    var portfolio = std.ArrayList(PortfolioRow){ .items = &.{}, .capacity = 0 };
    errdefer deinitPortfolio(allocator, &portfolio);

    for (dates, 0..) |date, di| {
        try checkCancelled(hooks);
        var all_group = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
        defer all_group.deinit(allocator);
        var group = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
        defer group.deinit(allocator);
        var buyable_group = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
        defer buyable_group.deinit(allocator);

        for (observations.items, 0..) |obs, i| {
            if (std.mem.eql(u8, obs.date, date)) {
                try all_group.append(allocator, i);
                if (obs.in_pool) try group.append(allocator, i);
            }
        }
        if (group.items.len < 5) continue;

        materializeCustomFactors(observations.items, group.items, req.factors.items);

        for (req.factors.items, 0..) |factor, fi| {
            for (group.items) |obs_idx| {
                const pct = rankPct(observations.items, group.items, fi, obs_idx);
                observations.items[obs_idx].factor_scores[fi] = if (factor.higherIsBetter()) pct else 1.0 - pct;
            }
        }
        for (group.items) |obs_idx| {
            var score: f64 = 0;
            for (0..req.factors.items.len) |fi| score += observations.items[obs_idx].factor_scores[fi];
            observations.items[obs_idx].score = score / @as(f64, @floatFromInt(req.factors.items.len));
            if (observations.items[obs_idx].buyable) try buyable_group.append(allocator, obs_idx);
        }

        if (buyable_group.items.len == 0) continue;
        std.mem.sort(usize, buyable_group.items, SortCtx{ .observations = observations.items }, scoreDesc);

        const n = group.items.len;
        const trade_n = buyable_group.items.len;
        const benchmark = computeBenchmarkReturn(observations.items, group.items);
        const previous = if (portfolio.items.len > 0) &portfolio.items[portfolio.items.len - 1] else null;

        var row = PortfolioRow{
            .date = date,
            .long_return = 0,
            .short_return = 0,
            .ls_return = 0,
            .gross_return = 0,
            .net_return = 0,
            .benchmark_return = benchmark.value,
            .excess_return = 0,
            .turnover = 0,
            .buy_turnover = 0,
            .sell_turnover = 0,
            .cost = 0,
            .n_stocks = n,
            .n_long = 0,
            .n_short = 0,
            .n_buy_blocked = n - trade_n,
            .n_sell_blocked = 0,
            .n_benchmark = benchmark.count,
            .long_holdings = std.ArrayList(Holding){ .items = &.{}, .capacity = 0 },
            .short_holdings = std.ArrayList(Holding){ .items = &.{}, .capacity = 0 },
        };
        errdefer {
            row.long_holdings.deinit(allocator);
            row.short_holdings.deinit(allocator);
        }

        if (previous) |prev| {
            row.n_sell_blocked = try appendCarriedHoldings(allocator, stocks, observations.items, all_group.items, prev, &row);
        }

        const requested_long = @min(trade_n, @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(trade_n)) * req.top_pct))));
        var long_candidates = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
        defer long_candidates.deinit(allocator);
        for (buyable_group.items) |idx| {
            const obs = observations.items[idx];
            if (rowHasStock(&row, obs.stock_index)) continue;
            try long_candidates.append(allocator, idx);
            if (long_candidates.items.len >= requested_long) break;
        }
        const remaining_long = @max(0.0, 1.0 - positiveWeight(row.long_holdings.items));
        if (remaining_long > 0 and long_candidates.items.len > 0) {
            const long_weight = remaining_long / @as(f64, @floatFromInt(long_candidates.items.len));
            for (long_candidates.items) |idx| {
                const obs = observations.items[idx];
                try row.long_holdings.append(allocator, makeHolding(stocks, obs, long_weight, false));
            }
        }

        if (req.bottom_pct > 0 and trade_n > requested_long) {
            const available_short = trade_n - requested_long;
            const requested_short = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(trade_n)) * req.bottom_pct)));
            const n_short = @min(available_short, requested_short);
            var short_candidates = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
            defer short_candidates.deinit(allocator);
            if (n_short > 0) {
                var i = trade_n;
                while (i > 0 and short_candidates.items.len < n_short) {
                    i -= 1;
                    const idx = buyable_group.items[i];
                    const obs = observations.items[idx];
                    if (rowHasStock(&row, obs.stock_index)) continue;
                    try short_candidates.append(allocator, idx);
                }
            }
            const remaining_short = @max(0.0, 1.0 - negativeWeightAbs(row.short_holdings.items));
            if (remaining_short > 0 and short_candidates.items.len > 0) {
                const short_weight = -remaining_short / @as(f64, @floatFromInt(short_candidates.items.len));
                for (short_candidates.items) |idx| {
                    const obs = observations.items[idx];
                    try row.short_holdings.append(allocator, makeHolding(stocks, obs, short_weight, false));
                }
            }
        }

        row.n_long = row.long_holdings.items.len;
        row.n_short = row.short_holdings.items.len;
        row.long_return = weightedReturn(row.long_holdings.items);
        row.short_return = weightedReturn(row.short_holdings.items);
        const turnover = calculateTurnover(previous, &row);
        row.buy_turnover = turnover.buy;
        row.sell_turnover = turnover.sell;
        row.turnover = turnover.total;
        row.cost = row.turnover * (req.commission_rate + req.slippage_rate) + row.sell_turnover * req.stamp_tax_rate;
        row.gross_return = row.long_return + row.short_return;
        row.net_return = row.gross_return - row.cost;
        row.ls_return = row.net_return;
        row.excess_return = row.net_return - row.benchmark_return;

        try portfolio.append(allocator, row);
        emitProgress(
            hooks,
            "portfolio",
            0.78 + 0.12 * (@as(f64, @floatFromInt(di + 1)) / @as(f64, @floatFromInt(dates.len))),
            "构建组合",
        );
    }

    var net: f64 = 1;
    var high: f64 = 1;
    var benchmark_net: f64 = 1;
    for (portfolio.items) |*row| {
        net *= 1.0 + row.net_return;
        benchmark_net *= 1.0 + row.benchmark_return;
        if (net > high) high = net;
        row.net_value = net;
        row.benchmark_net_value = benchmark_net;
        row.excess_net_value = if (benchmark_net != 0) net / benchmark_net else 1.0;
        row.cumulative_return = net - 1.0;
        row.drawdown = net / high - 1.0;
    }

    return portfolio;
}

fn materializeCustomFactors(observations: []Observation, group: []const usize, factors: []const FactorSpec) void {
    for (factors, 0..) |factor, fi| {
        switch (factor) {
            .builtin => {},
            .custom => |custom| {
                for (group) |obs_idx| {
                    var score: f64 = 0;
                    for (custom.components, 0..) |component, ci| {
                        const pct = componentRankPct(observations, group, fi, ci, obs_idx);
                        const directed = if (component.direction == .higher) pct else 1.0 - pct;
                        score += directed * component.weight;
                    }
                    observations[obs_idx].factors[fi] = score;
                }
            },
        }
    }
}

fn componentRankPct(observations: []const Observation, group: []const usize, factor_index: usize, component_index: usize, target_idx: usize) f64 {
    const value = observations[target_idx].custom_components[factor_index][component_index];
    var less: usize = 0;
    var equal: usize = 0;
    for (group) |idx| {
        const v = observations[idx].custom_components[factor_index][component_index];
        if (v < value) less += 1;
        if (v == value) equal += 1;
    }
    const avg_rank = @as(f64, @floatFromInt(less)) + (@as(f64, @floatFromInt(equal)) + 1.0) / 2.0;
    return avg_rank / @as(f64, @floatFromInt(group.len));
}

const BenchmarkReturn = struct {
    value: f64,
    count: usize,
};

fn computeBenchmarkReturn(observations: []const Observation, group: []const usize) BenchmarkReturn {
    var sum: f64 = 0;
    var count: usize = 0;
    for (group) |idx| {
        const obs = observations[idx];
        if (!obs.tradable) continue;
        sum += obs.forward_return;
        count += 1;
    }
    if (count == 0) {
        for (group) |idx| {
            sum += observations[idx].forward_return;
            count += 1;
        }
    }
    return BenchmarkReturn{
        .value = if (count > 0) sum / @as(f64, @floatFromInt(count)) else 0,
        .count = count,
    };
}

fn appendCarriedHoldings(
    allocator: std.mem.Allocator,
    stocks: []const StockData,
    observations: []const Observation,
    group: []const usize,
    previous: *const PortfolioRow,
    row: *PortfolioRow,
) !usize {
    var blocked: usize = 0;
    for (previous.long_holdings.items) |holding| {
        if (currentObservation(observations, group, holding.stock_index)) |obs| {
            if (!obs.sellable) {
                try row.long_holdings.append(allocator, makeHolding(stocks, obs, holding.weight, true));
                blocked += 1;
            }
        } else {
            try row.long_holdings.append(allocator, carryExistingHolding(holding));
            blocked += 1;
        }
    }
    for (previous.short_holdings.items) |holding| {
        if (currentObservation(observations, group, holding.stock_index)) |obs| {
            if (!obs.buyable) {
                try row.short_holdings.append(allocator, makeHolding(stocks, obs, holding.weight, true));
                blocked += 1;
            }
        } else {
            try row.short_holdings.append(allocator, carryExistingHolding(holding));
            blocked += 1;
        }
    }
    return blocked;
}

fn currentObservation(observations: []const Observation, group: []const usize, stock_index: usize) ?Observation {
    for (group) |idx| {
        const obs = observations[idx];
        if (obs.stock_index == stock_index) return obs;
    }
    return null;
}

fn carryExistingHolding(holding: Holding) Holding {
    var carried = holding;
    carried.carried = true;
    carried.forward_return = 0;
    return carried;
}

fn makeHolding(stocks: []const StockData, obs: Observation, weight: f64, carried: bool) Holding {
    return Holding{
        .stock_index = obs.stock_index,
        .symbol = stocks[obs.stock_index].symbol,
        .weight = weight,
        .score = obs.score,
        .forward_return = obs.forward_return,
        .factors = obs.factors,
        .factor_scores = obs.factor_scores,
        .buyable = obs.buyable,
        .sellable = obs.sellable,
        .carried = carried,
        .entry_price = obs.entry_price,
        .exit_price = obs.exit_price,
    };
}

fn positiveWeight(holdings: []const Holding) f64 {
    var total: f64 = 0;
    for (holdings) |holding| {
        if (holding.weight > 0) total += holding.weight;
    }
    return total;
}

fn negativeWeightAbs(holdings: []const Holding) f64 {
    var total: f64 = 0;
    for (holdings) |holding| {
        if (holding.weight < 0) total += -holding.weight;
    }
    return total;
}

fn weightedReturn(holdings: []const Holding) f64 {
    var total: f64 = 0;
    for (holdings) |holding| total += holding.weight * holding.forward_return;
    return total;
}

const Turnover = struct {
    total: f64,
    buy: f64,
    sell: f64,
};

fn calculateTurnover(previous: ?*const PortfolioRow, current: *const PortfolioRow) Turnover {
    var buy: f64 = 0;
    var sell: f64 = 0;
    if (previous) |prev| {
        for (prev.long_holdings.items) |holding| {
            classifyTurnover(holdingWeight(current, holding.stock_index) - holding.weight, &buy, &sell);
        }
        for (prev.short_holdings.items) |holding| {
            classifyTurnover(holdingWeight(current, holding.stock_index) - holding.weight, &buy, &sell);
        }
        for (current.long_holdings.items) |holding| {
            if (!rowHasStock(prev, holding.stock_index)) classifyTurnover(holding.weight, &buy, &sell);
        }
        for (current.short_holdings.items) |holding| {
            if (!rowHasStock(prev, holding.stock_index)) classifyTurnover(holding.weight, &buy, &sell);
        }
    } else {
        for (current.long_holdings.items) |holding| classifyTurnover(holding.weight, &buy, &sell);
        for (current.short_holdings.items) |holding| classifyTurnover(holding.weight, &buy, &sell);
    }
    return Turnover{ .total = buy + sell, .buy = buy, .sell = sell };
}

fn classifyTurnover(delta: f64, buy: *f64, sell: *f64) void {
    if (delta > 0) {
        buy.* += delta;
    } else if (delta < 0) {
        sell.* += -delta;
    }
}

fn holdingWeight(row: *const PortfolioRow, stock_index: usize) f64 {
    var weight: f64 = 0;
    for (row.long_holdings.items) |holding| {
        if (holding.stock_index == stock_index) weight += holding.weight;
    }
    for (row.short_holdings.items) |holding| {
        if (holding.stock_index == stock_index) weight += holding.weight;
    }
    return weight;
}

fn rowHasStock(row: *const PortfolioRow, stock_index: usize) bool {
    return holdingWeight(row, stock_index) != 0;
}

fn deinitPortfolio(allocator: std.mem.Allocator, portfolio: *std.ArrayList(PortfolioRow)) void {
    for (portfolio.items) |*row| {
        row.long_holdings.deinit(allocator);
        row.short_holdings.deinit(allocator);
    }
    portfolio.deinit(allocator);
}

const SortCtx = struct {
    observations: []const Observation,
};

fn scoreDesc(ctx: SortCtx, a: usize, b: usize) bool {
    return ctx.observations[a].score > ctx.observations[b].score;
}

fn rankPct(observations: []const Observation, group: []const usize, factor_index: usize, target_idx: usize) f64 {
    const value = observations[target_idx].factors[factor_index];
    var less: usize = 0;
    var equal: usize = 0;
    for (group) |idx| {
        const v = observations[idx].factors[factor_index];
        if (v < value) less += 1;
        if (v == value) equal += 1;
    }
    const avg_rank = @as(f64, @floatFromInt(less)) + (@as(f64, @floatFromInt(equal)) + 1.0) / 2.0;
    return avg_rank / @as(f64, @floatFromInt(group.len));
}

fn computeMetrics(rows: []const PortfolioRow, rebalance_period: usize) Metrics {
    const n = rows.len;
    const periods_per_year = 252.0 / @as(f64, @floatFromInt(@max(rebalance_period, 1)));
    const total_return = rows[n - 1].net_value - 1.0;
    const benchmark_total_return = rows[n - 1].benchmark_net_value - 1.0;
    const excess_total_return = rows[n - 1].excess_net_value - 1.0;
    const annualized = if (n > 1) std.math.pow(f64, rows[n - 1].net_value, periods_per_year / @as(f64, @floatFromInt(n))) - 1.0 else 0.0;
    const benchmark_annualized = if (n > 1) std.math.pow(f64, rows[n - 1].benchmark_net_value, periods_per_year / @as(f64, @floatFromInt(n))) - 1.0 else 0.0;
    var max_drawdown: f64 = 0;
    var rets_buf: [2048]f64 = undefined;
    var excess_buf: [2048]f64 = undefined;
    var count: usize = 0;
    for (rows) |row| {
        if (row.drawdown < max_drawdown) max_drawdown = row.drawdown;
        if (count < rets_buf.len) {
            rets_buf[count] = row.net_return;
            excess_buf[count] = row.excess_return;
            count += 1;
        }
    }
    var sharpe: f64 = 0;
    var information_ratio: f64 = 0;
    if (count == n) {
        const sd = sampleStd(rets_buf[0..count]) orelse 0;
        if (sd > 0) {
            var sum: f64 = 0;
            for (rets_buf[0..count]) |r| sum += r;
            sharpe = (sum / @as(f64, @floatFromInt(count))) / sd * std.math.sqrt(periods_per_year);
        }
        const excess_sd = sampleStd(excess_buf[0..count]) orelse 0;
        if (excess_sd > 0) {
            var excess_sum: f64 = 0;
            for (excess_buf[0..count]) |r| excess_sum += r;
            information_ratio = (excess_sum / @as(f64, @floatFromInt(count))) / excess_sd * std.math.sqrt(periods_per_year);
        }
    }
    return Metrics{
        .total_return = total_return,
        .annualized_return = annualized,
        .benchmark_total_return = benchmark_total_return,
        .benchmark_annualized_return = benchmark_annualized,
        .excess_total_return = excess_total_return,
        .max_drawdown = max_drawdown,
        .sharpe_ratio = sharpe,
        .information_ratio = information_ratio,
        .num_periods = n,
        .periods_per_year = periods_per_year,
    };
}

fn computeIc(
    allocator: std.mem.Allocator,
    observations: []const Observation,
    dates: []const []const u8,
    factors: []const FactorSpec,
) ![]IcResult {
    var results = try allocator.alloc(IcResult, factors.len);
    for (factors, 0..) |factor, fi| {
        var ic_values = std.ArrayList(f64){ .items = &.{}, .capacity = 0 };
        defer ic_values.deinit(allocator);

        for (dates) |date| {
            var group = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
            defer group.deinit(allocator);
            for (observations, 0..) |obs, i| {
                if (obs.in_pool and std.mem.eql(u8, obs.date, date)) try group.append(allocator, i);
            }
            if (group.items.len < 5) continue;
            if (spearman(allocator, observations, group.items, fi, factor)) |ic| {
                try ic_values.append(allocator, ic);
            }
        }

        if (ic_values.items.len == 0) {
            results[fi] = IcResult{ .mean = 0, .std = 0, .icir = 0, .positive_ratio = 0 };
            continue;
        }
        var sum: f64 = 0;
        var positive: usize = 0;
        for (ic_values.items) |v| {
            sum += v;
            if (v > 0) positive += 1;
        }
        const mean = sum / @as(f64, @floatFromInt(ic_values.items.len));
        const sd = sampleStd(ic_values.items) orelse 0;
        results[fi] = IcResult{
            .mean = mean,
            .std = sd,
            .icir = if (sd > 0.000001) mean / sd else 0,
            .positive_ratio = @as(f64, @floatFromInt(positive)) / @as(f64, @floatFromInt(ic_values.items.len)),
        };
    }
    return results;
}

fn spearman(allocator: std.mem.Allocator, observations: []const Observation, group: []const usize, factor_index: usize, factor: FactorSpec) ?f64 {
    var factor_ranks = allocator.alloc(f64, group.len) catch return null;
    defer allocator.free(factor_ranks);
    var return_ranks = allocator.alloc(f64, group.len) catch return null;
    defer allocator.free(return_ranks);

    for (group, 0..) |idx, i| {
        factor_ranks[i] = directedRankPct(observations, group, factor_index, idx, factor);
        return_ranks[i] = returnRankPct(observations, group, idx);
    }
    return pearson(factor_ranks, return_ranks);
}

fn directedRankPct(observations: []const Observation, group: []const usize, factor_index: usize, target_idx: usize, factor: FactorSpec) f64 {
    const pct = rankPct(observations, group, factor_index, target_idx);
    return if (factor.higherIsBetter()) pct else 1.0 - pct;
}

fn returnRankPct(observations: []const Observation, group: []const usize, target_idx: usize) f64 {
    const value = observations[target_idx].forward_return;
    var less: usize = 0;
    var equal: usize = 0;
    for (group) |idx| {
        const v = observations[idx].forward_return;
        if (v < value) less += 1;
        if (v == value) equal += 1;
    }
    const avg_rank = @as(f64, @floatFromInt(less)) + (@as(f64, @floatFromInt(equal)) + 1.0) / 2.0;
    return avg_rank / @as(f64, @floatFromInt(group.len));
}

fn pearson(a: []const f64, b: []const f64) ?f64 {
    if (a.len != b.len or a.len < 2) return null;
    var sum_a: f64 = 0;
    var sum_b: f64 = 0;
    for (a, b) |x, y| {
        sum_a += x;
        sum_b += y;
    }
    const mean_a = sum_a / @as(f64, @floatFromInt(a.len));
    const mean_b = sum_b / @as(f64, @floatFromInt(b.len));
    var cov: f64 = 0;
    var va: f64 = 0;
    var vb: f64 = 0;
    for (a, b) |x, y| {
        const da = x - mean_a;
        const db = y - mean_b;
        cov += da * db;
        va += da * da;
        vb += db * db;
    }
    if (va == 0 or vb == 0) return null;
    return cov / std.math.sqrt(va * vb);
}

fn renderOutput(
    allocator: std.mem.Allocator,
    req: Request,
    pool_source: []const u8,
    stock_pools: *const StockPools,
    stocks: []const StockData,
    lookback_start: []const u8,
    data_start: []const u8,
    data_end: []const u8,
    trading_dates: []const []const u8,
    observations: []const Observation,
    dates: []const []const u8,
    portfolio: []const PortfolioRow,
    metrics: Metrics,
    ic_results: []const IcResult,
    factor_cache_stats: FactorCacheStats,
) ![]u8 {
    var out = std.io.Writer.Allocating.init(allocator);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try writeResult(&s, allocator, req, pool_source, stock_pools, stocks, lookback_start, data_start, data_end, trading_dates, observations, dates, portfolio, metrics, ic_results, factor_cache_stats);
    return out.toOwnedSlice();
}

fn writeResult(
    s: *std.json.Stringify,
    allocator: std.mem.Allocator,
    req: Request,
    pool_source: []const u8,
    stock_pools: *const StockPools,
    stocks: []const StockData,
    lookback_start: []const u8,
    data_start: []const u8,
    data_end: []const u8,
    trading_dates: []const []const u8,
    observations: []const Observation,
    dates: []const []const u8,
    portfolio: []const PortfolioRow,
    metrics: Metrics,
    ic_results: []const IcResult,
    factor_cache_stats: FactorCacheStats,
) !void {
    try s.beginObject();
    try s.objectField("config");
    try s.beginObject();
    try s.objectField("factors");
    try s.beginArray();
    for (req.factors.items) |factor| try s.write(factor.key());
    try s.endArray();
    try s.objectField("factor_labels");
    try writeFactorLabels(s, req.factors.items);
    try s.objectField("factor_definitions");
    try writeFactorDefinitions(s, req.factors.items);
    try s.objectField("start_date");
    try s.write(req.start_date);
    try s.objectField("end_date");
    try s.write(req.end_date);
    try s.objectField("rebalance_period");
    try s.write(req.rebalance_period);
    try s.objectField("top_pct");
    try s.write(req.top_pct);
    try s.objectField("bottom_pct");
    try s.write(req.bottom_pct);
    try s.objectField("pool_size");
    try s.write(req.pool_size);
    try s.objectField("pool_mode");
    try s.write(poolModeName(req.pool_mode));
    try s.objectField("industry");
    if (req.industry) |industry| try s.write(industry) else try s.write(null);
    try s.objectField("pool_source");
    try s.write(pool_source);
    try s.objectField("lookback_start");
    try s.write(lookback_start);
    try s.objectField("data_start");
    try s.write(data_start);
    try s.objectField("data_end");
    try s.write(data_end);
    try s.objectField("commission_rate");
    try s.write(req.commission_rate);
    try s.objectField("stamp_tax_rate");
    try s.write(req.stamp_tax_rate);
    try s.objectField("slippage_rate");
    try s.write(req.slippage_rate);
    try s.objectField("min_amount");
    try s.write(req.min_amount);
    try s.objectField("min_listed_days");
    try s.write(req.min_listed_days);
    try s.objectField("limit_pct");
    try s.write(req.limit_pct);
    try s.objectField("execution_price");
    try s.write(executionModeName(req.execution_mode));
    try s.objectField("benchmark");
    try s.write("pool_equal_weight");
    try s.objectField("factor_cache");
    try writeFactorCacheStats(s, factor_cache_stats);
    try s.endObject();

    try s.objectField("metrics");
    try s.beginObject();
    try s.objectField("total_return");
    try s.write(metrics.total_return);
    try s.objectField("annualized_return");
    try s.write(metrics.annualized_return);
    try s.objectField("benchmark_total_return");
    try s.write(metrics.benchmark_total_return);
    try s.objectField("benchmark_annualized_return");
    try s.write(metrics.benchmark_annualized_return);
    try s.objectField("excess_total_return");
    try s.write(metrics.excess_total_return);
    try s.objectField("max_drawdown");
    try s.write(metrics.max_drawdown);
    try s.objectField("sharpe_ratio");
    try s.write(metrics.sharpe_ratio);
    try s.objectField("information_ratio");
    try s.write(metrics.information_ratio);
    try s.objectField("num_periods");
    try s.write(metrics.num_periods);
    try s.objectField("periods_per_year");
    try s.write(metrics.periods_per_year);
    try s.endObject();

    try s.objectField("portfolio");
    try s.beginArray();
    for (portfolio) |row| {
        try s.beginObject();
        try s.objectField("date");
        try s.write(row.date);
        try s.objectField("long_return");
        try s.write(row.long_return);
        try s.objectField("short_return");
        try s.write(row.short_return);
        try s.objectField("ls_return");
        try s.write(row.ls_return);
        try s.objectField("gross_return");
        try s.write(row.gross_return);
        try s.objectField("net_return");
        try s.write(row.net_return);
        try s.objectField("benchmark_return");
        try s.write(row.benchmark_return);
        try s.objectField("excess_return");
        try s.write(row.excess_return);
        try s.objectField("turnover");
        try s.write(row.turnover);
        try s.objectField("buy_turnover");
        try s.write(row.buy_turnover);
        try s.objectField("sell_turnover");
        try s.write(row.sell_turnover);
        try s.objectField("cost");
        try s.write(row.cost);
        try s.objectField("net_value");
        try s.write(row.net_value);
        try s.objectField("benchmark_net_value");
        try s.write(row.benchmark_net_value);
        try s.objectField("excess_net_value");
        try s.write(row.excess_net_value);
        try s.objectField("cumulative_return");
        try s.write(row.cumulative_return);
        try s.objectField("drawdown");
        try s.write(row.drawdown);
        try s.objectField("n_stocks");
        try s.write(row.n_stocks);
        try s.objectField("n_long");
        try s.write(row.n_long);
        try s.objectField("n_short");
        try s.write(row.n_short);
        try s.objectField("n_buy_blocked");
        try s.write(row.n_buy_blocked);
        try s.objectField("n_sell_blocked");
        try s.write(row.n_sell_blocked);
        try s.objectField("n_benchmark");
        try s.write(row.n_benchmark);
        try s.objectField("long_holdings");
        try writeHoldings(s, row.long_holdings.items, req.factors.items);
        try s.objectField("short_holdings");
        try writeHoldings(s, row.short_holdings.items, req.factors.items);
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("ic_analysis");
    try s.beginObject();
    for (req.factors.items, 0..) |factor, i| {
        try s.objectField(factor.key());
        try s.beginObject();
        try s.objectField("ic_mean");
        try s.write(ic_results[i].mean);
        try s.objectField("ic_std");
        try s.write(ic_results[i].std);
        try s.objectField("icir");
        try s.write(ic_results[i].icir);
        try s.objectField("ic_positive_ratio");
        try s.write(ic_results[i].positive_ratio);
        try s.endObject();
    }
    try s.endObject();
    try s.objectField("factor_research");
    try writeFactorResearch(s, allocator, observations, dates, req.factors.items);
    try s.objectField("data_quality");
    try writeDataQuality(s, allocator, req, stock_pools, stocks, lookback_start, data_start, data_end, trading_dates, dates, observations);
    try s.endObject();
}

fn writeFactorCacheStats(s: *std.json.Stringify, stats: FactorCacheStats) !void {
    try s.beginObject();
    try s.objectField("enabled");
    try s.write(stats.enabled);
    try s.objectField("version");
    try s.write(FACTOR_CACHE_VERSION);
    try s.objectField("requested");
    try s.write(stats.requested);
    try s.objectField("cacheable");
    try s.write(stats.cacheable);
    try s.objectField("hits");
    try s.write(stats.hits);
    try s.objectField("misses");
    try s.write(stats.misses);
    try s.objectField("unavailable");
    try s.write(stats.unavailable);
    try s.objectField("writes");
    try s.write(stats.writes);
    try s.objectField("hit_rate");
    try s.write(stats.hit_rate);
    try s.endObject();
}

fn writeFactorLabels(s: *std.json.Stringify, factors: []const FactorSpec) !void {
    try s.beginObject();
    for (factors) |factor| {
        try s.objectField(factor.key());
        try s.write(factor.label());
    }
    try s.endObject();
}

fn writeFactorDefinitions(s: *std.json.Stringify, factors: []const FactorSpec) !void {
    try s.beginArray();
    for (factors) |factor| {
        try s.beginObject();
        try s.objectField("key");
        try s.write(factor.key());
        try s.objectField("name");
        try s.write(factor.label());
        try s.objectField("lookback");
        try s.write(factor.lookback());
        switch (factor) {
            .builtin => |builtin| {
                try s.objectField("type");
                try s.write("builtin");
                try s.objectField("description");
                try s.write(factorName(builtin));
            },
            .custom => |custom| {
                try s.objectField("type");
                try s.write("custom");
                try s.objectField("description");
                try s.write(custom.description);
                try s.objectField("schema_version");
                try s.write(custom.schema_version);
                try s.objectField("engine_version");
                try s.write(custom.engine_version);
                try s.objectField("components");
                try s.beginArray();
                for (custom.components) |component| {
                    try s.beginObject();
                    try s.objectField("kind");
                    try s.write(config.factor_specs.componentKindName(component.kind));
                    try s.objectField("field");
                    if (component.field) |field| try s.write(config.factor_specs.fieldName(field)) else try s.write(null);
                    try s.objectField("window");
                    if (component.window) |window| try s.write(window) else try s.write(null);
                    try s.objectField("short_window");
                    if (component.short_window) |window| try s.write(window) else try s.write(null);
                    try s.objectField("long_window");
                    if (component.long_window) |window| try s.write(window) else try s.write(null);
                    try s.objectField("direction");
                    try s.write(config.factor_specs.directionName(component.direction));
                    try s.objectField("weight");
                    try s.write(component.weight);
                    try s.endObject();
                }
                try s.endArray();
            },
        }
        try s.endObject();
    }
    try s.endArray();
}

fn writeHoldings(s: *std.json.Stringify, holdings: []const Holding, factors: []const FactorSpec) !void {
    try s.beginArray();
    for (holdings) |holding| {
        try s.beginObject();
        try s.objectField("symbol");
        try s.write(holding.symbol);
        try s.objectField("weight");
        try s.write(holding.weight);
        try s.objectField("score");
        try s.write(holding.score);
        try s.objectField("forward_return");
        try s.write(holding.forward_return);
        try s.objectField("buyable");
        try s.write(holding.buyable);
        try s.objectField("sellable");
        try s.write(holding.sellable);
        try s.objectField("carried");
        try s.write(holding.carried);
        try s.objectField("entry_price");
        try s.write(holding.entry_price);
        try s.objectField("exit_price");
        try s.write(holding.exit_price);
        try s.objectField("factors");
        try s.beginObject();
        for (factors, 0..) |factor, i| {
            try s.objectField(factor.key());
            try s.write(holding.factors[i]);
        }
        try s.endObject();
        try s.objectField("factor_scores");
        try s.beginObject();
        for (factors, 0..) |factor, i| {
            try s.objectField(factor.key());
            try s.write(holding.factor_scores[i]);
        }
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();
}

fn writeFactorResearch(
    s: *std.json.Stringify,
    allocator: std.mem.Allocator,
    observations: []const Observation,
    dates: []const []const u8,
    factors: []const FactorSpec,
) !void {
    try s.beginObject();
    for (factors, 0..) |factor, fi| {
        try s.objectField(factor.key());
        try s.beginObject();
        try s.objectField("observation_count");
        try s.write(countPoolObservations(observations));
        try s.objectField("date_count");
        try s.write(dates.len);

        var quintile_sums = [_]f64{0} ** 5;
        var quintile_counts = [_]usize{0} ** 5;

        try s.objectField("ic_series");
        try s.beginArray();
        for (dates) |date| {
            var group = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
            defer group.deinit(allocator);
            for (observations, 0..) |obs, i| {
                if (obs.in_pool and std.mem.eql(u8, obs.date, date)) try group.append(allocator, i);
            }
            if (group.items.len < 5) continue;

            if (spearman(allocator, observations, group.items, fi, factor)) |ic| {
                try s.beginObject();
                try s.objectField("date");
                try s.write(date);
                try s.objectField("ic");
                try s.write(ic);
                try s.endObject();
            }

            for (group.items) |idx| {
                const pct = directedRankPct(observations, group.items, fi, idx, factor);
                var bucket = @as(usize, @intFromFloat(pct * 5.0));
                if (bucket >= 5) bucket = 4;
                quintile_sums[bucket] += observations[idx].forward_return;
                quintile_counts[bucket] += 1;
            }
        }
        try s.endArray();

        try s.objectField("quintile_returns");
        try s.beginArray();
        for (0..5) |i| {
            const value = if (quintile_counts[i] > 0) quintile_sums[i] / @as(f64, @floatFromInt(quintile_counts[i])) else 0;
            try s.write(value);
        }
        try s.endArray();

        try s.objectField("quintile_counts");
        try s.beginArray();
        for (0..5) |i| try s.write(quintile_counts[i]);
        try s.endArray();

        try s.endObject();
    }
    try s.endObject();
}

fn countPoolObservations(observations: []const Observation) usize {
    var count: usize = 0;
    for (observations) |obs| {
        if (obs.in_pool) count += 1;
    }
    return count;
}

const DataQualityStats = struct {
    status: []const u8,
    price_status: []const u8,
    date_status: []const u8,
    symbol_status: []const u8,
    observation_status: []const u8,
    pool_status: []const u8,
    factor_time_status: []const u8,
    entry_time_status: []const u8,
    exit_time_status: []const u8,
    pe_time_status: []const u8,
    requested_symbols: usize,
    loaded_symbols: usize,
    missing_symbols: usize,
    price_load_rate: f64,
    market_trading_days: usize,
    rebalance_count: usize,
    expected_observations: usize,
    valid_observations: usize,
    valid_observation_rate: f64,
    expected_pool_observations: usize,
    valid_pool_observations: usize,
    pool_observation_rate: f64,
    avg_symbol_day_coverage: f64,
    low_symbol_coverage_count: usize,
    factor_future_violations: usize,
    pe_future_violations: usize,
    entry_time_violations: usize,
    exit_before_entry: usize,
    exit_after_next_rebalance: usize,
    stale_factor_rows: usize,
};

fn buildDataQualityStats(
    req: Request,
    stock_pools: *const StockPools,
    stocks: []const StockData,
    trading_dates: []const []const u8,
    rebalance_dates: []const []const u8,
    observations: []const Observation,
) DataQualityStats {
    const requested_symbols = stock_pools.union_symbols.items.len;
    const loaded_symbols = stocks.len;
    const missing_symbols = if (requested_symbols > loaded_symbols) requested_symbols - loaded_symbols else 0;
    const price_load_rate = ratio(loaded_symbols, requested_symbols);
    const price_status = if (price_load_rate < 0.8) "fail" else if (price_load_rate < 0.95) "warn" else "pass";
    const date_status = if (trading_dates.len >= 2) "pass" else "fail";

    var coverage_sum: f64 = 0;
    var low_symbol_coverage_count: usize = 0;
    const market_days = @max(trading_dates.len, 1);
    for (stocks) |stock| {
        var days: usize = 0;
        for (stock.prices.items) |row| {
            if (std.mem.order(u8, row.date, req.start_date) != .lt and std.mem.order(u8, row.date, req.end_date) != .gt) {
                days += 1;
            }
        }
        const rate = ratio(days, market_days);
        coverage_sum += rate;
        if (rate < 0.8) low_symbol_coverage_count += 1;
    }
    const avg_symbol_day_coverage = if (stocks.len > 0) coverage_sum / @as(f64, @floatFromInt(stocks.len)) else 0;
    const symbol_status = if (avg_symbol_day_coverage < 0.7) "fail" else if (avg_symbol_day_coverage < 0.9 or low_symbol_coverage_count > 0) "warn" else "pass";

    const expected_observations = requested_symbols * rebalance_dates.len;
    const valid_observations = observations.len;
    const valid_observation_rate = ratio(valid_observations, expected_observations);
    const observation_status = if (valid_observation_rate < 0.5) "fail" else if (valid_observation_rate < 0.8) "warn" else "pass";

    var expected_pool_observations: usize = 0;
    for (stock_pools.pools.items) |pool| expected_pool_observations += pool.symbols.items.len;
    const valid_pool_observations = countPoolObservations(observations);
    const pool_observation_rate = ratio(valid_pool_observations, expected_pool_observations);
    const pool_status = if (pool_observation_rate < 0.6) "fail" else if (pool_observation_rate < 0.85) "warn" else "pass";

    var factor_future_violations: usize = 0;
    var pe_future_violations: usize = 0;
    var entry_time_violations: usize = 0;
    var exit_before_entry: usize = 0;
    var exit_after_next_rebalance: usize = 0;
    var stale_factor_rows: usize = 0;
    for (observations) |obs| {
        if (std.mem.order(u8, obs.factor_date, obs.date) == .gt) factor_future_violations += 1;
        if (std.mem.order(u8, obs.factor_date, obs.date) == .lt) stale_factor_rows += 1;
        if (obs.pe_max_date) |pe_date| {
            if (std.mem.order(u8, pe_date, obs.date) == .gt) pe_future_violations += 1;
        }
        switch (req.execution_mode) {
            .next_open => {
                if (std.mem.order(u8, obs.entry_date, obs.date) != .gt) entry_time_violations += 1;
            },
            .close => {
                if (std.mem.order(u8, obs.entry_date, obs.date) == .gt) entry_time_violations += 1;
            },
        }
        if (std.mem.order(u8, obs.exit_date, obs.entry_date) != .gt) exit_before_entry += 1;
        if (obs.next_rebalance_date) |next_date| {
            if (std.mem.order(u8, obs.exit_date, next_date) == .gt) exit_after_next_rebalance += 1;
        }
    }
    const factor_time_status = if (factor_future_violations > 0) "fail" else if (stale_factor_rows > 0) "warn" else "pass";
    const entry_time_status = if (entry_time_violations > 0) "fail" else "pass";
    const exit_time_status = if (exit_before_entry > 0 or exit_after_next_rebalance > 0) "fail" else "pass";
    const pe_time_status = if (pe_future_violations > 0) "fail" else "pass";
    const status = overallQualityStatus(&.{
        price_status,
        date_status,
        symbol_status,
        observation_status,
        pool_status,
        factor_time_status,
        entry_time_status,
        exit_time_status,
        pe_time_status,
    });

    return DataQualityStats{
        .status = status,
        .price_status = price_status,
        .date_status = date_status,
        .symbol_status = symbol_status,
        .observation_status = observation_status,
        .pool_status = pool_status,
        .factor_time_status = factor_time_status,
        .entry_time_status = entry_time_status,
        .exit_time_status = exit_time_status,
        .pe_time_status = pe_time_status,
        .requested_symbols = requested_symbols,
        .loaded_symbols = loaded_symbols,
        .missing_symbols = missing_symbols,
        .price_load_rate = price_load_rate,
        .market_trading_days = trading_dates.len,
        .rebalance_count = rebalance_dates.len,
        .expected_observations = expected_observations,
        .valid_observations = valid_observations,
        .valid_observation_rate = valid_observation_rate,
        .expected_pool_observations = expected_pool_observations,
        .valid_pool_observations = valid_pool_observations,
        .pool_observation_rate = pool_observation_rate,
        .avg_symbol_day_coverage = avg_symbol_day_coverage,
        .low_symbol_coverage_count = low_symbol_coverage_count,
        .factor_future_violations = factor_future_violations,
        .pe_future_violations = pe_future_violations,
        .entry_time_violations = entry_time_violations,
        .exit_before_entry = exit_before_entry,
        .exit_after_next_rebalance = exit_after_next_rebalance,
        .stale_factor_rows = stale_factor_rows,
    };
}

fn ratio(numerator: usize, denominator: usize) f64 {
    return if (denominator > 0)
        @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator))
    else
        0;
}

fn overallQualityStatus(statuses: []const []const u8) []const u8 {
    var has_warn = false;
    for (statuses) |status| {
        if (std.mem.eql(u8, status, "fail")) return "fail";
        if (std.mem.eql(u8, status, "warn")) has_warn = true;
    }
    return if (has_warn) "warn" else "pass";
}

fn writeDataQuality(
    s: *std.json.Stringify,
    allocator: std.mem.Allocator,
    req: Request,
    stock_pools: *const StockPools,
    stocks: []const StockData,
    lookback_start: []const u8,
    data_start: []const u8,
    data_end: []const u8,
    trading_dates: []const []const u8,
    rebalance_dates: []const []const u8,
    observations: []const Observation,
) !void {
    const stats = buildDataQualityStats(req, stock_pools, stocks, trading_dates, rebalance_dates, observations);
    try s.beginObject();
    try s.objectField("status");
    try s.write(stats.status);

    try s.objectField("summary");
    try s.beginObject();
    try s.objectField("requested_symbols");
    try s.write(stats.requested_symbols);
    try s.objectField("loaded_symbols");
    try s.write(stats.loaded_symbols);
    try s.objectField("missing_symbols");
    try s.write(stats.missing_symbols);
    try s.objectField("price_load_rate");
    try s.write(stats.price_load_rate);
    try s.objectField("market_trading_days");
    try s.write(stats.market_trading_days);
    try s.objectField("rebalance_count");
    try s.write(stats.rebalance_count);
    try s.objectField("expected_observations");
    try s.write(stats.expected_observations);
    try s.objectField("valid_observations");
    try s.write(stats.valid_observations);
    try s.objectField("valid_observation_rate");
    try s.write(stats.valid_observation_rate);
    try s.objectField("expected_pool_observations");
    try s.write(stats.expected_pool_observations);
    try s.objectField("valid_pool_observations");
    try s.write(stats.valid_pool_observations);
    try s.objectField("pool_observation_rate");
    try s.write(stats.pool_observation_rate);
    try s.objectField("avg_symbol_day_coverage");
    try s.write(stats.avg_symbol_day_coverage);
    try s.objectField("low_symbol_coverage_count");
    try s.write(stats.low_symbol_coverage_count);
    try s.objectField("stale_factor_rows");
    try s.write(stats.stale_factor_rows);
    try s.endObject();

    try s.objectField("date_coverage");
    try s.beginObject();
    try s.objectField("requested_start");
    try s.write(req.start_date);
    try s.objectField("requested_end");
    try s.write(req.end_date);
    try s.objectField("lookback_start");
    try s.write(lookback_start);
    try s.objectField("data_start");
    try s.write(data_start);
    try s.objectField("data_end");
    try s.write(data_end);
    try s.objectField("start_gap_days");
    try s.write(0);
    try s.objectField("end_gap_days");
    try s.write(0);
    try s.endObject();

    try s.objectField("future_leakage");
    try s.beginObject();
    try s.objectField("factor_future_violations");
    try s.write(stats.factor_future_violations);
    try s.objectField("pe_future_violations");
    try s.write(stats.pe_future_violations);
    try s.objectField("entry_time_violations");
    try s.write(stats.entry_time_violations);
    try s.objectField("exit_before_entry");
    try s.write(stats.exit_before_entry);
    try s.objectField("exit_after_next_rebalance");
    try s.write(stats.exit_after_next_rebalance);
    try s.objectField("stale_factor_rows");
    try s.write(stats.stale_factor_rows);
    try s.endObject();

    try s.objectField("checks");
    try s.beginArray();
    const detail = try std.fmt.allocPrint(allocator, "{d}/{d} 只股票有可用行情", .{ stats.loaded_symbols, stats.requested_symbols });
    defer allocator.free(detail);
    try writeQualityCheck(s, "price_load", "行情加载覆盖率", stats.price_status, detail);

    const date_detail = try std.fmt.allocPrint(allocator, "市场交易日 {d} 天，实际区间 {s} ~ {s}", .{ stats.market_trading_days, data_start, data_end });
    defer allocator.free(date_detail);
    try writeQualityCheck(s, "date_coverage", "回测日期覆盖", stats.date_status, date_detail);

    const symbol_detail = try std.fmt.allocPrint(allocator, "平均覆盖率 {d:.1}%，低覆盖样本 {d} 只", .{ stats.avg_symbol_day_coverage * 100.0, stats.low_symbol_coverage_count });
    defer allocator.free(symbol_detail);
    try writeQualityCheck(s, "symbol_day_coverage", "个股交易日覆盖", stats.symbol_status, symbol_detail);

    const obs_detail = try std.fmt.allocPrint(allocator, "{d}/{d} 条股票-调仓日样本具备完整因子和未来收益", .{ stats.valid_observations, stats.expected_observations });
    defer allocator.free(obs_detail);
    try writeQualityCheck(s, "complete_observations", "完整因子观测", stats.observation_status, obs_detail);

    const pool_detail = try std.fmt.allocPrint(allocator, "{d}/{d} 条当期池内样本可用于排序", .{ stats.valid_pool_observations, stats.expected_pool_observations });
    defer allocator.free(pool_detail);
    try writeQualityCheck(s, "pool_observations", "股票池有效样本", stats.pool_status, pool_detail);

    const factor_detail = try std.fmt.allocPrint(allocator, "因子价格日期晚于调仓日 {d} 条，使用调仓日前最后行情 {d} 条", .{ stats.factor_future_violations, stats.stale_factor_rows });
    defer allocator.free(factor_detail);
    try writeQualityCheck(s, "factor_time_order", "因子时间截断", stats.factor_time_status, factor_detail);

    const entry_detail = if (req.execution_mode == .next_open)
        try std.fmt.allocPrint(allocator, "next_open 模式下，入场日期必须晚于调仓日；违规 {d} 条", .{stats.entry_time_violations})
    else
        try std.fmt.allocPrint(allocator, "close 模式下，入场价不得来自调仓日之后；违规 {d} 条", .{stats.entry_time_violations});
    defer allocator.free(entry_detail);
    try writeQualityCheck(s, "entry_time_order", "入场时间顺序", stats.entry_time_status, entry_detail);

    const exit_detail = try std.fmt.allocPrint(allocator, "退出日期不晚于入场日 {d} 条，退出晚于下一调仓日 {d} 条", .{ stats.exit_before_entry, stats.exit_after_next_rebalance });
    defer allocator.free(exit_detail);
    try writeQualityCheck(s, "exit_time_order", "退出时间顺序", stats.exit_time_status, exit_detail);

    const pe_detail = try std.fmt.allocPrint(allocator, "PE 数据日期晚于调仓日 {d} 条", .{stats.pe_future_violations});
    defer allocator.free(pe_detail);
    try writeQualityCheck(s, "pe_time_order", "PE数据日期截断", stats.pe_time_status, pe_detail);
    try s.endArray();

    try s.objectField("issues");
    try s.beginArray();
    if (std.mem.eql(u8, stats.status, "fail")) {
        if (std.mem.eql(u8, stats.factor_time_status, "fail")) try s.write("存在因子价格日期晚于调仓日的样本");
        if (std.mem.eql(u8, stats.pe_time_status, "fail")) try s.write("存在 PE 日期晚于调仓日的样本");
        if (std.mem.eql(u8, stats.entry_time_status, "fail")) try s.write("存在入场时间顺序违规样本");
        if (std.mem.eql(u8, stats.exit_time_status, "fail")) try s.write("存在退出时间顺序违规样本");
    }
    try s.endArray();

    try s.objectField("warnings");
    try s.beginArray();
    if (std.mem.eql(u8, stats.symbol_status, "warn")) try s.write("部分个股交易日覆盖偏低，可能来自新股、停牌或数据缺失");
    if (std.mem.eql(u8, stats.factor_time_status, "warn")) try s.write("部分样本使用调仓日前最后一条个股行情，通常来自停牌或缺失交易日");
    if (hasFactor(req.factors.items, .pe_percentile)) try s.write("PE历史百分位按估值日期截断；后续财报类因子应额外使用公告披露日");
    try s.endArray();

    try s.endObject();
}

fn writeQualityCheck(
    s: *std.json.Stringify,
    name: []const u8,
    label: []const u8,
    status: []const u8,
    detail: []const u8,
) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("label");
    try s.write(label);
    try s.objectField("status");
    try s.write(status);
    try s.objectField("detail");
    try s.write(detail);
    try s.endObject();
}

fn saveHistory(allocator: std.mem.Allocator, workspace_dir: []const u8, req: Request, metrics: Metrics) !void {
    const history_dir = try std.fmt.allocPrint(allocator, "{s}/.backtest_history", .{workspace_dir});
    defer allocator.free(history_dir);
    std.fs.makeDirAbsolute(history_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const id = try std.fmt.allocPrint(allocator, "{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(id);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ history_dir, id });
    defer allocator.free(path);

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };

    try s.beginObject();
    try s.objectField("id");
    try s.write(id);
    try s.objectField("ts");
    try s.write(id);
    try s.objectField("factors");
    try s.beginArray();
    for (req.factors.items) |factor| try s.write(factor.key());
    try s.endArray();
    try s.objectField("start");
    try s.write(req.start_date);
    try s.objectField("end");
    try s.write(req.end_date);
    try s.objectField("metrics");
    try s.beginObject();
    try s.objectField("total_return");
    try s.write(metrics.total_return);
    try s.objectField("annualized_return");
    try s.write(metrics.annualized_return);
    try s.objectField("benchmark_total_return");
    try s.write(metrics.benchmark_total_return);
    try s.objectField("benchmark_annualized_return");
    try s.write(metrics.benchmark_annualized_return);
    try s.objectField("excess_total_return");
    try s.write(metrics.excess_total_return);
    try s.objectField("max_drawdown");
    try s.write(metrics.max_drawdown);
    try s.objectField("sharpe_ratio");
    try s.write(metrics.sharpe_ratio);
    try s.objectField("information_ratio");
    try s.write(metrics.information_ratio);
    try s.objectField("num_periods");
    try s.write(metrics.num_periods);
    try s.objectField("periods_per_year");
    try s.write(metrics.periods_per_year);
    try s.endObject();
    try s.objectField("config");
    try s.beginObject();
    try s.objectField("factor_names");
    try s.beginArray();
    for (req.factors.items) |factor| try s.write(factor.key());
    try s.endArray();
    try s.objectField("start_date");
    try s.write(req.start_date);
    try s.objectField("end_date");
    try s.write(req.end_date);
    try s.objectField("rebalance_period");
    try s.write(req.rebalance_period);
    try s.objectField("top_pct");
    try s.write(req.top_pct);
    try s.objectField("bottom_pct");
    try s.write(req.bottom_pct);
    try s.objectField("pool_size");
    try s.write(req.pool_size);
    try s.objectField("pool_mode");
    try s.write(poolModeName(req.pool_mode));
    try s.objectField("industry");
    if (req.industry) |industry| try s.write(industry) else try s.write(null);
    try s.objectField("execution_price");
    try s.write(executionModeName(req.execution_mode));
    try s.endObject();
    try s.endObject();

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(out.written());
}
