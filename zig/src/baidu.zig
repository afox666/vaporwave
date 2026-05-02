const std = @import("std");
const eastmoney = @import("eastmoney.zig");

fn jsonToFloat(val: std.json.Value) ?f64 {
    return switch (val) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub const ValuationData = struct {
    current_pe: ?f64 = null,
    dates: []const u8 = "",
    values: []f64 = &.{},
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *ValuationData, allocator: std.mem.Allocator) void {
        allocator.free(self.dates);
        allocator.free(self.values);
    }
};

pub fn getValuation(allocator: std.mem.Allocator, symbol: []const u8) !ValuationData {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const url = try std.fmt.allocPrint(arena.allocator(),
        "https://gushitong.baidu.com/opendata?openapi=1&dspName=iphone&client=app&query=%E5%B8%82%E7%9B%88%E7%8E%87%28TTM%29&code={s}&resource_id=51171&market=ab&tag=%E5%B8%82%E7%9B%88%E7%8E%87%28TTM%29&chart_select=%E8%BF%91%E4%BA%94%E5%B9%B4&finClientType=pc",
        .{symbol},
    );

    const response = try eastmoney.httpGet(arena.allocator(), url);

    // Convert GBK response to UTF-8 before JSON parsing
    const utf8_response = try eastmoney.gbkToUtf8(allocator, response);
    defer allocator.free(utf8_response);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), utf8_response, .{});

    const result_arr = parsed.object.get("Result").?;
    if (result_arr != .array or result_arr.array.items.len == 0) {
        return ValuationData{ .err_msg = "no result" };
    }

    const first = result_arr.array.items[0];
    if (first != .object) return ValuationData{ .err_msg = "bad result format" };

    const display = first.object.get("DisplayData").?;
    if (display != .object) return ValuationData{ .err_msg = "no display data" };

    const result_data = display.object.get("resultData").?;
    if (result_data != .object) return ValuationData{ .err_msg = "no resultData" };

    const tpl = result_data.object.get("tplData").?;
    if (tpl != .object) return ValuationData{ .err_msg = "no tplData" };

    const result_obj = tpl.object.get("result").?;
    if (result_obj != .object) return ValuationData{ .err_msg = "no result" };

    const chart_info = result_obj.object.get("chartInfo").?;
    if (chart_info != .array or chart_info.array.items.len == 0) {
        return ValuationData{ .err_msg = "no chart data" };
    }

    const chart_first = chart_info.array.items[0];
    if (chart_first != .object) return ValuationData{ .err_msg = "bad chart format" };

    const body = chart_first.object.get("body").?;
    if (body != .array) return ValuationData{ .err_msg = "no body data" };

    var dates = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    var values = std.ArrayList(f64){ .items = &.{}, .capacity = 0 };
    errdefer {
        dates.deinit(allocator);
        values.deinit(allocator);
    }

    var first_entry = true;
    var current_pe: ?f64 = null;

    for (body.array.items) |entry_val| {
        if (entry_val != .array or entry_val.array.items.len < 2) continue;
        const entry = entry_val.array.items;

        const date_val = entry[0];
        const value_val = entry[1];

        if (date_val != .string) continue;
        const date_str = date_val.string;

        const value_num = jsonToFloat(value_val) orelse continue;

        if (first_entry) {
            current_pe = value_num;
            first_entry = false;
        }

        if (!first_entry) {
            try dates.appendSlice(allocator, date_str);
            try dates.append(allocator, ',');
        }
        try values.append(allocator, value_num);
    }

    if (dates.items.len > 0) _ = dates.pop();

    return ValuationData{
        .current_pe = current_pe,
        .dates = try dates.toOwnedSlice(allocator),
        .values = try values.toOwnedSlice(allocator),
    };
}
