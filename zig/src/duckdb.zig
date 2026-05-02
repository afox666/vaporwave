const std = @import("std");

// ---- DuckDB C API minimal bindings (v1.5.2) ----

const DuckdbDatabase = *opaque {};
const DuckdbConnection = *opaque {};
const DuckdbResult = extern struct {
    // 48 bytes - we access through C API functions, not directly
    _padding: [48]u8 align(8) = undefined,
};
const DuckdbConfig = *opaque {};

extern fn duckdb_open(path: [*c]const u8, out_database: [*c]DuckdbDatabase) c_int;
extern fn duckdb_close(database: [*c]DuckdbDatabase) void;
extern fn duckdb_connect(database: DuckdbDatabase, out_connection: [*c]DuckdbConnection) c_int;
extern fn duckdb_disconnect(connection: [*c]DuckdbConnection) void;
extern fn duckdb_query(connection: DuckdbConnection, query: [*c]const u8, out_result: *DuckdbResult) c_int;
extern fn duckdb_result_error(result: *DuckdbResult) [*c]const u8;
extern fn duckdb_column_count(result: *DuckdbResult) idx_t;
extern fn duckdb_row_count(result: *DuckdbResult) idx_t;
extern fn duckdb_column_name(result: *DuckdbResult, col: idx_t) [*c]const u8;
extern fn duckdb_column_type(result: *DuckdbResult, col: idx_t) c_int;
extern fn duckdb_value_varchar(result: *DuckdbResult, col: idx_t, row: idx_t) [*c]u8;
extern fn duckdb_value_double(result: *DuckdbResult, col: idx_t, row: idx_t) f64;
extern fn duckdb_value_int64(result: *DuckdbResult, col: idx_t, row: idx_t) i64;
extern fn duckdb_free(ptr: *anyopaque) void;
extern fn duckdb_destroy_result(result: *DuckdbResult) void;
extern fn duckdb_create_config(out_config: [*c]DuckdbConfig) c_int;
extern fn duckdb_destroy_config(config: [*c]DuckdbConfig) void;

const idx_t = u64;

// Column types
const DUCKDB_TYPE_VARCHAR: c_int = 17;
const DUCKDB_TYPE_INTEGER: c_int = 3;
const DUCKDB_TYPE_BIGINT: c_int = 4;
const DUCKDB_TYPE_DOUBLE: c_int = 5;

