const std = @import("std");

pub fn escape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);

    for (input) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "''");
        } else if (ch == '\n' or ch == '\r') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, ch);
        }
    }

    return try out.toOwnedSlice(allocator);
}
