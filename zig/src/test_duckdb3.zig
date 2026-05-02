const std = @import("std");

const duckdb_database = *opaque {};
const duckdb_connection = *opaque {};
const duckdb_result = *opaque {};

extern fn duckdb_open(path: [*c]const u8, out_database: [*c]duckdb_database) c_int;
extern fn duckdb_close(database: [*c]duckdb_database) void;
extern fn duckdb_connect(database: duckdb_database, out_connection: [*c]duckdb_connection) c_int;
extern fn duckdb_disconnect(connection: [*c]duckdb_connection) void;
extern fn duckdb_query(connection: duckdb_connection, query: [*c]const u8, out_result: [*c]duckdb_result) c_int;
extern fn duckdb_result_error(result: duckdb_result) [*c]const u8;
extern fn duckdb_column_count(result: duckdb_result) i64;
extern fn duckdb_row_count(result: duckdb_result) i64;
extern fn duckdb_column_name(result: duckdb_result, col: i64) [*c]const u8;
extern fn duckdb_destroy_result(result: [*c]duckdb_result) void;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const path = "/tmp/test_isolated3.db";

    var db: duckdb_database = undefined;
    const rc = duckdb_open(path, &db);
    std.debug.print("duckdb_open returned: {d}, db ptr: {*}\n", .{ rc, db });
    if (rc != 0) return error.OpenFailed;

    var conn: duckdb_connection = undefined;
    const cc = duckdb_connect(db, &conn);
    std.debug.print("duckdb_connect returned: {d}, conn ptr: {*}\n", .{ cc, conn });
    if (cc != 0) return error.ConnectFailed;

    const query = "SELECT 1 as val";
    var result: duckdb_result = undefined;
    const qr = duckdb_query(conn, query, &result);
    std.debug.print("duckdb_query returned: {d}\n", .{qr});

    if (qr != 0) {
        const err = std.mem.span(duckdb_result_error(result));
        std.debug.print("Error: {s}\n", .{err});
        duckdb_destroy_result(&result);
        return error.QueryFailed;
    }

    const n_cols = duckdb_column_count(result);
    const n_rows = duckdb_row_count(result);
    std.debug.print("Columns: {d}, Rows: {d}\n", .{ n_cols, n_rows });

    const col_name = std.mem.span(duckdb_column_name(result, 0));
    std.debug.print("Column 0 name: {s}\n", .{col_name});

    duckdb_destroy_result(&result);
    duckdb_disconnect(&conn);
    duckdb_close(&db);
    std.debug.print("Done\n", .{});
}
