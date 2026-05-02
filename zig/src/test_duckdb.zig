const std = @import("std");
const duckdb = @import("duckdb.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = try duckdb.Db.open(allocator, "/tmp/test_isolated.db");
    defer db.close();

    // Create table
    try db.exec("CREATE TABLE IF NOT EXISTS test_table (id INTEGER, name VARCHAR)");
    std.debug.print("Table created\n", .{});

    // Insert
    try db.exec("INSERT INTO test_table VALUES (1, 'hello')");
    std.debug.print("Row inserted\n", .{});

    // Query
    var result = try db.queryRows(allocator, "SELECT * FROM test_table");
    defer result.deinit(allocator);
    std.debug.print("Query returned {d} rows\n", .{result.rows.items.len});

    for (result.rows.items, 0..) |row, i| {
        std.debug.print("  Row {d}:", .{i});
        for (row.items) |val| {
            std.debug.print(" {s}", .{val});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("Done\n", .{});
}
