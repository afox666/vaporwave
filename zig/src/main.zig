const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

extern fn daemon(nochdir: c_int, noclose: c_int) c_int;

const eastmoney = @import("eastmoney.zig");
const baidu = @import("baidu.zig");
const tencent = @import("tencent.zig");
const duckdb = @import("duckdb.zig");
const backtest = @import("backtest.zig");
const http = @import("http_helpers.zig");
const result_cache = @import("backtest_result_cache.zig");
const sql_text = @import("sql_text.zig");
const task_files = @import("backtest_task_files.zig");
const sync = @import("sync.zig");

const MAX_BACKTEST_TASKS = 50;
const MAX_CONCURRENT_BACKTEST_TASKS = 1;

const BacktestTaskStatus = enum {
    queued,
    running,
    completed,
    failed,
    cancelled,
    cancelling,
};

const BacktestTask = struct {
    id: []const u8,
    body: []const u8,
    db_path: []const u8,
    workspace_dir: []const u8,
    cache_key: []const u8,
    status: BacktestTaskStatus,
    progress: f64,
    stage: []const u8,
    message: []const u8,
    result: ?[]u8,
    error_message: ?[]u8,
    cancel_requested: bool,
    cache_hit: bool,
    queue_position: usize,
    created_at: []const u8,
    updated_at: []const u8,

    fn deinit(self: *BacktestTask, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.body);
        allocator.free(self.db_path);
        allocator.free(self.workspace_dir);
        allocator.free(self.cache_key);
        if (self.result) |result| allocator.free(result);
        if (self.error_message) |msg| allocator.free(msg);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        allocator.destroy(self);
    }
};

const BacktestTaskStore = struct {
    allocator: std.mem.Allocator = undefined,
    tasks: std.StringHashMap(*BacktestTask) = undefined,
    queue: std.ArrayList(*BacktestTask) = undefined,
    running_count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    initialized: bool = false,

    fn init(self: *BacktestTaskStore, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
        self.tasks = std.StringHashMap(*BacktestTask).init(allocator);
        self.queue = std.ArrayList(*BacktestTask){ .items = &.{}, .capacity = 0 };
        self.running_count = 0;
        self.initialized = true;
    }

    fn deinit(self: *BacktestTaskStore) void {
        if (!self.initialized) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.tasks.valueIterator();
        while (it.next()) |task| {
            task.*.deinit(self.allocator);
        }
        self.tasks.deinit();
        self.queue.deinit(self.allocator);
        self.initialized = false;
    }

    fn create(
        self: *BacktestTaskStore,
        body: []const u8,
        db_path: []const u8,
        cache_key: []const u8,
        cached_result: ?[]u8,
    ) !*BacktestTask {
        const allocator = self.allocator;
        const id = try makeBacktestTaskId(allocator);
        errdefer allocator.free(id);
        const body_copy = try allocator.dupe(u8, body);
        errdefer allocator.free(body_copy);
        const db_path_copy = try allocator.dupe(u8, db_path);
        errdefer allocator.free(db_path_copy);
        const workspace_dir_source = std.fs.path.dirname(db_path) orelse ".";
        const workspace_dir = try allocator.dupe(u8, workspace_dir_source);
        errdefer allocator.free(workspace_dir);
        const cache_key_copy = try allocator.dupe(u8, cache_key);
        errdefer allocator.free(cache_key_copy);
        const created_at = try allocTaskTimestamp(allocator);
        errdefer allocator.free(created_at);
        const updated_at = try allocator.dupe(u8, created_at);
        errdefer allocator.free(updated_at);

        const task = try allocator.create(BacktestTask);
        const has_cache = cached_result != null;
        task.* = .{
            .id = id,
            .body = body_copy,
            .db_path = db_path_copy,
            .workspace_dir = workspace_dir,
            .cache_key = cache_key_copy,
            .status = if (has_cache) .completed else .queued,
            .progress = if (has_cache) 1.0 else 0.0,
            .stage = if (has_cache) "result_cache" else "queued",
            .message = if (has_cache) "命中回测结果缓存" else "等待回测任务启动",
            .result = cached_result,
            .error_message = null,
            .cancel_requested = false,
            .cache_hit = has_cache,
            .queue_position = 0,
            .created_at = created_at,
            .updated_at = updated_at,
        };
        errdefer task.deinit(allocator);

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.tasks.put(task.id, task);
        persistBacktestTaskLocked(task);
        return task;
    }

    fn cleanupLocked(self: *BacktestTaskStore) void {
        while (self.tasks.count() > MAX_BACKTEST_TASKS) {
            var it = self.tasks.iterator();
            var removed = false;
            while (it.next()) |entry| {
                const task = entry.value_ptr.*;
                if (!isTerminalTaskStatus(task.status)) continue;
                _ = self.tasks.remove(entry.key_ptr.*);
                task.deinit(self.allocator);
                removed = true;
                break;
            }
            if (!removed) break;
        }
    }

    fn findActiveByCacheKeyLocked(self: *BacktestTaskStore, cache_key: []const u8) ?*BacktestTask {
        var it = self.tasks.valueIterator();
        while (it.next()) |task_ptr| {
            const task = task_ptr.*;
            if (!std.mem.eql(u8, task.cache_key, cache_key)) continue;
            if ((task.status == .queued or task.status == .running) and !task.cancel_requested) return task;
        }
        return null;
    }

    fn enqueueLocked(self: *BacktestTaskStore, task: *BacktestTask) !void {
        try self.queue.append(self.allocator, task);
        self.refreshQueuePositionsLocked();
    }

    fn refreshQueuePositionsLocked(self: *BacktestTaskStore) void {
        for (self.queue.items, 0..) |task, i| {
            task.queue_position = i + 1;
            persistBacktestTaskLocked(task);
        }
    }

    fn removeFromQueueLocked(self: *BacktestTaskStore, task: *BacktestTask) void {
        var i: usize = 0;
        while (i < self.queue.items.len) : (i += 1) {
            if (self.queue.items[i] == task) {
                _ = self.queue.orderedRemove(i);
                break;
            }
        }
        task.queue_position = 0;
        persistBacktestTaskLocked(task);
        self.refreshQueuePositionsLocked();
    }
};

var backtest_task_store = BacktestTaskStore{};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var port: u16 = 8000;
    var db_path: ?[]const u8 = null;
    var sync_command: ?[]const u8 = null;
    var job_command: ?[]const u8 = null;
    var scheduler_command: ?[]const u8 = null;
    var sync_years: u16 = 10;
    var sync_limit: usize = 0;
    var job_top_n: u16 = 100;
    var scheduler_interval_seconds: u32 = 30;
    var scheduled_for: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch 8000;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len) {
            db_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--sync") and i + 1 < args.len) {
            sync_command = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--job") and i + 1 < args.len) {
            job_command = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--scheduler") and i + 1 < args.len) {
            scheduler_command = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--years") and i + 1 < args.len) {
            sync_years = std.fmt.parseInt(u16, args[i + 1], 10) catch 10;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--limit") and i + 1 < args.len) {
            sync_limit = std.fmt.parseInt(usize, args[i + 1], 10) catch 0;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--top-n") and i + 1 < args.len) {
            job_top_n = std.fmt.parseInt(u16, args[i + 1], 10) catch 100;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--interval-seconds") and i + 1 < args.len) {
            scheduler_interval_seconds = std.fmt.parseInt(u32, args[i + 1], 10) catch 30;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--scheduled-for") and i + 1 < args.len) {
            scheduled_for = args[i + 1];
            i += 1;
        }
    }

    if (sync_command) |command| {
        if (db_path) |p| {
            var db = try openDatabase(allocator, p);
            defer db.close();
            try sync.run(allocator, &db, command, sync_years, sync_limit);
        } else {
            std.debug.print("同步命令需要指定可打开的 --db <path>\n", .{});
            return error.MissingDatabase;
        }
        return;
    }

    if (job_command) |command| {
        if (db_path) |p| {
            var db = try openDatabase(allocator, p);
            defer db.close();
            const summary = try runJobCommand(allocator, &db, command, job_top_n, sync_limit, scheduled_for);
            defer allocator.free(summary);
            std.debug.print("{s}\n", .{summary});
        } else {
            std.debug.print("任务命令需要指定可打开的 --db <path>\n", .{});
            return error.MissingDatabase;
        }
        return;
    }

    if (scheduler_command) |command| {
        if (db_path) |p| {
            const actual_command = blk: {
                if (std.mem.eql(u8, command, "daemonize")) {
                    if (daemon(1, 1) != 0) {
                        return error.DaemonizeFailed;
                    }
                    break :blk "run";
                }
                break :blk command;
            };
            if (std.mem.eql(u8, actual_command, "run")) {
                try runSchedulerLoopWithDbPath(allocator, p, scheduler_interval_seconds);
            } else {
                var db = try openDatabase(allocator, p);
                defer db.close();
                try runSchedulerCommand(allocator, &db, actual_command, scheduler_interval_seconds);
            }
        } else {
            std.debug.print("调度器命令需要指定可打开的 --db <path>\n", .{});
            return error.MissingDatabase;
        }
        return;
    }

    backtest_task_store.init(allocator);
    defer backtest_task_store.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    var server = try address.listen(.{ .reuse_address = true });
    const listen_port = server.listen_address.in.getPort();

    std.debug.print("Zig sidecar listening on http://127.0.0.1:{d}\n", .{listen_port});

    while (true) {
        const conn = try server.accept();
        errdefer conn.stream.close();

        handle_connection(allocator, conn.stream, db_path) catch |err| {
            std.debug.print("Connection error: {any}\n", .{err});
            conn.stream.close();
        };
    }
}

fn openDatabase(allocator: std.mem.Allocator, path: []const u8) !duckdb.Db {
    std.debug.print("Opening DuckDB: {s}\n", .{path});
    var db = try duckdb.Db.open(allocator, path);
    errdefer db.close();
    try initSchema(&db);
    return db;
}

fn initSchema(db: *duckdb.Db) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS daily_k (
        \\    symbol VARCHAR,
        \\    date DATE,
        \\    open DOUBLE,
        \\    close DOUBLE,
        \\    high DOUBLE,
        \\    low DOUBLE,
        \\    volume DOUBLE,
        \\    amount DOUBLE,
        \\    change_pct DOUBLE,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    PRIMARY KEY (symbol, date)
        \\)
    );
    try db.exec("CREATE INDEX IF NOT EXISTS idx_daily_k_date ON daily_k (date)");
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS sync_log (
        \\    symbol VARCHAR,
        \\    last_date DATE,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    PRIMARY KEY (symbol)
        \\)
    );
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS stock_info (
        \\    symbol VARCHAR PRIMARY KEY,
        \\    name VARCHAR,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    );
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS factor_daily (
        \\    symbol VARCHAR,
        \\    date DATE,
        \\    factor_name VARCHAR,
        \\    factor_value DOUBLE,
        \\    calc_version VARCHAR,
        \\    source VARCHAR,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    PRIMARY KEY (symbol, date, factor_name, calc_version)
        \\)
    );
    try db.exec("CREATE INDEX IF NOT EXISTS idx_factor_daily_lookup ON factor_daily (factor_name, date, symbol)");
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS scan_result (
        \\    scan_date DATE PRIMARY KEY,
        \\    top_n INTEGER,
        \\    total_stocks INTEGER,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    );
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS scan_stock (
        \\    scan_date DATE,
        \\    rank INTEGER,
        \\    symbol VARCHAR,
        \\    name VARCHAR,
        \\    price DOUBLE,
        \\    change_pct DOUBLE,
        \\    score DOUBLE,
        \\    industry VARCHAR,
        \\    PRIMARY KEY (scan_date, symbol)
        \\)
    );
    try db.exec("CREATE INDEX IF NOT EXISTS idx_scan_stock_date ON scan_stock (scan_date)");
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS job_config (
        \\    job_name VARCHAR PRIMARY KEY,
        \\    enabled BOOLEAN DEFAULT TRUE,
        \\    weekdays VARCHAR DEFAULT '1,2,3,4,5',
        \\    hour INTEGER DEFAULT 16,
        \\    minute INTEGER DEFAULT 10,
        \\    top_n INTEGER DEFAULT 100,
        \\    sync_limit INTEGER DEFAULT 0,
        \\    catch_up_minutes INTEGER DEFAULT 240,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    );
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS job_run_log (
        \\    job_name VARCHAR,
        \\    scheduled_for VARCHAR,
        \\    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    finished_at TIMESTAMP,
        \\    status VARCHAR,
        \\    exit_code INTEGER,
        \\    message VARCHAR,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    PRIMARY KEY (job_name, scheduled_for)
        \\)
    );
    try db.exec("CREATE INDEX IF NOT EXISTS idx_job_run_log_status ON job_run_log (status)");
    try db.exec(
        \\INSERT INTO job_config (job_name, enabled, weekdays, hour, minute, top_n, sync_limit, catch_up_minutes)
        \\SELECT 'scan-daily', TRUE, '1,2,3,4,5', 16, 10, 100, 0, 240
        \\WHERE NOT EXISTS (
        \\    SELECT 1 FROM job_config WHERE job_name = 'scan-daily'
        \\)
    );
    try db.exec(
        \\INSERT INTO job_config (job_name, enabled, weekdays, hour, minute, top_n, sync_limit, catch_up_minutes)
        \\SELECT 'sync-daily', TRUE, '1,2,3,4,5', 20, 30, 100, 0, 480
        \\WHERE NOT EXISTS (
        \\    SELECT 1 FROM job_config WHERE job_name = 'sync-daily'
        \\)
    );
}

const SchedulerClock = struct {
    current_date: []const u8,
    current_time: []const u8,
    weekday: u8,
    minute_of_day: i32,

    fn deinit(self: *const SchedulerClock, allocator: std.mem.Allocator) void {
        allocator.free(self.current_date);
        allocator.free(self.current_time);
    }
};

const SchedulerJobConfig = struct {
    job_name: []const u8,
    enabled: bool,
    weekdays: []const u8,
    hour: u8,
    minute: u8,
    top_n: u16,
    sync_limit: usize,
    catch_up_minutes: u16,
};

fn defaultSchedulerStatePath(allocator: std.mem.Allocator, db_path: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(db_path) orelse ".";
    return std.fmt.allocPrint(allocator, "{s}/.scheduler-state", .{dir});
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn buildJobsSummary(allocator: std.mem.Allocator, jobs: []const SchedulerJobConfig) ![]const u8 {
    var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);

    for (jobs, 0..) |job, idx| {
        if (idx > 0) try out.appendSlice(allocator, "; ");
        try out.writer(allocator).print(
            "{s}(enabled={s} weekdays={s} time={d:0>2}:{d:0>2} top_n={d} sync_limit={d} catch_up={d})",
            .{
                job.job_name,
                boolText(job.enabled),
                job.weekdays,
                job.hour,
                job.minute,
                job.top_n,
                job.sync_limit,
                job.catch_up_minutes,
            },
        );
    }

    return try out.toOwnedSlice(allocator);
}

