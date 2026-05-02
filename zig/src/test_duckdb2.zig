const std = @import("std");
const duckdb = @import("duckdb.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = try duckdb.Db.open(allocator, "/tmp/test_isolated2.db");
    defer db.close();

    std.debug.print("DB opened, database ptr: {*}\n", .{db.database});
    std.debug.print("Connection ptr: {*}\n", .{db.connection});

    // Create table
    try db.exec("CREATE TABLE IF NOT EXISTS test_table (id INTEGER, name VARCHAR)");
    std.debug.print("Table created\n", .{});

    // Insert
    try db.exec("INSERT INTO test_table VALUES (1, 'hello')");
    std.debug.print("Row inserted\n", .{});

    // Try a simpler query first
    const query = "SELECT 1";
    std.debug.print("About to query: {s}\n", .{query});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var c_query = try aa.allocSentinel(u8, query.len, 0);
    @memcpy(c_query[0..query.len], query);
    std.debug.print("c_query ptr: {*}, content: {s}\n", .{ c_query.ptr, c_query });

    var result: duckdb.duckdb_result = undefined;
    const rc = duckdb.duckdb_query(db.connection, c_query.ptr, &result);
    std.debug.print("duckdb_query returned: {d}\n", .{rc});

    if (rc != 0) {
        const err = std.mem.span(duckdb.duckdb_result_error(result));
        std.debug.print("Error: {s}\n", .{err});
        duckdb.duckdb_destroy_result(&result);
        return;
    }

    const n_cols = duckdb.duckdb_column_count(result);
    const n_rows = duckdb.duckdb_row_count(result);
    std.debug.print("Columns: {d}, Rows: {d}\n", .{ n_cols, n_rows });

    duckdb.duckdb_destroy_result(&result);
    std.debug.print("Done\n", .{});
}
