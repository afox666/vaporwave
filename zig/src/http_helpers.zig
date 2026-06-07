const std = @import("std");

pub fn parseContentLength(headers: []const u8) usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, ':')) |idx| {
            const name = std.mem.trim(u8, line[0..idx], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                const raw = std.mem.trim(u8, line[idx + 1 ..], " \t");
                return std.fmt.parseInt(usize, raw, 10) catch 0;
            }
        }
    }
    return 0;
}

pub fn stripQuery(value: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, value, '?')) |idx| {
        return value[0..idx];
    }
    return value;
}

pub fn queryParam(uri: []const u8, name: []const u8) ?[]const u8 {
    const query_start = std.mem.indexOfScalar(u8, uri, '?') orelse return null;
    const query = uri[query_start + 1 ..];
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], name)) {
            return part[eq + 1 ..];
        }
    }
    return null;
}

pub fn respondJson(allocator: std.mem.Allocator, stream: std.net.Stream, status: u16, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(body);
    try respond(stream, status, body);
}

pub fn respondError(allocator: std.mem.Allocator, stream: std.net.Stream, status: u16, msg: []const u8) !void {
    const E = struct { err: []const u8 };
    const body = try std.json.Stringify.valueAlloc(allocator, E{ .err = msg }, .{});
    defer allocator.free(body);
    try respond(stream, status, body);
}

pub fn respondOptions(stream: std.net.Stream) !void {
    try stream.writeAll(
        "HTTP/1.1 204 No Content\r\n" ++
            "Content-Length: 0\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: Content-Type\r\n" ++
            "Access-Control-Max-Age: 86400\r\n" ++
            "Connection: close\r\n\r\n",
    );
}

pub fn respond(stream: std.net.Stream, status: u16, body: []const u8) !void {
    const status_text = switch (status) {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        501 => "Not Implemented",
        500 => "Internal Server Error",
        else => "Unknown",
    };

    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        .{ status, status_text, body.len },
    );

    try stream.writeAll(header);
    try stream.writeAll(body);
}