fn writeSchedulerStateFile(
    allocator: std.mem.Allocator,
    state_path: []const u8,
    status: []const u8,
    clock: SchedulerClock,
    interval_seconds: u32,
    jobs_summary: []const u8,
    job_name: ?[]const u8,
    scheduled_for: ?[]const u8,
    message: ?[]const u8,
) !void {
    const safe_message = try sql_text.escape(allocator, message orelse "");
    defer allocator.free(safe_message);

    const content = try std.fmt.allocPrint(
        allocator,
        \\updated_at={s} {s}
        \\status={s}
        \\interval_seconds={d}
        \\jobs={s}
        \\job_name={s}
        \\scheduled_for={s}
        \\message={s}
        \\
    ,
        .{
            clock.current_date,
            clock.current_time,
            status,
            interval_seconds,
            jobs_summary,
            job_name orelse "",
            scheduled_for orelse "",
            safe_message,
        },
    );
    defer allocator.free(content);

    var file = try std.fs.createFileAbsolute(state_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn runJobCommand(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    command: []const u8,
    top_n: u16,
    limit: usize,
    scheduled_for: ?[]const u8,
) ![]const u8 {
    if (std.mem.eql(u8, command, "sync-daily")) {
        try sync.run(allocator, db, "update", 10, limit);
        return std.fmt.allocPrint(allocator, "job=sync-daily limit={d}", .{limit});
    }

    if (std.mem.eql(u8, command, "scan-daily")) {
        var scan = try runMarketScan(allocator, db, top_n);
        defer scan.deinit(allocator);

        const scan_date = try resolveScheduledScanDate(allocator, db, scheduled_for);
        defer allocator.free(scan_date);

        try saveScanToDb(db, allocator, scan_date, top_n, scan.items);
        return std.fmt.allocPrint(
            allocator,
            "job=scan-daily scan_date={s} source={s} total={d} data_date={s} coverage={d}",
            .{ scan_date, scan.source, scan.items.len, scan.data_date orelse "", scan.coverage_count },
        );
    }

    if (std.mem.eql(u8, command, "daily-pipeline")) {
        try sync.run(allocator, db, "update", 10, limit);

        var scan = try runMarketScan(allocator, db, top_n);
        defer scan.deinit(allocator);

        const scan_date = try resolveScheduledScanDate(allocator, db, scheduled_for);
        defer allocator.free(scan_date);

        try saveScanToDb(db, allocator, scan_date, top_n, scan.items);
        return std.fmt.allocPrint(
            allocator,
            "job=daily-pipeline scan_date={s} source={s} total={d} data_date={s} coverage={d} sync_limit={d}",
            .{ scan_date, scan.source, scan.items.len, scan.data_date orelse "", scan.coverage_count, limit },
        );
    }

    std.debug.print(
        \\用法:
        \\  --job sync-daily
        \\  --job scan-daily --top-n 100
        \\  --job daily-pipeline --top-n 100 --limit 200
        \\
    , .{});
    return error.InvalidJobCommand;
}

fn runSchedulerCommand(allocator: std.mem.Allocator, db: *duckdb.Db, command: []const u8, interval_seconds: u32) !void {
    _ = interval_seconds;
    if (std.mem.eql(u8, command, "once")) {
        try runSchedulerOnce(allocator, db, null, 0);
        return;
    }
    if (std.mem.eql(u8, command, "status")) {
        try showSchedulerStatus(allocator, db);
        return;
    }

    std.debug.print(
        \\用法:
        \\  --scheduler run --interval-seconds 30
        \\  --scheduler daemonize --interval-seconds 30
        \\  --scheduler once
        \\  --scheduler status
        \\
    , .{});
    return error.InvalidSchedulerCommand;
}

fn runSchedulerLoopWithDbPath(allocator: std.mem.Allocator, db_path: []const u8, interval_seconds: u32) !void {
    const effective_interval = if (interval_seconds > 0) interval_seconds else 30;
    const state_path = try defaultSchedulerStatePath(allocator, db_path);
    defer allocator.free(state_path);
    std.debug.print("[scheduler] started, interval={d}s\n", .{effective_interval});

    while (true) {
        var db = openDatabase(allocator, db_path) catch |err| blk: {
            std.debug.print("[scheduler] open db failed: {any}\n", .{err});
            break :blk null;
        };
        if (db) |*d| {
            runSchedulerOnce(allocator, d, state_path, effective_interval) catch |err| {
                std.debug.print("[scheduler] tick failed: {any}\n", .{err});
            };
            d.close();
        }
        std.Thread.sleep(@as(u64, effective_interval) * std.time.ns_per_s);
    }
}

fn runSchedulerOnce(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    state_path: ?[]const u8,
    interval_seconds: u32,
) !void {
    const clock = try loadSchedulerClock(allocator);
    defer clock.deinit(allocator);

    const jobs = try loadSchedulerJobs(allocator, db);
    defer freeSchedulerJobs(allocator, jobs);
    const jobs_summary = try buildJobsSummary(allocator, jobs);
    defer allocator.free(jobs_summary);

    var ran_jobs: usize = 0;

    for (jobs) |job| {
        if (!job.enabled or !isSafeJobName(job.job_name)) continue;
        if (!jobEnabledForWeekday(job.weekdays, clock.weekday)) continue;

        const scheduled_minute = @as(i32, job.hour) * 60 + @as(i32, job.minute);
        if (clock.minute_of_day < scheduled_minute) continue;

        const overdue = clock.minute_of_day - scheduled_minute;
        if (overdue > @as(i32, job.catch_up_minutes)) continue;

        const scheduled_for = try std.fmt.allocPrint(
            allocator,
            "{s}T{d:0>2}:{d:0>2}:00",
            .{ clock.current_date, job.hour, job.minute },
        );
        defer allocator.free(scheduled_for);

        if (try jobRunExists(allocator, db, job.job_name, scheduled_for)) continue;

        try markJobRunning(allocator, db, job.job_name, scheduled_for);
        if (state_path) |path| {
            writeSchedulerStateFile(
                allocator,
                path,
                "running",
                clock,
                interval_seconds,
                jobs_summary,
                job.job_name,
                scheduled_for,
                null,
            ) catch {};
        }
        std.debug.print("[scheduler] running {s} at {s}\n", .{ job.job_name, scheduled_for });

        const summary = runJobCommand(allocator, db, job.job_name, job.top_n, job.sync_limit, scheduled_for) catch |err| blk: {
            const failed_message = try std.fmt.allocPrint(allocator, "job={s} failed: {any}", .{ job.job_name, err });
            defer allocator.free(failed_message);
            try markJobFinished(allocator, db, job.job_name, scheduled_for, "failed", 1, failed_message);
            if (state_path) |path| {
                writeSchedulerStateFile(
                    allocator,
                    path,
                    "failed",
                    clock,
                    interval_seconds,
                    jobs_summary,
                    job.job_name,
                    scheduled_for,
                    failed_message,
                ) catch {};
            }
            std.debug.print("[scheduler] failed {s}: {any}\n", .{ job.job_name, err });
            break :blk null;
        };

        if (summary) |message| {
            defer allocator.free(message);
            try markJobFinished(allocator, db, job.job_name, scheduled_for, "success", 0, message);
            if (state_path) |path| {
                writeSchedulerStateFile(
                    allocator,
                    path,
                    "success",
                    clock,
                    interval_seconds,
                    jobs_summary,
                    job.job_name,
                    scheduled_for,
                    message,
                ) catch {};
            }
            std.debug.print("[scheduler] done {s}: {s}\n", .{ job.job_name, message });
            ran_jobs += 1;
        }
    }

    if (ran_jobs == 0) {
        if (state_path) |path| {
            writeSchedulerStateFile(
                allocator,
                path,
                "idle",
                clock,
                interval_seconds,
                jobs_summary,
                null,
                null,
                null,
            ) catch {};
        }
        std.debug.print("[scheduler] idle at {s} {s}\n", .{ clock.current_date, clock.current_time });
    }
}

fn showSchedulerStatus(allocator: std.mem.Allocator, db: *duckdb.Db) !void {
    const clock = try loadSchedulerClock(allocator);
    defer clock.deinit(allocator);

    std.debug.print("scheduler now: {s} {s} weekday={d}\n", .{ clock.current_date, clock.current_time, clock.weekday });

    var jobs = try db.queryRows(allocator,
        \\SELECT job_name, enabled, weekdays, hour, minute, top_n, sync_limit, catch_up_minutes
        \\FROM job_config
        \\ORDER BY job_name
    );
    defer jobs.deinit(allocator);

    std.debug.print("jobs:\n", .{});
    var i: usize = 0;
    while (i < jobs.rows.items.len) : (i += 1) {
        std.debug.print(
            "  {s}: enabled={s} schedule={s} {s}:{s} top_n={s} sync_limit={s} catch_up={s}m\n",
            .{
                jobs.getStr(i, "job_name") orelse "",
                jobs.getStr(i, "enabled") orelse "",
                jobs.getStr(i, "weekdays") orelse "",
                jobs.getStr(i, "hour") orelse "",
                jobs.getStr(i, "minute") orelse "",
                jobs.getStr(i, "top_n") orelse "",
                jobs.getStr(i, "sync_limit") orelse "",
                jobs.getStr(i, "catch_up_minutes") orelse "",
            },
        );
    }

    var logs = try db.queryRows(allocator,
        \\SELECT job_name, scheduled_for, status, COALESCE(message, '') AS message
        \\FROM job_run_log
        \\ORDER BY scheduled_for DESC
        \\LIMIT 10
    );
    defer logs.deinit(allocator);

    std.debug.print("recent runs:\n", .{});
    var r: usize = 0;
    while (r < logs.rows.items.len) : (r += 1) {
        std.debug.print(
            "  {s} {s} {s} {s}\n",
            .{
                logs.getStr(r, "job_name") orelse "",
                logs.getStr(r, "scheduled_for") orelse "",
                logs.getStr(r, "status") orelse "",
                logs.getStr(r, "message") orelse "",
            },
        );
    }
}

fn loadSchedulerClock(allocator: std.mem.Allocator) !SchedulerClock {
    var now: c.time_t = undefined;
    _ = c.time(&now);

    var local_tm: c.struct_tm = undefined;
    if (c.localtime_r(&now, &local_tm) == null) {
        return error.SchedulerClockUnavailable;
    }

    const current_date = try std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{
            @as(u16, @intCast(local_tm.tm_year + 1900)),
            @as(u8, @intCast(local_tm.tm_mon + 1)),
            @as(u8, @intCast(local_tm.tm_mday)),
        },
    );
    errdefer allocator.free(current_date);
    const current_time = try std.fmt.allocPrint(
        allocator,
        "{d:0>2}:{d:0>2}:{d:0>2}",
        .{
            @as(u8, @intCast(local_tm.tm_hour)),
            @as(u8, @intCast(local_tm.tm_min)),
            @as(u8, @intCast(local_tm.tm_sec)),
        },
    );
    errdefer allocator.free(current_time);

    const raw_weekday: u8 = @intCast(local_tm.tm_wday);
    const weekday: u8 = if (raw_weekday == 0) 7 else raw_weekday;
    const hour: i32 = @intCast(local_tm.tm_hour);
    const minute: i32 = @intCast(local_tm.tm_min);

    return SchedulerClock{
        .current_date = current_date,
        .current_time = current_time,
        .weekday = weekday,
        .minute_of_day = hour * 60 + minute,
    };
}

fn loadSchedulerJobs(allocator: std.mem.Allocator, db: *duckdb.Db) ![]const SchedulerJobConfig {
    var rows = try db.queryRows(allocator,
        \\SELECT job_name, enabled, weekdays, hour, minute, top_n, sync_limit, catch_up_minutes
        \\FROM job_config
        \\ORDER BY job_name
    );
    defer rows.deinit(allocator);

    var jobs = std.ArrayList(SchedulerJobConfig){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (jobs.items) |job| {
            allocator.free(job.job_name);
            allocator.free(job.weekdays);
        }
        jobs.deinit(allocator);
    }

    var i: usize = 0;
    while (i < rows.rows.items.len) : (i += 1) {
        try jobs.append(allocator, SchedulerJobConfig{
            .job_name = try allocator.dupe(u8, rows.getStr(i, "job_name") orelse ""),
            .enabled = parseBoolish(rows.getStr(i, "enabled") orelse "true"),
            .weekdays = try allocator.dupe(u8, rows.getStr(i, "weekdays") orelse "1,2,3,4,5"),
            .hour = std.fmt.parseInt(u8, rows.getStr(i, "hour") orelse "16", 10) catch 16,
            .minute = std.fmt.parseInt(u8, rows.getStr(i, "minute") orelse "10", 10) catch 10,
            .top_n = std.fmt.parseInt(u16, rows.getStr(i, "top_n") orelse "100", 10) catch 100,
            .sync_limit = std.fmt.parseInt(usize, rows.getStr(i, "sync_limit") orelse "0", 10) catch 0,
            .catch_up_minutes = std.fmt.parseInt(u16, rows.getStr(i, "catch_up_minutes") orelse "240", 10) catch 240,
        });
    }

    return try jobs.toOwnedSlice(allocator);
}

fn freeSchedulerJobs(allocator: std.mem.Allocator, jobs: []const SchedulerJobConfig) void {
    for (jobs) |job| {
        allocator.free(job.job_name);
        allocator.free(job.weekdays);
    }
    allocator.free(jobs);
}

fn parseBoolish(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "t");
}

fn isSafeJobName(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') continue;
        return false;
    }
    return true;
}

fn jobEnabledForWeekday(weekdays: []const u8, weekday: u8) bool {
    var iter = std.mem.splitScalar(u8, weekdays, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const value = std.fmt.parseInt(u8, trimmed, 10) catch continue;
        if (value == weekday) return true;
    }
    return false;
}

fn jobRunExists(allocator: std.mem.Allocator, db: *duckdb.Db, job_name: []const u8, scheduled_for: []const u8) !bool {
    const safe_job_name = if (isSafeJobName(job_name)) job_name else return false;
    const query = try std.fmt.allocPrint(
        allocator,
        "SELECT COUNT(*) AS cnt FROM job_run_log WHERE job_name = '{s}' AND scheduled_for = '{s}'",
        .{ safe_job_name, scheduled_for },
    );
    defer allocator.free(query);
    return (try queryCount(allocator, db, query)) > 0;
}

fn markJobRunning(allocator: std.mem.Allocator, db: *duckdb.Db, job_name: []const u8, scheduled_for: []const u8) !void {
    const safe_job_name = if (isSafeJobName(job_name)) job_name else return error.InvalidJobName;
    const query = try std.fmt.allocPrint(allocator,
        \\INSERT OR REPLACE INTO job_run_log (job_name, scheduled_for, started_at, finished_at, status, exit_code, message, updated_at)
        \\VALUES ('{s}', '{s}', CURRENT_TIMESTAMP, NULL, 'running', NULL, '', CURRENT_TIMESTAMP)
    , .{ safe_job_name, scheduled_for });
    defer allocator.free(query);
    try db.exec(query);
}

fn markJobFinished(
    allocator: std.mem.Allocator,
    db: *duckdb.Db,
    job_name: []const u8,
    scheduled_for: []const u8,
    status: []const u8,
    exit_code: i32,
    message: []const u8,
) !void {
    const safe_job_name = if (isSafeJobName(job_name)) job_name else return error.InvalidJobName;
    const escaped = try sql_text.escape(allocator, message);
    defer allocator.free(escaped);

    const query = try std.fmt.allocPrint(allocator,
        \\UPDATE job_run_log
        \\SET finished_at = CURRENT_TIMESTAMP,
        \\    status = '{s}',
        \\    exit_code = {d},
        \\    message = '{s}',
        \\    updated_at = CURRENT_TIMESTAMP
        \\WHERE job_name = '{s}' AND scheduled_for = '{s}'
    , .{ status, exit_code, escaped, safe_job_name, scheduled_for });
    defer allocator.free(query);
    try db.exec(query);
}

fn resolveScheduledScanDate(allocator: std.mem.Allocator, db: *duckdb.Db, scheduled_for: ?[]const u8) ![]const u8 {
    if (scheduled_for) |value| {
        if (value.len >= 10 and isSafeDate(value[0..10])) {
            return allocator.dupe(u8, value[0..10]);
        }
    }
    return currentDbDate(allocator, db);
}

fn currentDbDate(allocator: std.mem.Allocator, db: *duckdb.Db) ![]const u8 {
    return querySingleString(
        allocator,
        db,
        "SELECT CAST(CURRENT_DATE AS VARCHAR) AS d",
        "1970-01-01",
    );
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

fn makeBacktestTaskId(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [6]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    const out = try allocator.alloc(u8, bytes.len * 2);
    @memcpy(out, &hex);
    return out;
}

fn allocTaskTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()});
}

fn backtestTaskStatusName(status: BacktestTaskStatus) []const u8 {
    return switch (status) {
        .queued => "queued",
        .running => "running",
        .completed => "completed",
        .failed => "failed",
        .cancelled => "cancelled",
        .cancelling => "cancelling",
    };
}

fn isTerminalTaskStatus(status: BacktestTaskStatus) bool {
    return switch (status) {
        .completed, .failed, .cancelled => true,
        else => false,
    };
}

fn refreshBacktestTaskUpdatedAtLocked(task: *BacktestTask) void {
    const updated_at = allocTaskTimestamp(backtest_task_store.allocator) catch return;
    backtest_task_store.allocator.free(task.updated_at);
    task.updated_at = updated_at;
}