pub const Db = struct {
    path: []const u8,
    database: DuckdbDatabase,
    connection: DuckdbConnection,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Db {
        var c_path = try allocator.allocSentinel(u8, path.len, 0);
        @memcpy(c_path[0..path.len], path);
        defer allocator.free(c_path);

        var database: DuckdbDatabase = undefined;
        const rc = duckdb_open(c_path.ptr, &database);
        if (rc != 0) {
            std.debug.print("DuckDB open failed: {s}\n", .{path});
            return error.OpenFailed;
        }

        var connection: DuckdbConnection = undefined;
        const cc = duckdb_connect(database, &connection);
        if (cc != 0) {
            duckdb_close(&database);
            return error.ConnectFailed;
        }

        return Db{
            .path = try allocator.dupe(u8, path),
            .database = database,
            .connection = connection,
            .allocator = allocator,
        };
    }

    pub fn close(self: *Db) void {
        duckdb_disconnect(&self.connection);
        duckdb_close(&self.database);
        self.allocator.free(self.path);
    }

    pub fn exec(self: *Db, query: []const u8) !void {
        var c_query = try self.allocator.allocSentinel(u8, query.len, 0);
        @memcpy(c_query[0..query.len], query);
        defer self.allocator.free(c_query);

        var result: DuckdbResult = undefined;
        const rc = duckdb_query(self.connection, c_query.ptr, &result);
        if (rc != 0) {
            const err = std.mem.span(duckdb_result_error(&result));
            duckdb_destroy_result(&result);
            std.debug.print("DuckDB exec error: {s}\n  Query: {s}\n", .{ err, query });
            return error.QueryFailed;
        }
        duckdb_destroy_result(&result);
    }

    pub fn queryRows(self: *Db, allocator: std.mem.Allocator, query: []const u8) !QueryResult {
        var c_query = try allocator.allocSentinel(u8, query.len, 0);
        @memcpy(c_query[0..query.len], query);
        defer allocator.free(c_query);

        var result: DuckdbResult = undefined;
        const rc = duckdb_query(self.connection, c_query.ptr, &result);
        if (rc != 0) {
            const err = std.mem.span(duckdb_result_error(&result));
            duckdb_destroy_result(&result);
            std.debug.print("DuckDB query error: {s}\n  Query: {s}\n", .{ err, query });
            return error.QueryFailed;
        }

        const n_cols = duckdb_column_count(&result);
        const n_rows = duckdb_row_count(&result);

        // Collect column names
        var col_names = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        errdefer col_names.deinit(allocator);

        var c: idx_t = 0;
        while (c < n_cols) : (c += 1) {
            const name = std.mem.span(duckdb_column_name(&result, c));
            try col_names.append(allocator, try allocator.dupe(u8, name));
        }

        // Collect rows as arrays of strings
        var rows = std.ArrayList(std.ArrayList([]const u8)){ .items = &.{}, .capacity = 0 };
        errdefer {
            for (rows.items) |*row| row.deinit(allocator);
            rows.deinit(allocator);
        }

        var r: idx_t = 0;
        while (r < n_rows) : (r += 1) {
            var row = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
            errdefer row.deinit(allocator);

            var c2: idx_t = 0;
            while (c2 < n_cols) : (c2 += 1) {
                const col_type = duckdb_column_type(&result, c2);
                var val_str: []const u8 = try allocator.dupe(u8, "");

                switch (col_type) {
                    DUCKDB_TYPE_VARCHAR => {
                        const ptr = duckdb_value_varchar(&result, c2, r);
                        if (ptr != null) {
                            allocator.free(val_str);
                            val_str = try allocator.dupe(u8, std.mem.span(@as([*c]const u8, @ptrCast(ptr))));
                            duckdb_free(@ptrCast(ptr));
                        }
                    },
                    DUCKDB_TYPE_DOUBLE => {
                        const v = duckdb_value_double(&result, c2, r);
                        var buf: [64]u8 = undefined;
                        const formatted = try std.fmt.bufPrint(&buf, "{d}", .{v});
                        allocator.free(val_str);
                        val_str = try allocator.dupe(u8, formatted);
                    },
                    DUCKDB_TYPE_BIGINT, DUCKDB_TYPE_INTEGER => {
                        const v = duckdb_value_int64(&result, c2, r);
                        var buf: [64]u8 = undefined;
                        const formatted = try std.fmt.bufPrint(&buf, "{d}", .{v});
                        allocator.free(val_str);
                        val_str = try allocator.dupe(u8, formatted);
                    },
                    else => {
                        const ptr = duckdb_value_varchar(&result, c2, r);
                        if (ptr != null) {
                            allocator.free(val_str);
                            val_str = try allocator.dupe(u8, std.mem.span(@as([*c]const u8, @ptrCast(ptr))));
                            duckdb_free(@ptrCast(ptr));
                        }
                    },
                }
                try row.append(allocator, val_str);
            }
            try rows.append(allocator, row);
        }

        const names_slice = try col_names.toOwnedSlice(allocator);

        duckdb_destroy_result(&result);

        return QueryResult{
            .columns = names_slice,
            .rows = rows,
        };
    }
};

pub const QueryResult = struct {
    columns: []const []const u8,
    rows: std.ArrayList(std.ArrayList([]const u8)),

    pub fn deinit(self: *QueryResult, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*row| {
            for (row.items) |cell| allocator.free(cell);
            row.deinit(allocator);
        }
        self.rows.deinit(allocator);
        for (self.columns) |col| allocator.free(col);
        allocator.free(self.columns);
    }

    /// Get string value at (row, col_name)
    pub fn getStr(self: *QueryResult, row: usize, col_name: []const u8) ?[]const u8 {
        const col_idx = findColumn(self.columns, col_name) orelse return null;
        if (row >= self.rows.items.len) return null;
        if (col_idx >= self.rows.items[row].items.len) return null;
        return self.rows.items[row].items[col_idx];
    }

    /// Get f64 value at (row, col_name)
    pub fn getF64(self: *QueryResult, row: usize, col_name: []const u8) ?f64 {
        const str = self.getStr(row, col_name) orelse return null;
        return std.fmt.parseFloat(f64, str) catch null;
    }
};

pub const QueryError = struct {
    message: []const u8,
};

fn findColumn(columns: []const []const u8, name: []const u8) ?usize {
    for (columns, 0..) |col, i| {
        if (std.mem.eql(u8, col, name)) return i;
    }
    return null;
}