fn setBacktestTaskProgress(ctx: *anyopaque, stage: []const u8, progress: f64, message: []const u8) void {
    const task: *BacktestTask = @ptrCast(@alignCast(ctx));
    backtest_task_store.mutex.lock();
    defer backtest_task_store.mutex.unlock();
    if (isTerminalTaskStatus(task.status)) return;
    task.status = if (task.cancel_requested) .cancelling else .running;
    task.stage = stage;
    task.progress = progress;
    task.message = message;
    refreshBacktestTaskUpdatedAtLocked(task);
    persistBacktestTaskLocked(task);
}

fn isBacktestTaskCancelled(ctx: *anyopaque) bool {
    const task: *BacktestTask = @ptrCast(@alignCast(ctx));
    backtest_task_store.mutex.lock();
    defer backtest_task_store.mutex.unlock();
    return task.cancel_requested;
}

fn setBacktestTaskRunning(task: *BacktestTask) void {
    backtest_task_store.mutex.lock();
    defer backtest_task_store.mutex.unlock();
    if (isTerminalTaskStatus(task.status)) return;
    task.status = .running;
    task.progress = 0.01;
    task.stage = "queued";
    task.message = "回测任务已启动";
    refreshBacktestTaskUpdatedAtLocked(task);
    persistBacktestTaskLocked(task);
}

fn startQueuedBacktestTasks() void {
    var task_to_start: ?*BacktestTask = null;
    backtest_task_store.mutex.lock();
    if (backtest_task_store.running_count < MAX_CONCURRENT_BACKTEST_TASKS and backtest_task_store.queue.items.len > 0) {
        const task = backtest_task_store.queue.orderedRemove(0);
        task.queue_position = 0;
        task.status = .running;
        task.progress = @max(task.progress, 0.01);
        task.stage = "queued";
        task.message = "回测任务已启动";
        refreshBacktestTaskUpdatedAtLocked(task);
        backtest_task_store.running_count += 1;
        persistBacktestTaskLocked(task);
        backtest_task_store.refreshQueuePositionsLocked();
        task_to_start = task;
    }
    backtest_task_store.mutex.unlock();

    if (task_to_start) |task| {
        const thread = std.Thread.spawn(
            .{ .allocator = backtest_task_store.allocator },
            backtestTaskWorker,
            .{task},
        ) catch |err| {
            std.debug.print("Backtest task spawn error: {any}\n", .{err});
            setBacktestTaskFailed(task, "failed to start backtest task");
            finishBacktestTask(task);
            return;
        };
        thread.detach();
    }
}

fn finishBacktestTask(task: *BacktestTask) void {
    backtest_task_store.mutex.lock();
    if (backtest_task_store.running_count > 0) backtest_task_store.running_count -= 1;
    task.queue_position = 0;
    persistBacktestTaskLocked(task);
    backtest_task_store.mutex.unlock();
    startQueuedBacktestTasks();
}

fn setBacktestTaskCompleted(task: *BacktestTask, result: []u8) void {
    backtest_task_store.mutex.lock();
    defer backtest_task_store.mutex.unlock();
    if (task.result) |old| backtest_task_store.allocator.free(old);
    if (task.error_message) |old| {
        backtest_task_store.allocator.free(old);
        task.error_message = null;
    }
    task.result = result;
    task.status = .completed;
    task.progress = 1.0;
    task.stage = if (task.cache_hit) "result_cache" else "done";
    task.message = if (task.cache_hit) "命中回测结果缓存" else "回测完成";
    refreshBacktestTaskUpdatedAtLocked(task);
    persistBacktestTaskLocked(task);
}

fn setBacktestTaskCancelled(task: *BacktestTask) void {
    backtest_task_store.mutex.lock();
    defer backtest_task_store.mutex.unlock();
    task.status = .cancelled;
    task.stage = "cancelled";
    task.message = "回测已取消";
    refreshBacktestTaskUpdatedAtLocked(task);
    persistBacktestTaskLocked(task);
}

fn setBacktestTaskFailed(task: *BacktestTask, message: []const u8) void {
    const error_copy = backtest_task_store.allocator.dupe(u8, message) catch null;
    backtest_task_store.mutex.lock();
    defer backtest_task_store.mutex.unlock();
    if (task.error_message) |old| backtest_task_store.allocator.free(old);
    task.error_message = error_copy;
    task.status = .failed;
    task.stage = "failed";
    task.message = "回测运行失败";
    refreshBacktestTaskUpdatedAtLocked(task);
    persistBacktestTaskLocked(task);
}

fn backtestTaskCancelRequested(task: *BacktestTask) bool {
    backtest_task_store.mutex.lock();
    defer backtest_task_store.mutex.unlock();
    return task.cancel_requested;
}

fn backtestTaskWorker(task: *BacktestTask) void {
    const allocator = backtest_task_store.allocator;
    setBacktestTaskRunning(task);
    defer finishBacktestTask(task);

    if (result_cache.load(allocator, task.workspace_dir, task.cache_key) catch null) |cached| {
        backtest_task_store.mutex.lock();
        task.cache_hit = true;
        backtest_task_store.mutex.unlock();
        setBacktestTaskCompleted(task, cached);
        return;
    }

    var db = openDatabase(allocator, task.db_path) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "database open failed: {s}", .{@errorName(err)}) catch "database open failed";
        setBacktestTaskFailed(task, msg);
        return;
    };
    defer db.close();

    const result = backtest.runWithHooks(
        allocator,
        &db,
        task.body,
        task.workspace_dir,
        .{
            .ctx = task,
            .progress = setBacktestTaskProgress,
            .cancelled = isBacktestTaskCancelled,
        },
    ) catch |err| {
        if (err == error.Cancelled) {
            setBacktestTaskCancelled(task);
            return;
        }
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "backtest failed: {s}", .{@errorName(err)}) catch "backtest failed";
        setBacktestTaskFailed(task, msg);
        return;
    };

    if (backtestTaskCancelRequested(task)) {
        allocator.free(result);
        setBacktestTaskCancelled(task);
        return;
    }
    result_cache.save(allocator, task.workspace_dir, task.cache_key, result);
    setBacktestTaskCompleted(task, result);
}

fn renderBacktestTaskJsonLocked(allocator: std.mem.Allocator, task: *const BacktestTask) ![]u8 {
    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginObject();
    try s.objectField("task_id");
    try s.write(task.id);
    try s.objectField("status");
    try s.write(backtestTaskStatusName(task.status));
    try s.objectField("progress");
    try s.write(task.progress);
    try s.objectField("stage");
    try s.write(task.stage);
    try s.objectField("message");
    try s.write(task.message);
    try s.objectField("created_at");
    try s.write(task.created_at);
    try s.objectField("updated_at");
    try s.write(task.updated_at);
    try s.objectField("cache_key");
    try s.write(task.cache_key);
    try s.objectField("cache_hit");
    try s.write(task.cache_hit);
    try s.objectField("queue_position");
    try s.write(task.queue_position);
    try s.objectField("running_count");
    try s.write(backtest_task_store.running_count);
    try s.objectField("max_concurrent");
    try s.write(MAX_CONCURRENT_BACKTEST_TASKS);
    try s.objectField("request");
    try s.beginWriteRaw();
    try s.writer.writeAll(task.body);
    s.endWriteRaw();
    if (task.error_message) |msg| {
        try s.objectField("error");
        try s.write(msg);
    }
    if (task.result) |result| {
        try s.objectField("result");
        try s.beginWriteRaw();
        try s.writer.writeAll(result);
        s.endWriteRaw();
    }
    try s.endObject();
    return out.toOwnedSlice();
}

fn persistBacktestTaskLocked(task: *const BacktestTask) void {
    const body = renderBacktestTaskJsonLocked(backtest_task_store.allocator, task) catch |err| {
        std.debug.print("Backtest task render for persistence failed: {any}\n", .{err});
        return;
    };
    defer backtest_task_store.allocator.free(body);
    task_files.writeJson(backtest_task_store.allocator, task.workspace_dir, task.id, body);
}

fn renderBacktestTaskJson(allocator: std.mem.Allocator, task_id: []const u8) !?[]u8 {
    backtest_task_store.mutex.lock();
    defer backtest_task_store.mutex.unlock();
    const task = backtest_task_store.tasks.get(task_id) orelse return null;
    return try renderBacktestTaskJsonLocked(allocator, task);
}

fn listBacktestTasksJson(allocator: std.mem.Allocator, workspace_dir: []const u8, limit: usize) ![]u8 {
    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginArray();

    var count: usize = 0;
    backtest_task_store.mutex.lock();
    {
        defer backtest_task_store.mutex.unlock();
        var it = backtest_task_store.tasks.valueIterator();
        while (it.next()) |task_ptr| {
            if (count >= limit) break;
            const task = task_ptr.*;
            const body = try renderBacktestTaskJsonLocked(allocator, task);
            defer allocator.free(body);
            try s.beginWriteRaw();
            try s.writer.writeAll(body);
            s.endWriteRaw();
            count += 1;
        }
    }

    if (count < limit) {
        const dir_path = try task_files.storeDir(allocator, workspace_dir);
        defer allocator.free(dir_path);
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch null;
        if (dir) |*d| {
            defer d.close();
            var files = std.ArrayList(task_files.PersistedFile){ .items = &.{}, .capacity = 0 };
            defer {
                for (files.items) |file| allocator.free(file.name);
                files.deinit(allocator);
            }

            var iter = d.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
                const stat = d.statFile(entry.name) catch continue;
                const name = try allocator.dupe(u8, entry.name);
                errdefer allocator.free(name);
                try files.append(allocator, .{ .name = name, .mtime = stat.mtime });
            }
            std.mem.sort(task_files.PersistedFile, files.items, {}, task_files.newer);

            for (files.items) |file| {
                if (count >= limit) break;
                const task_id = file.name[0 .. file.name.len - ".json".len];

                backtest_task_store.mutex.lock();
                const loaded = backtest_task_store.tasks.contains(task_id);
                backtest_task_store.mutex.unlock();
                if (loaded) continue;

                const body = (try task_files.loadJson(allocator, workspace_dir, task_id, backtest_task_store.running_count, MAX_CONCURRENT_BACKTEST_TASKS)) orelse continue;
                defer allocator.free(body);
                try s.beginWriteRaw();
                try s.writer.writeAll(body);
                s.endWriteRaw();
                count += 1;
            }
        }
    }

    try s.endArray();
    return out.toOwnedSlice();
}

fn cancelBacktestTaskJson(allocator: std.mem.Allocator, task_id: []const u8) !?[]u8 {
    backtest_task_store.mutex.lock();
    defer backtest_task_store.mutex.unlock();
    const task = backtest_task_store.tasks.get(task_id) orelse return null;
    if (task.status == .queued) {
        backtest_task_store.removeFromQueueLocked(task);
        task.cancel_requested = true;
        task.status = .cancelled;
        task.stage = "cancelled";
        task.message = "回测已取消";
        refreshBacktestTaskUpdatedAtLocked(task);
        persistBacktestTaskLocked(task);
    } else if (!isTerminalTaskStatus(task.status)) {
        task.cancel_requested = true;
        task.status = .cancelling;
        task.stage = "cancelling";
        task.message = "正在取消回测任务";
        refreshBacktestTaskUpdatedAtLocked(task);
        persistBacktestTaskLocked(task);
    }
    return try renderBacktestTaskJsonLocked(allocator, task);
}

fn handle_connection(allocator: std.mem.Allocator, stream: std.net.Stream, db_path: ?[]const u8) !void {
    defer stream.close();

    var request = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer request.deinit(allocator);

    var header_len: ?usize = null;
    var body_len: usize = 0;
    while (true) {
        var buf: [4096]u8 = undefined;
        const bytes_read = try stream.read(&buf);
        if (bytes_read == 0) break;
        try request.appendSlice(allocator, buf[0..bytes_read]);

        if (header_len == null) {
            if (std.mem.indexOf(u8, request.items, "\r\n\r\n")) |idx| {
                header_len = idx + 4;
                body_len = http.parseContentLength(request.items[0..idx]);
            }
        }

        if (header_len) |hlen| {
            if (request.items.len >= hlen + body_len) break;
        }

        if (request.items.len > 10 * 1024 * 1024) {
            try http.respondError(allocator, stream, 500, "request too large");
            return;
        }
    }
    const request_data = request.items;
    const body_start = header_len orelse request_data.len;
    const body_end = @min(request_data.len, body_start + body_len);
    const request_body = request_data[body_start..body_end];
    var request_db: ?duckdb.Db = null;
    defer if (request_db) |*d| d.close();

    if (db_path) |path| {
        request_db = openDatabase(allocator, path) catch |err| blk: {
            std.debug.print("DuckDB open failed: {any}\n", .{err});
            break :blk null;
        };
    }
    const active_db = if (request_db) |*d| d else null;

    const newline = std.mem.indexOf(u8, request_data, "\r\n") orelse return;
    const request_line = request_data[0..newline];

    var line_iter = std.mem.splitScalar(u8, request_line, ' ');
    const method = line_iter.next() orelse return;
    const uri = line_iter.next() orelse return;

    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");

    if (!is_get and !is_post) {
        const ErrStruct = struct { err: []const u8 };
        const err_json = try std.json.Stringify.valueAlloc(allocator, ErrStruct{ .err = "Method not allowed" }, .{});
        try http.respond(stream, 405, err_json);
        return;
    }

    if (is_post and std.mem.startsWith(u8, uri, "/api/scan/run")) {
        try handle_scan(allocator, stream, uri, active_db);
        return;
    }

    if (is_post and std.mem.eql(u8, uri, "/api/backtest")) {
        try handle_backtest(allocator, stream, request_body, active_db, db_path);
        return;
    }

    if (is_post and std.mem.eql(u8, uri, "/api/backtest/tasks")) {
        try handle_backtest_task_create(allocator, stream, request_body, active_db, db_path);
        return;
    }

    if (is_post and std.mem.startsWith(u8, uri, "/api/backtest/tasks/") and std.mem.endsWith(u8, http.stripQuery(uri), "/cancel")) {
        const rest = http.stripQuery(uri)["/api/backtest/tasks/".len..];
        const task_id = rest[0 .. rest.len - "/cancel".len];
        try handle_backtest_task_cancel(allocator, stream, task_id);
        return;
    }

    if (!is_get) {
        try http.respondError(allocator, stream, 405, "method not allowed");
        return;
    }

    // GET /api/stock/search?q=xxx  (must check before /api/stock/ prefix)
    if (std.mem.startsWith(u8, uri, "/api/stock/search")) {
        try handle_search(allocator, stream, uri);
        return;
    }

    // GET /api/stock/{symbol}/...
    if (std.mem.startsWith(u8, uri, "/api/stock/")) {
        const rest_with_query = uri["/api/stock/".len..];
        const rest = http.stripQuery(rest_with_query);

        if (std.mem.endsWith(u8, rest, "/basic")) {
            try handle_stock_basic(allocator, stream, rest[0 .. rest.len - "/basic".len]);
            return;
        }
        if (std.mem.endsWith(u8, rest, "/kline")) {
            try handle_stock_kline(allocator, stream, rest[0 .. rest.len - "/kline".len]);
            return;
        }
        if (std.mem.endsWith(u8, rest, "/valuation")) {
            try handle_stock_valuation(allocator, stream, rest[0 .. rest.len - "/valuation".len]);
            return;
        }
        if (std.mem.endsWith(u8, rest, "/price-history")) {
            try handle_price_history(allocator, stream, rest[0 .. rest.len - "/price-history".len], uri, active_db);
            return;
        }
        if (std.mem.endsWith(u8, rest, "/industry")) {
            try handle_stock_industry(allocator, stream, rest[0 .. rest.len - "/industry".len], uri);
            return;
        }
        if (std.mem.endsWith(u8, rest, "/full")) {
            try handle_stock_full(allocator, stream, rest[0 .. rest.len - "/full".len], active_db);
            return;
        }
        if (std.mem.endsWith(u8, rest, "/profile")) {
            try handle_stock_profile(allocator, stream, rest[0 .. rest.len - "/profile".len]);
            return;
        }
        if (std.mem.endsWith(u8, rest, "/technical")) {
            try handle_stock_technical(allocator, stream, rest[0 .. rest.len - "/technical".len], active_db);
            return;
        }
    }

    // GET /api/daily-k/{symbol}?start_date=&end_date=
    if (std.mem.startsWith(u8, uri, "/api/daily-k/")) {
        var symbol = uri["/api/daily-k/".len..];
        // Strip query params from symbol
        if (std.mem.indexOfScalar(u8, symbol, '?')) |qidx| {
            symbol = symbol[0..qidx];
        }
        try handle_daily_k(allocator, stream, symbol, uri, active_db);
        return;
    }

    // GET /api/scan?top_n=N  (must check specific routes first)
    if (std.mem.eql(u8, uri, "/api/scan/history")) {
        try handle_scan_history(allocator, stream, active_db);
        return;
    }
    if (std.mem.startsWith(u8, uri, "/api/scan/history/")) {
        const date_str = uri["/api/scan/history/".len..];
        try handle_scan_history_detail(allocator, stream, date_str, active_db);
        return;
    }
    if (std.mem.startsWith(u8, uri, "/api/scan")) {
        try handle_scan(allocator, stream, uri, active_db);
        return;
    }

    // GET /api/factors
    if (std.mem.eql(u8, uri, "/api/factors")) {
        try handle_factors(stream);
        return;
    }

    if (std.mem.startsWith(u8, uri, "/api/futures")) {
        try handle_futures(allocator, stream, uri);
        return;
    }

    if (std.mem.eql(u8, uri, "/api/backtest/history")) {
        try handle_backtest_history(allocator, stream, db_path);
        return;
    }

    if (std.mem.eql(u8, http.stripQuery(uri), "/api/backtest/tasks")) {
        try handle_backtest_task_list(allocator, stream, uri, db_path);
        return;
    }

    if (std.mem.startsWith(u8, uri, "/api/backtest/tasks/")) {
        const task_id = http.stripQuery(uri)["/api/backtest/tasks/".len..];
        try handle_backtest_task_get(allocator, stream, task_id, db_path);
        return;
    }

    if (std.mem.eql(u8, uri, "/api/health")) {
        try http.respondJson(allocator, stream, 200, .{ .status = "ok" });
        return;
    }

    try http.respondError(allocator, stream, 404, "Not found");
}

fn handle_backtest_task_create(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    body: []const u8,
    db: ?*duckdb.Db,
    db_path: ?[]const u8,
) !void {
    const path = db_path orelse {
        try http.respondError(allocator, stream, 500, "database path is missing");
        return;
    };
    backtest.validateRequest(allocator, body) catch |err| {
        std.debug.print("Backtest task validation error: {any}\n", .{err});
        try http.respondError(allocator, stream, 400, "invalid backtest request");
        return;
    };

    const workspace_dir = std.fs.path.dirname(path) orelse ".";
    const cache_key = result_cache.makeKey(allocator, body, db) catch |err| {
        std.debug.print("Backtest cache key error: {any}\n", .{err});
        try http.respondError(allocator, stream, 500, "failed to build backtest cache key");
        return;
    };
    defer allocator.free(cache_key);

    {
        backtest_task_store.mutex.lock();
        defer backtest_task_store.mutex.unlock();
        backtest_task_store.cleanupLocked();
        if (backtest_task_store.findActiveByCacheKeyLocked(cache_key)) |active| {
            const body_json = try renderBacktestTaskJsonLocked(allocator, active);
            defer allocator.free(body_json);
            try http.respond(stream, 200, body_json);
            return;
        }
    }

    const cached_result = result_cache.load(allocator, workspace_dir, cache_key) catch null;
    const task = backtest_task_store.create(body, path, cache_key, cached_result) catch |err| {
        if (cached_result) |cached| allocator.free(cached);
        std.debug.print("Backtest task create error: {any}\n", .{err});
        try http.respondError(allocator, stream, 500, "failed to create backtest task");
        return;
    };

    if (cached_result == null) {
        backtest_task_store.mutex.lock();
        backtest_task_store.enqueueLocked(task) catch |err| {
            backtest_task_store.mutex.unlock();
            std.debug.print("Backtest task enqueue error: {any}\n", .{err});
            setBacktestTaskFailed(task, "failed to enqueue backtest task");
            const body_json = try renderBacktestTaskJsonLockedAfterLookup(allocator, task.id);
            defer allocator.free(body_json);
            try http.respond(stream, 200, body_json);
            return;
        };
        backtest_task_store.mutex.unlock();
        startQueuedBacktestTasks();
    }

    const body_json = try renderBacktestTaskJsonLockedAfterLookup(allocator, task.id);
    defer allocator.free(body_json);
    try http.respond(stream, 200, body_json);
}

fn renderBacktestTaskJsonLockedAfterLookup(allocator: std.mem.Allocator, task_id: []const u8) ![]u8 {
    return (try renderBacktestTaskJson(allocator, task_id)) orelse try std.json.Stringify.valueAlloc(
        allocator,
        .{ .err = "backtest task not found" },
        .{},
    );
}

fn handle_backtest_task_get(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    task_id: []const u8,
    db_path: ?[]const u8,
) !void {
    if (task_id.len == 0) {
        try http.respondError(allocator, stream, 404, "backtest task not found");
        return;
    }
    const body_json = (try renderBacktestTaskJson(allocator, task_id)) orelse blk: {
        const path = db_path orelse {
            try http.respondError(allocator, stream, 404, "backtest task not found");
            return;
        };
        const workspace_dir = std.fs.path.dirname(path) orelse ".";
        break :blk (try task_files.loadJson(allocator, workspace_dir, task_id, backtest_task_store.running_count, MAX_CONCURRENT_BACKTEST_TASKS)) orelse {
            try http.respondError(allocator, stream, 404, "backtest task not found");
            return;
        };
    };
    defer allocator.free(body_json);
    try http.respond(stream, 200, body_json);
}

fn handle_backtest_task_list(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    uri: []const u8,
    db_path: ?[]const u8,
) !void {
    const path = db_path orelse {
        try http.respondError(allocator, stream, 500, "database path is missing");
        return;
    };
    const workspace_dir = std.fs.path.dirname(path) orelse ".";
    const limit = parsePositiveQueryInt(uri, "limit", 10, 50);
    const body_json = try listBacktestTasksJson(allocator, workspace_dir, limit);
    defer allocator.free(body_json);
    try http.respond(stream, 200, body_json);
}

fn handle_backtest_task_cancel(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    task_id: []const u8,
) !void {
    if (task_id.len == 0) {
        try http.respondError(allocator, stream, 404, "backtest task not found");
        return;
    }
    const body_json = (try cancelBacktestTaskJson(allocator, task_id)) orelse {
        try http.respondError(allocator, stream, 404, "backtest task not found");
        return;
    };
    defer allocator.free(body_json);
    try http.respond(stream, 200, body_json);
}

fn handle_backtest(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    body: []const u8,
    db: ?*duckdb.Db,
    db_path: ?[]const u8,
) !void {
    const path = db_path orelse {
        try http.respondError(allocator, stream, 500, "database path is missing");
        return;
    };
    const d = db orelse {
        try http.respondError(allocator, stream, 500, "database is not available");
        return;
    };
    const workspace_dir = std.fs.path.dirname(path) orelse ".";
    const cache_key = result_cache.makeKey(allocator, body, db) catch null;
    defer if (cache_key) |key| allocator.free(key);
    if (cache_key) |key| {
        if (result_cache.load(allocator, workspace_dir, key) catch null) |cached| {
            defer allocator.free(cached);
            try http.respond(stream, 200, cached);
            return;
        }
    }
    const result = backtest.run(allocator, d, body, workspace_dir) catch |err| {
        std.debug.print("Backtest error: {any}\n", .{err});
        try http.respondError(allocator, stream, 400, "backtest failed");
        return;
    };
    defer allocator.free(result);
    if (cache_key) |key| {
        result_cache.save(allocator, workspace_dir, key, result);
    }
    try http.respond(stream, 200, result);
}

fn handle_backtest_history(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    db_path: ?[]const u8,
) !void {
    const path = db_path orelse {
        try http.respond(stream, 200, "[]");
        return;
    };
    const workspace_dir = std.fs.path.dirname(path) orelse ".";
    const result = backtest.history(allocator, workspace_dir) catch |err| {
        std.debug.print("Backtest history error: {any}\n", .{err});
        try http.respond(stream, 200, "[]");
        return;
    };
    defer allocator.free(result);
    try http.respond(stream, 200, result);
}

// ============================================================
// Stock basic info
// ============================================================
fn handle_stock_basic(allocator: std.mem.Allocator, stream: std.net.Stream, symbol: []const u8) !void {
    var info = eastmoney.getStockInfo(allocator, symbol) catch |err| {
        std.debug.print("EastMoney error: {any}, trying Tencent\n", .{err});
        var t_info = tencent.getStockInfo(allocator, symbol) catch |err2| {
            std.debug.print("Tencent error: {any}\n", .{err2});
            try http.respondError(allocator, stream, 500, "no data");
            return;
        };
        defer t_info.deinit(allocator);
        var out = std.io.Writer.Allocating.init(allocator);
        defer out.deinit();
        var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
        try s.beginObject();
        try s.objectField("symbol");
        try s.write(t_info.symbol);
        try s.objectField("name");
        try s.write(t_info.name);
        try s.objectField("latest");
        try s.write(t_info.price);
        try s.objectField("change_pct");
        try writeNullableF64(&s, t_info.change_pct);
        try s.objectField("股票代码");
        try s.write(t_info.symbol);
        try s.objectField("股票简称");
        try s.write(t_info.name);
        try s.objectField("最新");
        try s.write(t_info.price);
        try s.objectField("涨跌幅");
        try writeNullableF64(&s, t_info.change_pct);
        try s.objectField("总市值");
        try writeNullableF64(&s, t_info.market_cap);
        try s.objectField("流通市值");
        try writeNullableF64(&s, t_info.float_market_cap);
        try s.objectField("总股本");
        try writeNullableF64(&s, t_info.total_shares);
        try s.objectField("流通股");
        try writeNullableF64(&s, t_info.float_shares);
        try s.endObject();
        try http.respond(stream, 200, out.written());
        return;
    };
    defer info.deinit(allocator);

    if (info.err_msg) |err| {
        try http.respondError(allocator, stream, 500, err);
        return;
    }

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginObject();
    try s.objectField("symbol");
    try s.write(info.symbol);
    try s.objectField("name");
    try s.write(info.name);
    try s.objectField("latest");
    try s.write(info.price);
    try s.objectField("change_pct");
    try writeNullableF64(&s, info.change_pct);
    try s.objectField("股票代码");
    try s.write(info.symbol);
    try s.objectField("股票简称");
    try s.write(info.name);
    try s.objectField("最新");
    try s.write(info.price);
    try s.objectField("涨跌幅");
    try writeNullableF64(&s, info.change_pct);
    try s.objectField("行业");
    try s.write(info.industry orelse "");
    try s.objectField("总市值");
    try writeNullableF64(&s, info.market_cap);
    try s.objectField("总股本");
    try writeNullableF64(&s, info.total_shares);
    try s.objectField("流通股");
    try writeNullableF64(&s, info.float_shares);
    try s.objectField("上市时间");
    try s.write(info.list_date orelse "");
    try s.endObject();
    try http.respond(stream, 200, out.written());
}

// ============================================================
// Stock search
// ============================================================
fn handle_search(allocator: std.mem.Allocator, stream: std.net.Stream, uri: []const u8) !void {
    const q_str = if (std.mem.indexOf(u8, uri, "?q=")) |idx| uri[idx + 3 ..] else "";
    if (q_str.len == 0) {
        try http.respond(stream, 200, "[]");
        return;
    }

    var result = eastmoney.searchStock(allocator, q_str) catch |err| {
        std.debug.print("Search error: {any}\n", .{err});
        try http.respondError(allocator, stream, 500, "search failed");
        return;
    };
    defer result.deinit(allocator);

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginArray();
    for (result.items) |item| {
        try s.beginObject();
        try s.objectField("symbol");
        try s.write(item.symbol);
        try s.objectField("name");
        try s.write(item.name);
        try s.endObject();
    }
    try s.endArray();

    try http.respond(stream, 200, out.written());
}

// ============================================================
// K-line history
// ============================================================
fn handle_stock_kline(allocator: std.mem.Allocator, stream: std.net.Stream, symbol: []const u8) !void {
    var result = try eastmoney.getKline(allocator, symbol);
    defer result.deinit(allocator);

    if (result.err_msg) |err| {
        try http.respondError(allocator, stream, 500, err);
        return;
    }

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginArray();
    for (result.items) |kline| {
        try s.beginObject();
        try s.objectField("date");
        try s.write(kline.date);
        try s.objectField("open");
        try s.write(kline.open);
        try s.objectField("close");
        try s.write(kline.close);
        try s.objectField("high");
        try s.write(kline.high);
        try s.objectField("low");
        try s.write(kline.low);
        try s.objectField("volume");
        try s.write(kline.volume);
        try s.endObject();
    }
    try s.endArray();

    try http.respond(stream, 200, out.written());
}

// ============================================================
// Daily K-line with amount and change_pct
// ============================================================
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

fn isSafeSymbol(s: []const u8) bool {
    if (s.len != 6) return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn writeNullableF64(s: *std.json.Stringify, val: ?f64) !void {
    if (val) |v| {
        try s.write(v);
    } else {
        try s.write(null);
    }
}

const DailyBar = struct {
    date: []const u8,
    open: f64,
    close: f64,
    high: f64,
    low: f64,
    volume: f64,
    amount: ?f64 = null,
    change_pct: ?f64 = null,
};

const TechnicalSummary = struct {
    symbol: []const u8,
    position: []const u8,
    short_term: []const u8,
    medium_term: []const u8,
    long_term: []const u8,
    ma_arrangement: []const u8,
    macd: f64,
    signal_line: f64,
    histogram: f64,
    macd_trend: []const u8,
    rsi: f64,
    rsi_status: []const u8,
    current: f64,
    resistance: f64,
    support: f64,
    vwap: f64,
    ma5: f64,
    ma10: f64,
    ma20: f64,
    ma60: f64,
    boll_upper: f64,
    boll_mid: f64,
    boll_lower: f64,
    has_w_bottom: bool,
    suggestion: []const u8,
    trade_signal: []const u8,
    score: f64,
};

fn freeDailyBars(allocator: std.mem.Allocator, bars: []DailyBar) void {
    for (bars) |bar| {
        allocator.free(bar.date);
    }
    allocator.free(bars);
}

fn loadDailyBarsFromDb(allocator: std.mem.Allocator, d: *duckdb.Db, symbol: []const u8, limit: usize) ![]DailyBar {
    if (!isSafeSymbol(symbol)) return error.InvalidSymbol;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const query = try std.fmt.allocPrint(aa,
        \\SELECT CAST(date AS VARCHAR) AS date, open, close, high, low, volume, amount, change_pct
        \\FROM (
        \\    SELECT date, open, close, high, low, volume, amount, change_pct
        \\    FROM daily_k
        \\    WHERE symbol = '{s}'
        \\    ORDER BY date DESC
        \\    LIMIT {d}
        \\)
        \\ORDER BY date ASC
    , .{ symbol, limit });

    var result = try d.queryRows(allocator, query);
    defer result.deinit(allocator);

    if (result.rows.items.len == 0) return error.NoData;

    var bars = std.ArrayList(DailyBar){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (bars.items) |bar| allocator.free(bar.date);
        bars.deinit(allocator);
    }

    var r: usize = 0;
    while (r < result.rows.items.len) : (r += 1) {
        try bars.append(allocator, DailyBar{
            .date = try allocator.dupe(u8, result.getStr(r, "date") orelse ""),
            .open = result.getF64(r, "open") orelse 0,
            .close = result.getF64(r, "close") orelse 0,
            .high = result.getF64(r, "high") orelse 0,
            .low = result.getF64(r, "low") orelse 0,
            .volume = result.getF64(r, "volume") orelse 0,
            .amount = result.getF64(r, "amount"),
            .change_pct = result.getF64(r, "change_pct"),
        });
    }

    return try bars.toOwnedSlice(allocator);
}

fn loadDailyBars(allocator: std.mem.Allocator, db: ?*duckdb.Db, symbol: []const u8, limit: usize) ![]DailyBar {
    if (db) |d| {
        if (loadDailyBarsFromDb(allocator, d, symbol, limit)) |bars| {
            return bars;
        } else |_| {}
    }

    const days: u16 = @intCast(@min(limit, 500));
    var result = try eastmoney.getDailyK(allocator, symbol, days);
    defer result.deinit(allocator);

    if (result.err_msg != null or result.items.len == 0) return error.NoData;

    var bars = std.ArrayList(DailyBar){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (bars.items) |bar| allocator.free(bar.date);
        bars.deinit(allocator);
    }

    for (result.items) |item| {
        try bars.append(allocator, DailyBar{
            .date = try allocator.dupe(u8, item.date),
            .open = item.open,
            .close = item.close,
            .high = item.high,
            .low = item.low,
            .volume = item.volume,
            .amount = item.amount,
            .change_pct = item.change_pct,
        });
    }

    return try bars.toOwnedSlice(allocator);
}

fn meanClose(bars: []const DailyBar, window: usize) f64 {
    if (bars.len == 0) return 0;
    const start = if (bars.len > window) bars.len - window else 0;
    var sum: f64 = 0;
    var count: usize = 0;
    for (bars[start..]) |bar| {
        sum += bar.close;
        count += 1;
    }
    return if (count > 0) sum / @as(f64, @floatFromInt(count)) else 0;
}

fn stddevClose(bars: []const DailyBar, window: usize, mean: f64) f64 {
    if (bars.len == 0) return 0;
    const start = if (bars.len > window) bars.len - window else 0;
    var sum_sq: f64 = 0;
    var count: usize = 0;
    for (bars[start..]) |bar| {
        const diff = bar.close - mean;
        sum_sq += diff * diff;
        count += 1;
    }
    return if (count > 1) std.math.sqrt(sum_sq / @as(f64, @floatFromInt(count))) else 0;
}

fn analyzeBars(symbol: []const u8, bars: []const DailyBar) TechnicalSummary {
    if (bars.len == 0) {
        return TechnicalSummary{
            .symbol = symbol,
            .position = "未知",
            .short_term = "未知",
            .medium_term = "未知",
            .long_term = "未知",
            .ma_arrangement = "未知",
            .macd = 0,
            .signal_line = 0,
            .histogram = 0,
            .macd_trend = "未知",
            .rsi = 50,
            .rsi_status = "中性",
            .current = 0,
            .resistance = 0,
            .support = 0,
            .vwap = 0,
            .ma5 = 0,
            .ma10 = 0,
            .ma20 = 0,
            .ma60 = 0,
            .boll_upper = 0,
            .boll_mid = 0,
            .boll_lower = 0,
            .has_w_bottom = false,
            .suggestion = "技术面中性",
            .trade_signal = "hold",
            .score = 50,
        };
    }

    const current = bars[bars.len - 1].close;
    const ma5 = meanClose(bars, 5);
    const ma10 = meanClose(bars, 10);
    const ma20 = meanClose(bars, 20);
    const ma60 = meanClose(bars, 60);
    const boll_std = stddevClose(bars, 20, ma20);

    const short_term = if (current > ma5) "上涨" else "下跌";
    const medium_term = if (current > ma10) "上涨" else "下跌";
    const long_term = if (current > ma20) "上涨" else "下跌";
    const ma_arrangement = if (ma5 > ma10 and ma10 > ma20) "多头排列" else if (ma5 < ma10 and ma10 < ma20) "空头排列" else "纠缠";

    var ema12 = bars[0].close;
    var ema26 = bars[0].close;
    var dif: f64 = 0;
    var dea: f64 = 0;
    var hist: f64 = 0;
    var prev_hist: f64 = 0;
    for (bars, 0..) |bar, idx| {
        if (idx == 0) continue;
        prev_hist = hist;
        ema12 = ema12 + (2.0 / 13.0) * (bar.close - ema12);
        ema26 = ema26 + (2.0 / 27.0) * (bar.close - ema26);
        dif = ema12 - ema26;
        dea = dea + (2.0 / 10.0) * (dif - dea);
        hist = dif - dea;
    }
    const macd_trend = if (hist > 0 and prev_hist < 0) "金叉看涨" else if (hist < 0 and prev_hist > 0) "死叉看跌" else if (hist > 0) "多头" else "空头";

    var gains: f64 = 0;
    var losses: f64 = 0;
    var rsi_count: usize = 0;
    const rsi_start = if (bars.len > 14) bars.len - 14 else 1;
    if (bars.len > 1) {
        var i: usize = rsi_start;
        while (i < bars.len) : (i += 1) {
            const delta = bars[i].close - bars[i - 1].close;
            if (delta > 0) {
                gains += delta;
            } else {
                losses += -delta;
            }
            rsi_count += 1;
        }
    }
    const avg_gain = if (rsi_count > 0) gains / @as(f64, @floatFromInt(rsi_count)) else 0;
    const avg_loss = if (rsi_count > 0) losses / @as(f64, @floatFromInt(rsi_count)) else 0;
    const rsi = if (avg_loss == 0 and avg_gain > 0) 100.0 else if (avg_loss == 0) 50.0 else 100.0 - (100.0 / (1.0 + avg_gain / avg_loss));
    const rsi_status = if (rsi > 70) "超买" else if (rsi < 30) "超卖" else "中性";

    const sr_start = if (bars.len > 30) bars.len - 30 else 0;
    var resistance = bars[sr_start].high;
    var support = bars[sr_start].low;
    var vwap_num: f64 = 0;
    var vwap_den: f64 = 0;
    for (bars[sr_start..]) |bar| {
        if (bar.high > resistance) resistance = bar.high;
        if (bar.low < support) support = bar.low;
        vwap_num += bar.close * bar.volume;
        vwap_den += bar.volume;
    }
    const vwap = if (vwap_den > 0) vwap_num / vwap_den else meanClose(bars, 30);

    const w_start = if (bars.len > 20) bars.len - 20 else 0;
    var min_low = bars[w_start].low;
    for (bars[w_start..]) |bar| {
        if (bar.low < min_low) min_low = bar.low;
    }
    var low_hits: usize = 0;
    if (min_low > 0) {
        for (bars[w_start..]) |bar| {
            if (@abs(bar.low - min_low) / min_low < 0.03) low_hits += 1;
        }
    }
    const has_w_bottom = low_hits >= 2;

    const position = if (current > resistance * 0.98) "突破/接近阻力" else if (current < support * 1.02) "接近支撑" else if (std.mem.eql(u8, short_term, "上涨")) "上涨趋势" else "震荡整理";

    var score: f64 = 50;
    if (std.mem.eql(u8, short_term, "上涨")) score += 10;
    if (std.mem.eql(u8, ma_arrangement, "多头排列")) score += 10;
    if (std.mem.eql(u8, macd_trend, "金叉看涨")) {
        score += 15;
    } else if (hist > 0) {
        score += 5;
    }
    if (rsi >= 45 and rsi <= 60) {
        score += 10;
    } else if (rsi > 70) {
        score -= 10;
    }
    if (has_w_bottom) score += 20;
    if (score < 0) score = 0;
    if (score > 100) score = 100;

    const suggestion = if (std.mem.eql(u8, macd_trend, "金叉看涨")) "MACD金叉，短期看涨" else if (std.mem.eql(u8, rsi_status, "超卖")) "RSI超卖，可能有反弹" else if (std.mem.eql(u8, rsi_status, "超买")) "RSI超买，注意回调" else if (has_w_bottom) "W底形态形成，看涨信号" else "技术面中性";
    const trade_signal = if (score >= 70) "buy" else if (score < 40) "sell" else "hold";

    return TechnicalSummary{
        .symbol = symbol,
        .position = position,
        .short_term = short_term,
        .medium_term = medium_term,
        .long_term = long_term,
        .ma_arrangement = ma_arrangement,
        .macd = dif,
        .signal_line = dea,
        .histogram = hist,
        .macd_trend = macd_trend,
        .rsi = rsi,
        .rsi_status = rsi_status,
        .current = current,
        .resistance = resistance,
        .support = support,
        .vwap = vwap,
        .ma5 = ma5,
        .ma10 = ma10,
        .ma20 = ma20,
        .ma60 = ma60,
        .boll_upper = ma20 + boll_std * 2.0,
        .boll_mid = ma20,
        .boll_lower = ma20 - boll_std * 2.0,
        .has_w_bottom = has_w_bottom,
        .suggestion = suggestion,
        .trade_signal = trade_signal,
        .score = score,
    };
}

fn analyzeSymbolTechnical(allocator: std.mem.Allocator, db: ?*duckdb.Db, symbol: []const u8) !TechnicalSummary {
    const bars = try loadDailyBars(allocator, db, symbol, 260);
    defer freeDailyBars(allocator, bars);
    return analyzeBars(symbol, bars);
}

fn analyzeSymbolTechnicalWithLivePrice(
    allocator: std.mem.Allocator,
    db: ?*duckdb.Db,
    symbol: []const u8,
    live_price: f64,
    live_change_pct: ?f64,
) !TechnicalSummary {
    const bars = try loadDailyBars(allocator, db, symbol, 260);
    defer freeDailyBars(allocator, bars);
    if (bars.len > 0 and live_price > 0) {
        const last = &bars[bars.len - 1];
        last.close = live_price;
        if (live_price > last.high) last.high = live_price;
        if (last.low == 0 or live_price < last.low) last.low = live_price;
        if (live_change_pct) |change| last.change_pct = change;
    }
    return analyzeBars(symbol, bars);
}

fn writeTechnicalObject(s: *std.json.Stringify, t: TechnicalSummary) !void {
    try s.beginObject();
    try s.objectField("symbol");
    try s.write(t.symbol);
    try s.objectField("position");
    try s.write(t.position);

    try s.objectField("trend");
    try s.beginObject();
    try s.objectField("short_term");
    try s.write(t.short_term);
    try s.objectField("medium_term");
    try s.write(t.medium_term);
    try s.objectField("long_term");
    try s.write(t.long_term);
    try s.objectField("ma_arrangement");
    try s.write(t.ma_arrangement);
    try s.endObject();

    try s.objectField("indicators");
    try s.beginObject();
    try s.objectField("macd");
    try s.beginObject();
    try s.objectField("macd");
    try s.write(t.macd);
    try s.objectField("signal");
    try s.write(t.signal_line);
    try s.objectField("histogram");
    try s.write(t.histogram);
    try s.objectField("trend");
    try s.write(t.macd_trend);
    try s.endObject();
    try s.objectField("rsi");
    try s.beginObject();
    try s.objectField("value");
    try s.write(t.rsi);
    try s.objectField("status");
    try s.write(t.rsi_status);
    try s.endObject();
    try s.endObject();

    try s.objectField("patterns");
    try s.beginArray();
    if (t.has_w_bottom) {
        try s.beginObject();
        try s.objectField("pattern");
        try s.write("W底形态");
        try s.objectField("confidence");
        try s.write("中等");
        try s.objectField("implication");
        try s.write("看涨信号");
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("support_resistance");
    try s.beginObject();
    try s.objectField("current");
    try s.write(t.current);
    try s.objectField("resistance");
    try s.write(t.resistance);
    try s.objectField("support");
    try s.write(t.support);
    try s.objectField("vwap");
    try s.write(t.vwap);
    try s.endObject();

    try s.objectField("suggestion");
    try s.write(t.suggestion);
    try s.objectField("score");
    try s.write(t.score);

    try s.objectField("macd");
    try s.beginObject();
    try s.objectField("dif");
    try s.write(t.macd);
    try s.objectField("dea");
    try s.write(t.signal_line);
    try s.objectField("macd");
    try s.write(t.histogram);
    try s.endObject();

    try s.objectField("rsi");
    try s.beginObject();
    try s.objectField("rsi_6");
    try s.write(t.rsi);
    try s.objectField("rsi_12");
    try s.write(t.rsi);
    try s.objectField("rsi_24");
    try s.write(t.rsi);
    try s.endObject();

    try s.objectField("boll");
    try s.beginObject();
    try s.objectField("upper");
    try s.write(t.boll_upper);
    try s.objectField("mid");
    try s.write(t.boll_mid);
    try s.objectField("lower");
    try s.write(t.boll_lower);
    try s.endObject();

    try s.objectField("ma");
    try s.beginObject();
    try s.objectField("ma5");
    try s.write(t.ma5);
    try s.objectField("ma10");
    try s.write(t.ma10);
    try s.objectField("ma20");
    try s.write(t.ma20);
    try s.objectField("ma60");
    try s.write(t.ma60);
    try s.endObject();

    try s.objectField("signal");
    try s.write(t.trade_signal);
    try s.endObject();
}

fn writeValuationObject(s: *std.json.Stringify, allocator: std.mem.Allocator, symbol: []const u8, db: ?*duckdb.Db) !void {
    try s.beginObject();

    try s.objectField("price");
    const bars = loadDailyBars(allocator, db, symbol, 1300) catch null;
    if (bars) |price_bars| {
        defer freeDailyBars(allocator, price_bars);
        if (price_bars.len > 0) {
            const current = price_bars[price_bars.len - 1].close;
            var hist_high = current;
            var hist_low = current;
            var avg: f64 = 0;
            var below_count: usize = 0;
            for (price_bars) |bar| {
                if (bar.close > hist_high) hist_high = bar.close;
                if (bar.close < hist_low) hist_low = bar.close;
                if (bar.close < current) below_count += 1;
                avg += bar.close;
            }
            avg /= @as(f64, @floatFromInt(price_bars.len));
            const percentile = @as(f64, @floatFromInt(below_count)) / @as(f64, @floatFromInt(price_bars.len)) * 100.0;

            try s.beginObject();
            try s.objectField("current");
            try s.write(current);
            try s.objectField("percentile");
            try s.write(percentile);
            try s.objectField("hist_high");
            try s.write(hist_high);
            try s.objectField("hist_low");
            try s.write(hist_low);
            try s.objectField("avg");
            try s.write(avg);
            try s.endObject();
        } else {
            try s.beginObject();
            try s.endObject();
        }
    } else {
        try s.beginObject();
        try s.endObject();
    }

    try s.objectField("pe");
    var val_result = baidu.getValuation(allocator, symbol) catch null;
    if (val_result) |*val| {
        defer val_result.?.deinit(allocator);
        if (val.current_pe) |current_pe| {
            if (current_pe < 0) {
                try s.beginObject();
                try s.objectField("current");
                try s.write(current_pe);
                try s.objectField("is_loss");
                try s.write(true);
                try s.objectField("status");
                try s.write("公司当前处于亏损状态");
                try s.endObject();
            } else {
                var positive_count: usize = 0;
                var below_count: usize = 0;
                var hist_high: f64 = current_pe;
                var hist_low: f64 = current_pe;
                var avg: f64 = 0;
                for (val.values) |v| {
                    if (v <= 0) continue;
                    positive_count += 1;
                    if (v < current_pe) below_count += 1;
                    if (v > hist_high) hist_high = v;
                    if (v < hist_low) hist_low = v;
                    avg += v;
                }
                if (positive_count > 0) avg /= @as(f64, @floatFromInt(positive_count));
                const percentile = if (positive_count > 0) @as(f64, @floatFromInt(below_count)) / @as(f64, @floatFromInt(positive_count)) * 100.0 else 0;

                try s.beginObject();
                try s.objectField("current");
                try s.write(current_pe);
                try s.objectField("percentile");
                try s.write(percentile);
                try s.objectField("hist_high");
                try s.write(hist_high);
                try s.objectField("hist_low");
                try s.write(hist_low);
                try s.objectField("avg");
                try s.write(avg);
                try s.objectField("is_loss");
                try s.write(false);
                try s.endObject();
            }
        } else {
            try s.beginObject();
            try s.endObject();
        }
    } else {
        try s.beginObject();
        try s.endObject();
    }

    try s.endObject();
}

fn writeProfileObject(
    s: *std.json.Stringify,
    symbol: []const u8,
    name: []const u8,
    industry: []const u8,
    list_date: []const u8,
    profile: ?eastmoney.CompanyProfile,
) !void {
    try s.beginObject();
    if (profile) |p| {
        const company_name = p.company_name orelse name;
        const a_code = p.a_code orelse symbol;
        const a_name = p.a_name orelse name;
        const profile_industry = p.industry orelse industry;
        const profile_list_date = p.list_date orelse list_date;

        try s.objectField("symbol");
        try s.write(a_code);
        try s.objectField("company_name");
        try s.write(company_name);
        try s.objectField("industry");
        try s.write(profile_industry);
        try s.objectField("main_business");
        try s.write(p.main_business orelse "");
        try s.objectField("description");
        try s.write(p.description orelse "");

        try s.objectField("公司名称");
        try s.write(company_name);
        try s.objectField("英文名称");
        try s.write(p.english_name orelse "");
        try s.objectField("曾用简称");
        try s.write(p.previous_name orelse "");
        try s.objectField("A股代码");
        try s.write(a_code);
        try s.objectField("A股简称");
        try s.write(a_name);
        try s.objectField("所属市场");
        try s.write(p.market orelse "");
        try s.objectField("所属行业");
        try s.write(profile_industry);
        try s.objectField("法人代表");
        try s.write(p.legal_representative orelse "");
        try s.objectField("注册资金");
        try writeNullableF64(s, p.registered_capital);
        try s.objectField("成立日期");
        try s.write(p.founded_date orelse "");
        try s.objectField("上市日期");
        try s.write(profile_list_date);
        try s.objectField("官方网站");
        try s.write(p.website orelse "");
        try s.objectField("电子邮箱");
        try s.write(p.email orelse "");
        try s.objectField("联系电话");
        try s.write(p.phone orelse "");
        try s.objectField("传真");
        try s.write(p.fax orelse "");
        try s.objectField("注册地址");
        try s.write(p.registered_address orelse "");
        try s.objectField("办公地址");
        try s.write(p.office_address orelse "");
        try s.objectField("邮政编码");
        try s.write(p.zip_code orelse "");
        try s.objectField("主营业务");
        try s.write(p.main_business orelse "");
        try s.objectField("经营范围");
        try s.write(p.business_scope orelse "");
        try s.objectField("机构简介");
        try s.write(p.description orelse "");
        try s.objectField("董事长");
        try s.write(p.chairman orelse "");
    } else {
        try s.objectField("symbol");
        try s.write(symbol);
        try s.objectField("company_name");
        try s.write(name);
        try s.objectField("industry");
        try s.write(industry);
        try s.objectField("main_business");
        try s.write("");
        try s.objectField("description");
        try s.write("");
        try s.objectField("公司名称");
        try s.write(name);
        try s.objectField("A股代码");
        try s.write(symbol);
        try s.objectField("A股简称");
        try s.write(name);
        try s.objectField("所属行业");
        try s.write(industry);
        try s.objectField("上市日期");
        try s.write(list_date);
        try s.objectField("主营业务");
        try s.write("");
        try s.objectField("经营范围");
        try s.write("");
        try s.objectField("机构简介");
        try s.write("");
    }
    try s.endObject();
}

fn writeDailyRowsFromDb(allocator: std.mem.Allocator, stream: std.net.Stream, d: *duckdb.Db, symbol: []const u8, uri: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const start_date = http.queryParam(uri, "start_date");
    const end_date = http.queryParam(uri, "end_date");

    var query = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer query.deinit(aa);
    try query.appendSlice(aa,
        \\SELECT CAST(date AS VARCHAR) AS date, open, close, high, low, volume, amount, change_pct
        \\FROM daily_k
        \\WHERE symbol = '
    );
    try query.appendSlice(aa, symbol);
    try query.appendSlice(aa, "'");

    if (start_date) |sd| {
        if (isSafeDate(sd)) {
            try query.appendSlice(aa, " AND date >= DATE '");
            try query.appendSlice(aa, sd);
            try query.appendSlice(aa, "'");
        }
    } else if (end_date == null) {
        try query.appendSlice(aa, " AND date >= CURRENT_DATE - INTERVAL 1 YEAR");
    }

    if (end_date) |ed| {
        if (isSafeDate(ed)) {
            try query.appendSlice(aa, " AND date <= DATE '");
            try query.appendSlice(aa, ed);
            try query.appendSlice(aa, "'");
        }
    }

    try query.appendSlice(aa, " ORDER BY date ASC");

    var result = d.queryRows(allocator, query.items) catch |err| {
        std.debug.print("DuckDB daily_k query error: {any}\n", .{err});
        return false;
    };
    defer result.deinit(allocator);

    if (result.rows.items.len == 0) {
        return false;
    }

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginArray();
    var r: usize = 0;
    while (r < result.rows.items.len) : (r += 1) {
        try s.beginObject();
        try s.objectField("date");
        try s.write(result.getStr(r, "date") orelse "");
        try s.objectField("open");
        try writeNullableF64(&s, result.getF64(r, "open"));
        try s.objectField("close");
        try writeNullableF64(&s, result.getF64(r, "close"));
        try s.objectField("high");
        try writeNullableF64(&s, result.getF64(r, "high"));
        try s.objectField("low");
        try writeNullableF64(&s, result.getF64(r, "low"));
        try s.objectField("volume");
        try writeNullableF64(&s, result.getF64(r, "volume"));
        try s.objectField("amount");
        try writeNullableF64(&s, result.getF64(r, "amount"));
        try s.objectField("change_pct");
        try writeNullableF64(&s, result.getF64(r, "change_pct"));
        try s.endObject();
    }
    try s.endArray();

    try http.respond(stream, 200, out.written());
    return true;
}

fn parsePositiveQueryInt(uri: []const u8, name: []const u8, default_value: usize, max_value: usize) usize {
    const raw = http.queryParam(uri, name) orelse return default_value;
    const parsed = std.fmt.parseInt(usize, raw, 10) catch return default_value;
    if (parsed == 0) return default_value;
    return @min(parsed, max_value);
}

fn writeDailyBarsArray(stream: std.net.Stream, allocator: std.mem.Allocator, bars: []const DailyBar) !void {
    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginArray();
    for (bars) |bar| {
        try s.beginObject();
        try s.objectField("date");
        try s.write(bar.date);
        try s.objectField("open");
        try s.write(bar.open);
        try s.objectField("close");
        try s.write(bar.close);
        try s.objectField("high");
        try s.write(bar.high);
        try s.objectField("low");
        try s.write(bar.low);
        try s.objectField("volume");
        try s.write(bar.volume);
        try s.objectField("amount");
        try writeNullableF64(&s, bar.amount);
        try s.objectField("change_pct");
        try writeNullableF64(&s, bar.change_pct);
        try s.endObject();
    }
    try s.endArray();

    try http.respond(stream, 200, out.written());
}

fn handle_price_history(allocator: std.mem.Allocator, stream: std.net.Stream, symbol: []const u8, uri: []const u8, db: ?*duckdb.Db) !void {
    const days = parsePositiveQueryInt(uri, "days", 30, 5000);
    const bars = loadDailyBars(allocator, db, symbol, days) catch |err| {
        std.debug.print("Price history error: {any}\n", .{err});
        try http.respond(stream, 200, "[]");
        return;
    };
    defer freeDailyBars(allocator, bars);

    try writeDailyBarsArray(stream, allocator, bars);
}

fn handle_daily_k(allocator: std.mem.Allocator, stream: std.net.Stream, symbol: []const u8, uri: []const u8, db: ?*duckdb.Db) !void {
    if (db) |d| {
        if (try writeDailyRowsFromDb(allocator, stream, d, symbol, uri)) {
            return;
        }
    }

    var days: u16 = 0;
    if (std.mem.indexOf(u8, uri, "?days=")) |idx| {
        const num_str = uri[idx + 6 ..];
        days = std.fmt.parseInt(u16, num_str, 10) catch 0;
    }

    var result = eastmoney.getDailyK(allocator, symbol, if (days > 0) days else 500) catch |err| {
        std.debug.print("Daily K error: {any}\n", .{err});
        try http.respond(stream, 200, "[]");
        return;
    };
    defer result.deinit(allocator);

    if (result.err_msg) |err| {
        try http.respondError(allocator, stream, 500, err);
        return;
    }

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginArray();
    for (result.items) |kline| {
        try s.beginObject();
        try s.objectField("date");
        try s.write(kline.date);
        try s.objectField("open");
        try s.write(kline.open);
        try s.objectField("close");
        try s.write(kline.close);
        try s.objectField("high");
        try s.write(kline.high);
        try s.objectField("low");
        try s.write(kline.low);
        try s.objectField("volume");
        try s.write(kline.volume);
        try s.objectField("amount");
        try writeNullableF64(&s, kline.amount);
        try s.objectField("change_pct");
        try writeNullableF64(&s, kline.change_pct);
        try s.endObject();
    }
    try s.endArray();

    try http.respond(stream, 200, out.written());
}

// ============================================================
// PE Valuation
// ============================================================
fn handle_stock_valuation(allocator: std.mem.Allocator, stream: std.net.Stream, symbol: []const u8) !void {
    var result = try baidu.getValuation(allocator, symbol);
    defer result.deinit(allocator);

    if (result.err_msg) |err| {
        try http.respondError(allocator, stream, 500, err);
        return;
    }

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginObject();
    if (result.current_pe) |pe| {
        try s.objectField("current");
        try s.write(pe);
    }
    try s.objectField("dates");
    try s.beginArray();
    var date_iter = std.mem.splitSequence(u8, result.dates, ",");
    while (date_iter.next()) |d| {
        try s.write(d);
    }
    try s.endArray();
    try s.objectField("values");
    try s.beginArray();
    for (result.values) |v| {
        try s.write(v);
    }
    try s.endArray();
    try s.endObject();

    try http.respond(stream, 200, out.written());
}

// ============================================================
// Industry analysis compatibility endpoint
// ============================================================
fn industryStockChangeDesc(_: void, a: eastmoney.IndustryStock, b: eastmoney.IndustryStock) bool {
    return a.change_pct > b.change_pct;
}

fn writeEmptyIndustryObject(s: *std.json.Stringify, industry_name: []const u8) !void {
    try s.beginObject();
    try s.objectField("industry_name");
    try s.write(industry_name);
    try s.objectField("rank_in_industry");
    try s.write(null);
    try s.objectField("industry_avg_change");
    try s.write(null);
    try s.objectField("relative_performance");
    try s.write(null);
    try s.objectField("top5_peers");
    try s.beginArray();
    try s.endArray();
    try s.endObject();
}

fn writeEmptyFuturesObject(s: *std.json.Stringify) !void {
    try s.beginObject();
    try s.objectField("futures");
    try s.beginArray();
    try s.endArray();
    try s.objectField("summary");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
}

fn industryHas(industry_name: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, industry_name, needle) != null;
}

const FUTURES_LITHIUM = [_][]const u8{"碳酸锂主连"};
const FUTURES_METALS = [_][]const u8{ "沪铜主连", "沪铝主连", "沪锌主连" };
const FUTURES_STEEL = [_][]const u8{ "螺纹钢主连", "铁矿石主连" };

fn futuresForIndustry(industry_name: []const u8) []const []const u8 {
    if (industryHas(industry_name, "能源金属") or industryHas(industry_name, "锂") or industryHas(industry_name, "电池")) return FUTURES_LITHIUM[0..];
    if (industryHas(industry_name, "工业金属") or industryHas(industry_name, "有色金属") or industryHas(industry_name, "铜") or industryHas(industry_name, "铝") or industryHas(industry_name, "锌")) return FUTURES_METALS[0..];
    if (industryHas(industry_name, "钢铁") or industryHas(industry_name, "钢") or industryHas(industry_name, "铁")) return FUTURES_STEEL[0..];
    return &.{};
}

fn meanFutureClose(items: []const eastmoney.FutureBar, window: usize) f64 {
    if (items.len == 0) return 0;
    const start = if (items.len > window) items.len - window else 0;
    var sum: f64 = 0;
    var count: usize = 0;
    for (items[start..]) |bar| {
        sum += bar.close;
        count += 1;
    }
    return if (count > 0) sum / @as(f64, @floatFromInt(count)) else 0;
}

fn writeFutureAnalysisItem(s: *std.json.Stringify, allocator: std.mem.Allocator, symbol: []const u8) !?[]const u8 {
    var hist = eastmoney.getFutureHistory(allocator, symbol, 720) catch |err| {
        std.debug.print("Future history error for {s}: {any}\n", .{ symbol, err });
        return null;
    };
    defer hist.deinit(allocator);
    if (hist.items.len == 0) return null;

    const current = hist.items[hist.items.len - 1].close;
    const ma20 = meanFutureClose(hist.items, 20);
    const ma60 = meanFutureClose(hist.items, 60);
    const idx_1m = if (hist.items.len > 22) hist.items.len - 22 else 0;
    const idx_3m = if (hist.items.len > 66) hist.items.len - 66 else 0;
    const price_1m = hist.items[idx_1m].close;
    const price_3m = hist.items[idx_3m].close;

    var hist_high = current;
    var hist_low = current;
    var below_count: usize = 0;
    for (hist.items) |bar| {
        if (bar.close > hist_high) hist_high = bar.close;
        if (bar.close < hist_low) hist_low = bar.close;
        if (bar.close < current) below_count += 1;
    }
    const percentile = @as(f64, @floatFromInt(below_count)) / @as(f64, @floatFromInt(hist.items.len)) * 100.0;
    const trend = if (current > ma20 and ma20 > ma60) "上升趋势" else if (current < ma20 and ma20 < ma60) "下降趋势" else "震荡整理";

    try s.beginObject();
    try s.objectField("name");
    try s.write(hist.name);
    try s.objectField("current_price");
    try s.write(current);
    try s.objectField("price_20d_avg");
    try s.write(ma20);
    try s.objectField("price_60d_avg");
    try s.write(ma60);
    try s.objectField("trend");
    try s.write(trend);
    try s.objectField("change_1m");
    try s.write(if (price_1m != 0) (current - price_1m) / price_1m * 100.0 else 0);
    try s.objectField("change_3m");
    try s.write(if (price_3m != 0) (current - price_3m) / price_3m * 100.0 else 0);
    try s.objectField("hist_high");
    try s.write(hist_high);
    try s.objectField("hist_low");
    try s.write(hist_low);
    try s.objectField("price_percentile");
    try s.write(percentile);
    try s.endObject();

    return trend;
}

fn writeFuturesAnalysisObject(s: *std.json.Stringify, allocator: std.mem.Allocator, industry_name: []const u8) !void {
    const symbols = futuresForIndustry(industry_name);
    if (symbols.len == 0) {
        try writeEmptyFuturesObject(s);
        return;
    }

    var trends = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer trends.deinit(allocator);

    try s.beginObject();
    try s.objectField("futures");
    try s.beginArray();
    for (symbols) |symbol| {
        if (try writeFutureAnalysisItem(s, allocator, symbol)) |trend| {
            try trends.append(allocator, trend);
        }
    }
    try s.endArray();

    var up_count: usize = 0;
    var down_count: usize = 0;
    for (trends.items) |trend| {
        if (std.mem.eql(u8, trend, "上升趋势")) up_count += 1;
        if (std.mem.eql(u8, trend, "下降趋势")) down_count += 1;
    }

    try s.objectField("summary");
    try s.beginObject();
    try s.objectField("trend");
    if (trends.items.len == 0) {
        try s.write("暂无期货数据");
    } else if (up_count > down_count) {
        try s.write("上游原材料价格整体上涨");
    } else if (down_count > up_count) {
        try s.write("上游原材料价格整体下跌");
    } else {
        try s.write("上游原材料价格震荡");
    }
    try s.objectField("impact");
    if (trends.items.len == 0) {
        try s.write("暂无影响判断");
    } else if (up_count > down_count) {
        try s.write("成本上升，对下游企业利润可能产生压力");
    } else if (down_count > up_count) {
        try s.write("成本下降，有利于下游企业利润改善");
    } else {
        try s.write("成本相对稳定");
    }
    try s.endObject();
    try s.endObject();
}

fn writeIndustryAnalysisObject(s: *std.json.Stringify, allocator: std.mem.Allocator, symbol: []const u8, industry_name: []const u8) !void {
    if (industry_name.len == 0) {
        try writeEmptyIndustryObject(s, "");
        return;
    }

    var industry = eastmoney.getIndustryStocks(allocator, industry_name) catch |err| {
        std.debug.print("Industry analysis error: {any}\n", .{err});
        try writeEmptyIndustryObject(s, industry_name);
        return;
    };
    defer industry.deinit(allocator);

    std.mem.sort(eastmoney.IndustryStock, industry.items, {}, industryStockChangeDesc);

    var avg_change: f64 = 0;
    for (industry.items) |stock| {
        avg_change += stock.change_pct;
    }
    if (industry.items.len > 0) {
        avg_change /= @as(f64, @floatFromInt(industry.items.len));
    }

    var rank: ?usize = null;
    var target_change: ?f64 = null;
    for (industry.items, 0..) |stock, idx| {
        if (std.mem.eql(u8, stock.symbol, symbol)) {
            rank = idx + 1;
            target_change = stock.change_pct;
            break;
        }
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const rank_text = if (rank) |r| try std.fmt.allocPrint(arena.allocator(), "{d}/{d}", .{ r, industry.items.len }) else null;

    try s.beginObject();
    try s.objectField("industry_name");
    try s.write(industry.board_name);
    try s.objectField("rank_in_industry");
    if (rank_text) |text| try s.write(text) else try s.write(null);
    try s.objectField("industry_avg_change");
    try s.write(avg_change);
    try s.objectField("relative_performance");
    if (target_change) |change| try s.write(change - avg_change) else try s.write(null);
    try s.objectField("top5_peers");
    try s.beginArray();
    const top_n = @min(@as(usize, 5), industry.items.len);
    var i: usize = 0;
    while (i < top_n) : (i += 1) {
        const peer = industry.items[i];
        try s.beginObject();
        try s.objectField("名称");
        try s.write(peer.name);
        try s.objectField("代码");
        try s.write(peer.symbol);
        try s.objectField("最新价");
        try s.write(peer.price);
        try s.objectField("涨跌幅");
        try s.write(peer.change_pct);
        try s.objectField("成交额");
        try s.write(peer.amount);
        try s.objectField("换手率");
        try s.write(peer.turnover_rate);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

fn handle_stock_industry(allocator: std.mem.Allocator, stream: std.net.Stream, symbol: []const u8, uri: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const raw_industry = http.queryParam(uri, "industry") orelse "";
    const decoded_industry = if (raw_industry.len > 0) eastmoney.urlDecode(aa, raw_industry) catch raw_industry else "";

    var industry_name: []const u8 = decoded_industry;
    var stock_name: []const u8 = "";
    var latest: f64 = 0;
    if (industry_name.len == 0) {
        var info = eastmoney.getStockInfo(allocator, symbol) catch null;
        if (info) |*stock_info| {
            defer stock_info.deinit(allocator);
            stock_name = try aa.dupe(u8, stock_info.name);
            latest = stock_info.price;
            if (stock_info.industry) |ind| {
                industry_name = try aa.dupe(u8, ind);
            }
        }
    }

    if (industry_name.len > 0) {
        var industry = eastmoney.getIndustryStocks(allocator, industry_name) catch |err| {
            std.debug.print("Industry analysis error: {any}\n", .{err});
            var out = std.io.Writer.Allocating.init(allocator);
            defer out.deinit();
            var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
            try s.beginObject();
            try s.objectField("industry_name");
            try s.write(industry_name);
            try s.objectField("rank_in_industry");
            try s.write(null);
            try s.objectField("industry_avg_change");
            try s.write(null);
            try s.objectField("relative_performance");
            try s.write(null);
            try s.objectField("top5_peers");
            try s.beginArray();
            try s.endArray();
            try s.endObject();
            try http.respond(stream, 200, out.written());
            return;
        };
        defer industry.deinit(allocator);

        std.mem.sort(eastmoney.IndustryStock, industry.items, {}, industryStockChangeDesc);

        var avg_change: f64 = 0;
        for (industry.items) |stock| {
            avg_change += stock.change_pct;
        }
        if (industry.items.len > 0) {
            avg_change /= @as(f64, @floatFromInt(industry.items.len));
        }

        var rank: ?usize = null;
        var target_change: ?f64 = null;
        for (industry.items, 0..) |stock, idx| {
            if (std.mem.eql(u8, stock.symbol, symbol)) {
                rank = idx + 1;
                target_change = stock.change_pct;
                break;
            }
        }

        const rank_text = if (rank) |r| try std.fmt.allocPrint(aa, "{d}/{d}", .{ r, industry.items.len }) else null;

        var out = std.io.Writer.Allocating.init(allocator);
        defer out.deinit();
        var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };

        try s.beginObject();
        try s.objectField("industry_name");
        try s.write(industry.board_name);
        try s.objectField("rank_in_industry");
        if (rank_text) |text| try s.write(text) else try s.write(null);
        try s.objectField("industry_avg_change");
        try s.write(avg_change);
        try s.objectField("relative_performance");
        if (target_change) |change| try s.write(change - avg_change) else try s.write(null);
        try s.objectField("top5_peers");
        try s.beginArray();
        const top_n = @min(@as(usize, 5), industry.items.len);
        var i: usize = 0;
        while (i < top_n) : (i += 1) {
            const peer = industry.items[i];
            try s.beginObject();
            try s.objectField("名称");
            try s.write(peer.name);
            try s.objectField("代码");
            try s.write(peer.symbol);
            try s.objectField("最新价");
            try s.write(peer.price);
            try s.objectField("涨跌幅");
            try s.write(peer.change_pct);
            try s.objectField("成交额");
            try s.write(peer.amount);
            try s.objectField("换手率");
            try s.write(peer.turnover_rate);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();

        try http.respond(stream, 200, out.written());
        return;
    }

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };

    try s.beginObject();
    try s.objectField("industry_name");
    try s.write(industry_name);
    try s.objectField("rank_in_industry");
    try s.write(null);
    try s.objectField("industry_avg_change");
    try s.write(null);
    try s.objectField("relative_performance");
    try s.write(null);
    try s.objectField("top5_peers");
    try s.beginArray();
    if (stock_name.len > 0) {
        try s.beginObject();
        try s.objectField("名称");
        try s.write(stock_name);
        try s.objectField("代码");
        try s.write(symbol);
        try s.objectField("最新价");
        try s.write(latest);
        try s.objectField("涨跌幅");
        try s.write(null);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();

    try http.respond(stream, 200, out.written());
}

// ============================================================
// Full stock analysis
// ============================================================
fn handle_stock_full(allocator: std.mem.Allocator, stream: std.net.Stream, symbol: []const u8, db: ?*duckdb.Db) !void {
    // Get basic info
    var info = eastmoney.getStockInfo(allocator, symbol) catch |err| {
        std.debug.print("EastMoney error: {any}, trying Tencent\n", .{err});
        var t_info = tencent.getStockInfo(allocator, symbol) catch |err2| {
            std.debug.print("Tencent error: {any}\n", .{err2});
            try http.respondJson(allocator, stream, 200, .{ .symbol = symbol });
            return;
        };
        defer t_info.deinit(allocator);

        const empty_bars: []const DailyBar = &.{};
        const technical = analyzeSymbolTechnicalWithLivePrice(allocator, db, symbol, t_info.price, t_info.change_pct) catch analyzeBars(symbol, empty_bars);
        var out = std.io.Writer.Allocating.init(allocator);
        defer out.deinit();
        var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };

        try s.beginObject();
        try s.objectField("symbol");
        try s.write(t_info.symbol);
        try s.objectField("name");
        try s.write(t_info.name);
        try s.objectField("latest");
        try s.write(t_info.price);
        try s.objectField("score");
        try s.write(technical.score);
        try s.objectField("basic");
        try s.beginObject();
        try s.objectField("股票代码");
        try s.write(t_info.symbol);
        try s.objectField("股票简称");
        try s.write(t_info.name);
        try s.objectField("最新");
        try s.write(t_info.price);
        try s.objectField("行业");
        try s.write("");
        try s.objectField("总市值");
        try writeNullableF64(&s, t_info.market_cap);
        try s.objectField("流通市值");
        try writeNullableF64(&s, t_info.float_market_cap);
        try s.objectField("总股本");
        try writeNullableF64(&s, t_info.total_shares);
        try s.objectField("流通股");
        try writeNullableF64(&s, t_info.float_shares);
        try s.endObject();
        try s.objectField("profile");
        var t_profile = eastmoney.getCompanyProfile(allocator, symbol) catch null;
        defer if (t_profile) |*p| p.deinit(allocator);
        try writeProfileObject(&s, t_info.symbol, t_info.name, "", "", t_profile);
        try s.objectField("technical");
        try writeTechnicalObject(&s, technical);
        try s.objectField("valuation");
        try writeValuationObject(&s, allocator, symbol, db);
        try s.objectField("industry");
        try writeEmptyIndustryObject(&s, "");
        try s.objectField("futures");
        try writeEmptyFuturesObject(&s);
        try s.objectField("kline");
        try s.beginArray();
        try s.endArray();
        try s.endObject();

        try http.respond(stream, 200, out.written());
        return;
    };
    defer info.deinit(allocator);

    // Get kline
    var kline_result = eastmoney.getKline(allocator, symbol) catch eastmoney.KlineResult{
        .items = &.{},
    };
    defer kline_result.deinit(allocator);

    // Build combined response
    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginObject();
    try s.objectField("symbol");
    try s.write(info.symbol);
    try s.objectField("name");
    try s.write(info.name);
    try s.objectField("latest");
    try s.write(info.price);

    const empty_bars: []const DailyBar = &.{};
    const technical = analyzeSymbolTechnicalWithLivePrice(allocator, db, symbol, info.price, info.change_pct) catch analyzeBars(symbol, empty_bars);

    try s.objectField("score");
    try s.write(technical.score);

    try s.objectField("basic");
    try s.beginObject();
    try s.objectField("股票代码");
    try s.write(info.symbol);
    try s.objectField("股票简称");
    try s.write(info.name);
    try s.objectField("最新");
    try s.write(info.price);
    try s.objectField("行业");
    try s.write(info.industry orelse "");
    try s.objectField("总市值");
    try writeNullableF64(&s, info.market_cap);
    try s.objectField("总股本");
    try writeNullableF64(&s, info.total_shares);
    try s.objectField("流通股");
    try writeNullableF64(&s, info.float_shares);
    try s.objectField("上市时间");
    try s.write(info.list_date orelse "");
    try s.endObject();

    try s.objectField("profile");
    var profile_result = eastmoney.getCompanyProfile(allocator, symbol) catch null;
    defer if (profile_result) |*p| p.deinit(allocator);
    try writeProfileObject(&s, info.symbol, info.name, info.industry orelse "", info.list_date orelse "", profile_result);

    try s.objectField("technical");
    try writeTechnicalObject(&s, technical);

    try s.objectField("valuation");
    try writeValuationObject(&s, allocator, symbol, db);

    try s.objectField("industry");
    try writeIndustryAnalysisObject(&s, allocator, symbol, info.industry orelse "");

    try s.objectField("futures");
    try writeFuturesAnalysisObject(&s, allocator, info.industry orelse "");

    // K-line as array
    try s.objectField("kline");
    try s.beginArray();
    for (kline_result.items) |kline| {
        try s.beginObject();
        try s.objectField("date");
        try s.write(kline.date);
        try s.objectField("open");
        try s.write(kline.open);
        try s.objectField("close");
        try s.write(kline.close);
        try s.objectField("high");
        try s.write(kline.high);
        try s.objectField("low");
        try s.write(kline.low);
        try s.objectField("volume");
        try s.write(kline.volume);
        try s.endObject();
    }
    try s.endArray();

    try s.endObject();

    try http.respond(stream, 200, out.written());
}

// ============================================================
// Company profile
// ============================================================
fn handle_stock_profile(allocator: std.mem.Allocator, stream: std.net.Stream, symbol: []const u8) !void {
    var profile = eastmoney.getCompanyProfile(allocator, symbol) catch null;
    defer if (profile) |*p| p.deinit(allocator);

    var info = eastmoney.getStockInfo(allocator, symbol) catch |err| {
        std.debug.print("EastMoney error: {any}, trying Tencent\n", .{err});
        var t_info = tencent.getStockInfo(allocator, symbol) catch |err2| {
            std.debug.print("Tencent error: {any}\n", .{err2});
            var out = std.io.Writer.Allocating.init(allocator);
            defer out.deinit();
            var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
            try writeProfileObject(&s, symbol, symbol, "", "", profile);
            try http.respond(stream, 200, out.written());
            return;
        };
        defer t_info.deinit(allocator);

        var out = std.io.Writer.Allocating.init(allocator);
        defer out.deinit();
        var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
        try writeProfileObject(&s, t_info.symbol, t_info.name, "", "", profile);
        try http.respond(stream, 200, out.written());
        return;
    };
    defer info.deinit(allocator);

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try writeProfileObject(&s, info.symbol, info.name, info.industry orelse "", info.list_date orelse "", profile);
    try http.respond(stream, 200, out.written());
}

// ============================================================
// Technical analysis
// ============================================================
fn handle_stock_technical(allocator: std.mem.Allocator, stream: std.net.Stream, symbol: []const u8, db: ?*duckdb.Db) !void {
    const empty_bars: []const DailyBar = &.{};
    const LiveQuote = struct {
        price: ?f64 = null,
        change_pct: ?f64 = null,
    };
    const live = blk: {
        var info = eastmoney.getStockInfo(allocator, symbol) catch null;
        if (info) |*value| {
            defer value.deinit(allocator);
            break :blk LiveQuote{ .price = value.price, .change_pct = value.change_pct };
        }
        var t_info = tencent.getStockInfo(allocator, symbol) catch null;
        if (t_info) |*value| {
            defer value.deinit(allocator);
            break :blk LiveQuote{ .price = value.price, .change_pct = value.change_pct };
        }
        break :blk LiveQuote{};
    };
    const technical = if (live.price) |price|
        analyzeSymbolTechnicalWithLivePrice(allocator, db, symbol, price, live.change_pct) catch |err| blk2: {
            std.debug.print("Technical analysis error: {any}\n", .{err});
            break :blk2 analyzeBars(symbol, empty_bars);
        }
    else
        analyzeSymbolTechnical(allocator, db, symbol) catch |err| blk3: {
            std.debug.print("Technical analysis error: {any}\n", .{err});
            break :blk3 analyzeBars(symbol, empty_bars);
        };

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try writeTechnicalObject(&s, technical);
    try http.respond(stream, 200, out.written());
}

// ============================================================
// Related futures analysis
// ============================================================
fn handle_futures(allocator: std.mem.Allocator, stream: std.net.Stream, uri: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const raw_industry = http.queryParam(uri, "industry") orelse "";
    const industry_name = if (raw_industry.len > 0) eastmoney.urlDecode(aa, raw_industry) catch raw_industry else "";

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try writeFuturesAnalysisObject(&s, allocator, industry_name);
    try http.respond(stream, 200, out.written());
}

// ============================================================
// Market scan
// ============================================================
const ScoredStock = struct {
    symbol: []const u8,
    name: []const u8,
    price: f64,
    change_pct: f64,
    candidate_price: ?f64 = null,
    candidate_change_pct: ?f64 = null,
    turnover: f64,
    score: f64,
    industry: []const u8 = "",
    owns_text: bool = false,
};

const LocalScanAppendResult = struct {
    added: usize = 0,
    data_date: ?[]const u8 = null,
    coverage_count: usize = 0,
};

const MarketScanResult = struct {
    items: []ScoredStock,
    source: []const u8,
    data_date: ?[]const u8 = null,
    coverage_count: usize = 0,

    fn deinit(self: *MarketScanResult, allocator: std.mem.Allocator) void {
        for (self.items) |stock| {
            if (stock.owns_text) {
                allocator.free(stock.symbol);
                allocator.free(stock.name);
            }
        }
        allocator.free(self.items);
        if (self.data_date) |value| allocator.free(value);
    }
};

fn scoredStockDesc(_: void, a: ScoredStock, b: ScoredStock) bool {
    if (a.score == b.score) return a.turnover > b.turnover;
    return a.score > b.score;
}

fn applyRealtimeQuotesToScan(allocator: std.mem.Allocator, db: ?*duckdb.Db, items: []ScoredStock) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const chunk_size: usize = 100;
    var start: usize = 0;
    while (start < items.len) : (start += chunk_size) {
        const end = @min(start + chunk_size, items.len);
        var query = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer query.deinit(aa);

        for (items[start..end], 0..) |stock, idx| {
            if (idx > 0) try query.append(aa, ',');
            const prefix = if (stock.symbol[0] == '6' or stock.symbol[0] == '5') "sh" else "sz";
            try query.writer(aa).print("{s}{s}", .{ prefix, stock.symbol });
        }

        const url = try std.fmt.allocPrint(aa, "http://qt.gtimg.cn/q={s}", .{query.items});
        const response = try eastmoney.httpGet(aa, url);

        var line_iter = std.mem.splitScalar(u8, response, ';');
        while (line_iter.next()) |line| {
            const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse continue;
            const last_quote = std.mem.lastIndexOfScalar(u8, line, '"') orelse continue;
            if (first_quote >= last_quote) continue;

            const payload = line[first_quote + 1 .. last_quote];
            var field_iter = std.mem.splitScalar(u8, payload, '~');
            var field_index: usize = 0;
            var symbol: ?[]const u8 = null;
            var price: ?f64 = null;
            var prev_close: ?f64 = null;
            var turnover: ?f64 = null;

            while (field_iter.next()) |field| : (field_index += 1) {
                switch (field_index) {
                    2 => symbol = field,
                    3 => price = std.fmt.parseFloat(f64, field) catch null,
                    4 => prev_close = std.fmt.parseFloat(f64, field) catch null,
                    35 => {
                        var amount_iter = std.mem.splitScalar(u8, field, '/');
                        _ = amount_iter.next();
                        _ = amount_iter.next();
                        if (amount_iter.next()) |amount_str| {
                            turnover = std.fmt.parseFloat(f64, amount_str) catch null;
                        }
                    },
                    else => {},
                }
                if (field_index > 35) break;
            }

            const code = symbol orelse continue;
            const live_price = price orelse continue;
            if (live_price <= 0) continue;
            const live_change_pct = if (prev_close) |prev|
                if (prev != 0) (live_price - prev) / prev * 100.0 else null
            else
                null;

            for (items[start..end]) |*stock| {
                if (!std.mem.eql(u8, stock.symbol, code)) continue;
                stock.candidate_price = stock.price;
                stock.candidate_change_pct = stock.change_pct;
                stock.price = live_price;
                if (live_change_pct) |change| stock.change_pct = change;
                if (turnover) |amount| stock.turnover = amount;
                const technical = analyzeSymbolTechnicalWithLivePrice(allocator, db, stock.symbol, live_price, live_change_pct) catch null;
                if (technical) |summary| stock.score = summary.score;
                break;
            }
        }
    }
}

fn appendLocalScanCandidates(
    allocator: std.mem.Allocator,
    d: *duckdb.Db,
    top_n: u16,
    scored: *std.ArrayList(ScoredStock),
) !LocalScanAppendResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const min_coverage: u16 = @max(top_n, 1000);
    const query = try std.fmt.allocPrint(aa,
        \\WITH amount_counts AS (
        \\    SELECT date, COUNT(*) AS cnt
        \\    FROM daily_k
        \\    WHERE amount IS NOT NULL
        \\      AND amount > 0
        \\    GROUP BY date
        \\),
        \\qualified_date AS (
        \\    SELECT date AS d
        \\    FROM amount_counts
        \\    WHERE cnt >= {d}
        \\    ORDER BY date DESC
        \\    LIMIT 1
        \\),
        \\fallback_date AS (
        \\    SELECT date AS d
        \\    FROM amount_counts
        \\    ORDER BY cnt DESC, date DESC
        \\    LIMIT 1
        \\),
        \\scan_date AS (
        \\    SELECT COALESCE((SELECT d FROM qualified_date), (SELECT d FROM fallback_date)) AS d
        \\)
        \\SELECT
        \\    CAST(k.date AS VARCHAR) AS data_date,
        \\    COALESCE(ac.cnt, 0) AS coverage_count,
        \\    k.symbol,
        \\    COALESCE(i.name, k.symbol) AS name,
        \\    k.close,
        \\    k.change_pct,
        \\    k.amount
        \\FROM daily_k k
        \\LEFT JOIN stock_info i ON i.symbol = k.symbol
        \\LEFT JOIN amount_counts ac ON ac.date = k.date
        \\WHERE k.date = (SELECT d FROM scan_date)
        \\  AND k.amount IS NOT NULL
        \\  AND k.amount > 0
        \\ORDER BY k.amount DESC
        \\LIMIT {d}
    , .{ min_coverage, top_n });

    var result = try d.queryRows(allocator, query);
    defer result.deinit(allocator);

    var meta = LocalScanAppendResult{};
    var r: usize = 0;
    while (r < result.rows.items.len) : (r += 1) {
        const symbol = result.getStr(r, "symbol") orelse continue;
        const name = result.getStr(r, "name") orelse symbol;
        const empty_bars: []const DailyBar = &.{};
        const technical = analyzeSymbolTechnical(allocator, d, symbol) catch analyzeBars(symbol, empty_bars);
        if (meta.data_date == null) {
            meta.data_date = try allocator.dupe(u8, result.getStr(r, "data_date") orelse "");
            meta.coverage_count = std.fmt.parseInt(usize, result.getStr(r, "coverage_count") orelse "0", 10) catch 0;
        }
        try scored.append(allocator, ScoredStock{
            .symbol = try allocator.dupe(u8, symbol),
            .name = try allocator.dupe(u8, name),
            .price = result.getF64(r, "close") orelse 0,
            .change_pct = result.getF64(r, "change_pct") orelse 0,
            .turnover = result.getF64(r, "amount") orelse 0,
            .score = technical.score,
            .owns_text = true,
        });
        meta.added += 1;
    }
    return meta;
}

fn runMarketScan(allocator: std.mem.Allocator, db: ?*duckdb.Db, top_n: u16) !MarketScanResult {
    var scored = std.ArrayList(ScoredStock){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (scored.items) |stock| {
            if (stock.owns_text) {
                allocator.free(stock.symbol);
                allocator.free(stock.name);
            }
        }
        scored.deinit(allocator);
    }

    var source: []const u8 = "scan";
    var data_date: ?[]const u8 = null;
    var coverage_count: usize = 0;
    if (db) |d| {
        const local = appendLocalScanCandidates(allocator, d, top_n, &scored) catch |err| blk: {
            std.debug.print("Local scan error: {any}, trying remote market scan\n", .{err});
            break :blk LocalScanAppendResult{};
        };
        if (local.added > 0) {
            source = "db";
            data_date = local.data_date;
            coverage_count = local.coverage_count;
        } else if (local.data_date) |value| {
            allocator.free(value);
        }
    }

    if (scored.items.len == 0) {
        var remote_result = eastmoney.scanMarket(allocator, top_n) catch |err| blk: {
            std.debug.print("Scan error: {any}\n", .{err});
            break :blk null;
        };
        defer if (remote_result) |*result| result.deinit(allocator);

        if (remote_result) |result| {
            if (result.err_msg != null) return error.ScanFailed;
            for (result.items) |stock| {
                const empty_bars: []const DailyBar = &.{};
                const technical = analyzeSymbolTechnical(allocator, db, stock.symbol) catch analyzeBars(stock.symbol, empty_bars);
                try scored.append(allocator, ScoredStock{
                    .symbol = try allocator.dupe(u8, stock.symbol),
                    .name = try allocator.dupe(u8, stock.name),
                    .price = stock.price,
                    .change_pct = stock.change_pct,
                    .turnover = stock.turnover,
                    .score = technical.score,
                    .owns_text = true,
                });
            }
        }
    }

    if (scored.items.len == 0) return error.ScanFailed;
    std.mem.sort(ScoredStock, scored.items, {}, scoredStockDesc);
    const items = try scored.toOwnedSlice(allocator);

    if (std.mem.eql(u8, source, "db")) {
        applyRealtimeQuotesToScan(allocator, db, items) catch |err| {
            std.debug.print("Realtime quote merge error: {any}\n", .{err});
        };
        std.mem.sort(ScoredStock, items, {}, scoredStockDesc);
    }

    return MarketScanResult{
        .items = items,
        .source = source,
        .data_date = data_date,
        .coverage_count = coverage_count,
    };
}

fn handle_scan(allocator: std.mem.Allocator, stream: std.net.Stream, uri: []const u8, db: ?*duckdb.Db) !void {
    var top_n: u16 = 100;
    if (std.mem.indexOf(u8, uri, "?")) |idx| {
        const qs = uri[idx + 1 ..];
        if (std.mem.startsWith(u8, qs, "top_n=")) {
            const num_str = qs["top_n=".len..];
            top_n = std.fmt.parseInt(u16, num_str, 10) catch 100;
        }
    }

    var scan = runMarketScan(allocator, db, top_n) catch |err| {
        std.debug.print("Scan error: {any}\n", .{err});
        try http.respondError(allocator, stream, 500, "scan failed");
        return;
    };
    defer scan.deinit(allocator);

    if (db) |d| {
        const scan_date = currentDbDate(allocator, d) catch null;
        defer if (scan_date) |value| allocator.free(value);
        if (scan_date) |value| {
            saveScanToDb(d, allocator, value, top_n, scan.items) catch |err| {
                std.debug.print("DuckDB save error: {any}\n", .{err});
            };
        }
    }

    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try s.beginObject();
    try s.objectField("stocks");
    try s.beginArray();
    for (scan.items) |stock| {
        try s.beginObject();
        try s.objectField("symbol");
        try s.write(stock.symbol);
        try s.objectField("name");
        try s.write(stock.name);
        try s.objectField("price");
        try s.write(stock.price);
        try s.objectField("change_pct");
        try s.write(stock.change_pct);
        try s.objectField("candidate_price");
        try writeNullableF64(&s, stock.candidate_price);
        try s.objectField("candidate_change_pct");
        try writeNullableF64(&s, stock.candidate_change_pct);
        try s.objectField("score");
        try s.write(stock.score);
        try s.objectField("industry");
        try s.write(stock.industry);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("total");
    try s.write(scan.items.len);
    try s.objectField("source");
    try s.write(scan.source);
    try s.objectField("data_date");
    if (scan.data_date) |value| {
        try s.write(value);
    } else {
        try s.write(null);
    }
    try s.objectField("coverage_count");
    try s.write(scan.coverage_count);
    try s.endObject();

    try http.respond(stream, 200, out.written());
}

fn saveScanToDb(
    d: *duckdb.Db,
    allocator: std.mem.Allocator,
    scan_date: []const u8,
    top_n: u16,
    items: []const ScoredStock,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const insert_scan = try std.fmt.allocPrint(
        aa,
        "INSERT OR REPLACE INTO scan_result (scan_date, top_n, total_stocks) VALUES ('{s}', {d}, {d})",
        .{ scan_date, top_n, items.len },
    );
    try d.exec(insert_scan);

    const del = try std.fmt.allocPrint(
        aa,
        "DELETE FROM scan_stock WHERE scan_date = '{s}'",
        .{scan_date},
    );
    try d.exec(del);

    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const rank = i + 1;
        const escaped_name = try sql_text.escape(aa, items[i].name);
        const escaped_industry = try sql_text.escape(aa, items[i].industry);

        const insert_stock = try std.fmt.allocPrint(
            aa,
            "INSERT OR REPLACE INTO scan_stock (scan_date, rank, symbol, name, price, change_pct, score, industry) VALUES ('{s}', {d}, '{s}', '{s}', {d}, {d}, {d}, '{s}')",
            .{ scan_date, rank, items[i].symbol, escaped_name, items[i].price, items[i].change_pct, items[i].score, escaped_industry },
        );
        try d.exec(insert_stock);
    }
}

// ============================================================
// Scan history list
// ============================================================
fn handle_scan_history(allocator: std.mem.Allocator, stream: std.net.Stream, db: ?*duckdb.Db) !void {
    if (db) |d| {
        var result = d.queryRows(allocator, "SELECT CAST(scan_date AS VARCHAR) AS scan_date, top_n, total_stocks, CAST(created_at AS VARCHAR) as created_at FROM scan_result ORDER BY scan_date DESC LIMIT 100") catch |err| {
            std.debug.print("DuckDB query error: {any}\n", .{err});
            try http.respond(stream, 200, "[]");
            return;
        };
        defer result.deinit(allocator);

        var out = std.io.Writer.Allocating.init(allocator);
        defer out.deinit();

        var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
        try s.beginArray();
        var r: usize = 0;
        while (r < result.rows.items.len) : (r += 1) {
            try s.beginObject();
            try s.objectField("scan_date");
            try s.write(result.getStr(r, "scan_date") orelse "");
            try s.objectField("top_n");
            try s.write(result.getF64(r, "top_n") orelse 0);
            try s.objectField("total_stocks");
            try s.write(result.getF64(r, "total_stocks") orelse 0);
            try s.objectField("created_at");
            try s.write(result.getStr(r, "created_at") orelse "");
            try s.endObject();
        }
        try s.endArray();

        try http.respond(stream, 200, out.written());
    } else {
        try http.respond(stream, 200, "[]");
    }
}

// ============================================================
// Scan history detail
// ============================================================
fn handle_scan_history_detail(allocator: std.mem.Allocator, stream: std.net.Stream, date_str: []const u8, db: ?*duckdb.Db) !void {
    if (db) |d| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const query = try std.fmt.allocPrint(
            aa,
            "SELECT rank, symbol, name, price, change_pct, score, industry FROM scan_stock WHERE scan_date = '{s}' ORDER BY rank",
            .{date_str},
        );

        var result = d.queryRows(allocator, query) catch |err| {
            std.debug.print("DuckDB query error: {any}\n", .{err});
            try http.respond(stream, 200, "{\"stocks\":[]}");
            return;
        };
        defer result.deinit(allocator);

        var out = std.io.Writer.Allocating.init(allocator);
        defer out.deinit();

        var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
        try s.beginObject();
        try s.objectField("scan_date");
        try s.write(date_str);
        try s.objectField("stocks");
        try s.beginArray();
        var r: usize = 0;
        while (r < result.rows.items.len) : (r += 1) {
            try s.beginObject();
            try s.objectField("rank");
            try s.write(result.getF64(r, "rank") orelse 0);
            try s.objectField("symbol");
            try s.write(result.getStr(r, "symbol") orelse "");
            try s.objectField("name");
            try s.write(result.getStr(r, "name") orelse "");
            try s.objectField("price");
            try s.write(result.getF64(r, "price") orelse 0);
            try s.objectField("change_pct");
            try s.write(result.getF64(r, "change_pct") orelse 0);
            try s.objectField("score");
            try s.write(result.getF64(r, "score") orelse 0);
            try s.objectField("industry");
            try s.write(result.getStr(r, "industry") orelse "");
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();

        try http.respond(stream, 200, out.written());
    } else {
        try http.respond(stream, 200, "{\"stocks\":[]}");
    }
}

fn handle_factors(stream: std.net.Stream) !void {
    const body =
        \\[
        \\{"name":"momentum_20d","category":"momentum","description":"20日收益率","higher_is_better":true},
        \\{"name":"momentum_60d","category":"momentum","description":"60日收益率","higher_is_better":true},
        \\{"name":"momentum_120d","category":"momentum","description":"120日收益率","higher_is_better":true},
        \\{"name":"pe_percentile","category":"value","description":"PE历史百分位","higher_is_better":true},
        \\{"name":"price_percentile","category":"value","description":"价格历史百分位","higher_is_better":true},
        \\{"name":"volatility_20d","category":"volatility","description":"20日年化波动率","higher_is_better":false},
        \\{"name":"volume_change","category":"volume","description":"成交量变化率(5日vs20日)","higher_is_better":true},
        \\{"name":"rsi_14","category":"technical","description":"RSI(14)","higher_is_better":true},
        \\{"name":"ma_deviation_20","category":"technical","description":"价格偏离MA20百分比","higher_is_better":true}
        \\]
    ;
    try http.respond(stream, 200, body);
}
