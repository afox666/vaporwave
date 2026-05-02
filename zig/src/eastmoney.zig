const std = @import("std");

fn jsonToFloat(val: std.json.Value) ?f64 {
    return switch (val) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        .string => |v| std.fmt.parseFloat(f64, v) catch null,
        else => null,
    };
}

fn jsonToOwnedString(allocator: std.mem.Allocator, val: ?std.json.Value) !?[]const u8 {
    const value = val orelse return null;
    return switch (value) {
        .string => |v| try allocator.dupe(u8, v),
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        else => null,
    };
}

pub const StockInfo = struct {
    symbol: []const u8,
    name: []const u8,
    price: f64,
    change_pct: ?f64 = null,
    total_shares: ?f64 = null,
    float_shares: ?f64 = null,
    market_cap: ?f64 = null,
    industry: ?[]const u8 = null,
    list_date: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *StockInfo, a: std.mem.Allocator) void {
        a.free(self.symbol);
        a.free(self.name);
        if (self.industry) |v| a.free(v);
        if (self.list_date) |v| a.free(v);
    }
};

pub const IndustryBoard = struct {
    code: []const u8,
    name: []const u8,
};

pub const IndustryBoardResult = struct {
    items: []IndustryBoard,
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *IndustryBoardResult, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.code);
            allocator.free(item.name);
        }
        allocator.free(self.items);
    }
};

pub const IndustryStock = struct {
    symbol: []const u8,
    name: []const u8,
    price: f64,
    change_pct: f64,
    change_amount: f64,
    volume: f64,
    amount: f64,
    turnover_rate: f64,
    pe_dynamic: f64,
    pb: f64,

    pub fn deinit(self: *IndustryStock, allocator: std.mem.Allocator) void {
        allocator.free(self.symbol);
        allocator.free(self.name);
    }
};

pub const IndustryStockResult = struct {
    board_code: []const u8,
    board_name: []const u8,
    items: []IndustryStock,
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *IndustryStockResult, allocator: std.mem.Allocator) void {
        allocator.free(self.board_code);
        allocator.free(self.board_name);
        for (self.items) |*item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
    }
};

pub const FutureBar = struct {
    date: []const u8,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    change: f64,
    change_pct: f64,
    volume: f64,
    amount: f64,
    open_interest: f64,
};

pub const FutureHistoryResult = struct {
    name: []const u8,
    items: []FutureBar,
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *FutureHistoryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.items) |bar| {
            allocator.free(bar.date);
        }
        allocator.free(self.items);
    }
};

pub const CompanyProfile = struct {
    company_name: ?[]const u8 = null,
    english_name: ?[]const u8 = null,
    previous_name: ?[]const u8 = null,
    a_code: ?[]const u8 = null,
    a_name: ?[]const u8 = null,
    market: ?[]const u8 = null,
    industry: ?[]const u8 = null,
    legal_representative: ?[]const u8 = null,
    registered_capital: ?f64 = null,
    founded_date: ?[]const u8 = null,
    list_date: ?[]const u8 = null,
    website: ?[]const u8 = null,
    email: ?[]const u8 = null,
    phone: ?[]const u8 = null,
    fax: ?[]const u8 = null,
    registered_address: ?[]const u8 = null,
    office_address: ?[]const u8 = null,
    zip_code: ?[]const u8 = null,
    main_business: ?[]const u8 = null,
    business_scope: ?[]const u8 = null,
    description: ?[]const u8 = null,
    chairman: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *CompanyProfile, allocator: std.mem.Allocator) void {
        if (self.company_name) |v| allocator.free(v);
        if (self.english_name) |v| allocator.free(v);
        if (self.previous_name) |v| allocator.free(v);
        if (self.a_code) |v| allocator.free(v);
        if (self.a_name) |v| allocator.free(v);
        if (self.market) |v| allocator.free(v);
        if (self.industry) |v| allocator.free(v);
        if (self.legal_representative) |v| allocator.free(v);
        if (self.founded_date) |v| allocator.free(v);
        if (self.list_date) |v| allocator.free(v);
        if (self.website) |v| allocator.free(v);
        if (self.email) |v| allocator.free(v);
        if (self.phone) |v| allocator.free(v);
        if (self.fax) |v| allocator.free(v);
        if (self.registered_address) |v| allocator.free(v);
        if (self.office_address) |v| allocator.free(v);
        if (self.zip_code) |v| allocator.free(v);
        if (self.main_business) |v| allocator.free(v);
        if (self.business_scope) |v| allocator.free(v);
        if (self.description) |v| allocator.free(v);
        if (self.chairman) |v| allocator.free(v);
    }
};

pub const KlineResult = struct {
    items: []KlineItem,
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *KlineResult, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.date);
        }
        allocator.free(self.items);
    }
};

pub const KlineItem = struct {
    date: []const u8,
    open: f64,
    close: f64,
    high: f64,
    low: f64,
    volume: f64,
    amount: ?f64 = null,
    change_pct: ?f64 = null,
};

pub const ScanResult = struct {
    items: []StockItem,
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

pub const StockItem = struct {
    symbol: []const u8,
    name: []const u8,
    price: f64,
    change_pct: f64,
    turnover: f64,
};

// East Money API: Get stock basic info
pub fn getStockInfo(allocator: std.mem.Allocator, symbol: []const u8) !StockInfo {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const market_code: []const u8 = if (symbol[0] == '6') "1" else "0";
    const secid = try std.fmt.allocPrint(arena.allocator(), "{s}.{s}", .{ market_code, symbol });

    var url_buf: [1024]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "https://push2.eastmoney.com/api/qt/stock/get?fltt=2&invt=2&fields=f43,f57,f58,f84,f85,f116,f163,f120,f121,f162,f167,f168,f169,f170&secid={s}",
        .{secid},
    );

    const response = try httpGet(arena.allocator(), url);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});

    const data_obj = parsed.object.get("data").?;
    if (data_obj == .null) {
        return StockInfo{
            .symbol = try allocator.dupe(u8, symbol),
            .name = try allocator.dupe(u8, ""),
            .price = 0,
            .err_msg = "no data",
        };
    }

    const data = data_obj.object;

    const symbol_val = data.get("f57").?;
    const name_val = data.get("f58").?;
    const price_val = data.get("f43").?;

    const sym = if (symbol_val == .string) symbol_val.string else "unknown";
    const nm = if (name_val == .string) name_val.string else "unknown";
    const price = jsonToFloat(price_val) orelse 0;

    // Copy strings to the caller's allocator since arena will be freed
    return StockInfo{
        .symbol = try allocator.dupe(u8, sym),
        .name = try allocator.dupe(u8, nm),
        .price = price,
        .change_pct = jsonToFloat(data.get("f170") orelse .null),
        .total_shares = jsonToFloat(data.get("f84") orelse .null),
        .float_shares = jsonToFloat(data.get("f85") orelse .null),
        .market_cap = jsonToFloat(data.get("f116") orelse .null),
        .industry = try jsonToOwnedString(allocator, data.get("f127")),
        .list_date = try jsonToOwnedString(allocator, data.get("f189")),
    };
}

// East Money API: Get K-line history
pub fn getKline(allocator: std.mem.Allocator, symbol: []const u8) !KlineResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const market_code: u1 = if (symbol[0] == '6') 1 else 0;
    const secid = try std.fmt.allocPrint(arena.allocator(), "{d}.{s}", .{ market_code, symbol });

    var url_buf: [1024]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid={s}&klt=101&fqt=1&lmt=500&fields1=f1,f2,f3,f4,f5,f6,f7,f8&fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61",
        .{secid},
    );

    const response = try httpGet(arena.allocator(), url);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});

    const data_obj = parsed.object.get("data").?;
    if (data_obj == .null) {
        return KlineResult{ .items = &.{}, .err_msg = "no data" };
    }

    const data = data_obj.object;
    const klines_val = data.get("klines").?;

    if (klines_val != .array) {
        return KlineResult{ .items = &.{}, .err_msg = "no kline data" };
    }

    const klines_arr = klines_val.array.items;

    var items = std.ArrayList(KlineItem){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);

    for (klines_arr) |item_val| {
        if (item_val != .string) continue;
        const line = item_val.string;

        var iter = std.mem.splitSequence(u8, line, ",");
        const date_str = iter.next() orelse continue;
        const open_str = iter.next() orelse continue;
        const close_str = iter.next() orelse continue;
        const high_str = iter.next() orelse continue;
        const low_str = iter.next() orelse continue;
        const vol_str = iter.next() orelse continue;
        const amount_str = iter.next() orelse "";
        _ = iter.next(); // amplitude
        const change_pct_str = iter.next() orelse "";

        const open = std.fmt.parseFloat(f64, open_str) catch continue;
        const close = std.fmt.parseFloat(f64, close_str) catch continue;
        const high = std.fmt.parseFloat(f64, high_str) catch continue;
        const low = std.fmt.parseFloat(f64, low_str) catch continue;
        const volume = std.fmt.parseFloat(f64, vol_str) catch continue;

        try items.append(allocator, KlineItem{
            .date = try allocator.dupe(u8, date_str),
            .open = open,
            .close = close,
            .high = high,
            .low = low,
            .volume = volume,
            .amount = std.fmt.parseFloat(f64, amount_str) catch null,
            .change_pct = std.fmt.parseFloat(f64, change_pct_str) catch null,
        });
    }

    const slice = try items.toOwnedSlice(allocator);
    return KlineResult{ .items = slice };
}

// East Money API: Scan market
pub fn scanMarket(allocator: std.mem.Allocator, top_n: u16) !ScanResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const page_size: u16 = @min(top_n * 2, 500);

    var url_buf: [2048]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "https://82.push2.eastmoney.com/api/qt/clist/get?pn=1&pz={d}&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f6&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048&fields=f2,f3,f5,f6,f12,f14",
        .{page_size},
    );

    const response = try httpGetClist(arena.allocator(), url);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});

    const data_obj = parsed.object.get("data").?;
    if (data_obj == .null) {
        return ScanResult{ .items = &.{}, .err_msg = "no data" };
    }

    const data = data_obj.object;
    const diff_val = data.get("diff").?;

    if (diff_val != .array) {
        return ScanResult{ .items = &.{}, .err_msg = "no diff data" };
    }

    const diff_arr = diff_val.array.items;

    var items = std.ArrayList(StockItem){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);

    for (diff_arr) |item_val| {
        if (item_val != .object) continue;
        const obj = item_val.object;

        const code = obj.get("f12").?;
        const name = obj.get("f14").?;
        const price = obj.get("f2").?;
        const change = obj.get("f3").?;
        const turnover = obj.get("f6").?;

        if (code == .null or name == .null or price == .null) continue;

        const sym = if (code == .string) code.string else continue;
        const nm = if (name == .string) name.string else continue;
        const p = jsonToFloat(price) orelse 0;
        const c = jsonToFloat(change) orelse 0;
        const t = jsonToFloat(turnover) orelse 0;

        try items.append(allocator, StockItem{
            .symbol = try allocator.dupe(u8, sym),
            .name = try allocator.dupe(u8, nm),
            .price = p,
            .change_pct = c,
            .turnover = t,
        });
    }

    const all = try items.toOwnedSlice(allocator);

    const n = @min(@as(usize, top_n), all.len);
    var top = try allocator.alloc(StockItem, n);

    var used = std.bit_set.ArrayBitSet(usize, 500).initEmpty();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var best_idx: usize = 0;
        var best_turnover: f64 = -1;
        var j: usize = 0;
        while (j < all.len) : (j += 1) {
            if (!used.isSet(j) and all[j].turnover > best_turnover) {
                best_turnover = all[j].turnover;
                best_idx = j;
            }
        }
        used.set(best_idx);
        top[i] = all[best_idx];
    }

    allocator.free(all);

    return ScanResult{ .items = top };
}

fn normalizeIndustryName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "工业金属")) return "有色金属";
    if (std.mem.eql(u8, name, "白酒")) return "酿酒行业";
    if (std.mem.eql(u8, name, "饮料制造")) return "酿酒行业";
    if (std.mem.eql(u8, name, "酒")) return "酿酒行业";
    if (std.mem.eql(u8, name, "食品饮料")) return "食品饮料";
    return name;
}

pub fn getIndustryBoards(allocator: std.mem.Allocator) !IndustryBoardResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const url =
        "https://17.push2.eastmoney.com/api/qt/clist/get?pn=1&pz=100&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=m:90+t:2+f:!50&fields=f12,f14";

    const response = try httpGetClist(arena.allocator(), url);
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});

    const data_obj = parsed.object.get("data") orelse return IndustryBoardResult{ .items = &.{}, .err_msg = "no data" };
    if (data_obj == .null) return IndustryBoardResult{ .items = &.{}, .err_msg = "no data" };
    const diff_val = data_obj.object.get("diff") orelse return IndustryBoardResult{ .items = &.{}, .err_msg = "no diff data" };
    if (diff_val != .array) return IndustryBoardResult{ .items = &.{}, .err_msg = "no diff data" };

    var items = std.ArrayList(IndustryBoard){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);
    errdefer {
        for (items.items) |item| {
            allocator.free(item.code);
            allocator.free(item.name);
        }
    }

    for (diff_val.array.items) |item_val| {
        if (item_val != .object) continue;
        const obj = item_val.object;
        const code_val = obj.get("f12") orelse continue;
        const name_val = obj.get("f14") orelse continue;
        if (code_val != .string or name_val != .string) continue;
        try items.append(allocator, IndustryBoard{
            .code = try allocator.dupe(u8, code_val.string),
            .name = try allocator.dupe(u8, name_val.string),
        });
    }

    return IndustryBoardResult{ .items = try items.toOwnedSlice(allocator) };
}

pub fn getIndustryBoardCode(allocator: std.mem.Allocator, industry_name: []const u8) !IndustryBoard {
    const normalized = normalizeIndustryName(industry_name);
    if (std.mem.startsWith(u8, normalized, "BK")) {
        return IndustryBoard{
            .code = try allocator.dupe(u8, normalized),
            .name = try allocator.dupe(u8, normalized),
        };
    }

    var boards = try getIndustryBoards(allocator);
    defer boards.deinit(allocator);

    for (boards.items) |board| {
        if (std.mem.eql(u8, board.name, normalized)) {
            return IndustryBoard{
                .code = try allocator.dupe(u8, board.code),
                .name = try allocator.dupe(u8, board.name),
            };
        }
    }

    for (boards.items) |board| {
        if (std.mem.indexOf(u8, board.name, normalized) != null or std.mem.indexOf(u8, normalized, board.name) != null) {
            return IndustryBoard{
                .code = try allocator.dupe(u8, board.code),
                .name = try allocator.dupe(u8, board.name),
            };
        }
    }

    return error.IndustryNotFound;
}

pub fn getIndustryStocks(allocator: std.mem.Allocator, industry_name: []const u8) !IndustryStockResult {
    const board = try getIndustryBoardCode(allocator, industry_name);
    defer {
        allocator.free(board.code);
        allocator.free(board.name);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const url = try std.fmt.allocPrint(
        aa,
        "https://29.push2.eastmoney.com/api/qt/clist/get?pn=1&pz=200&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f3&fs=b:{s}+f:!50&fields=f2,f3,f4,f5,f6,f8,f9,f12,f14,f23",
        .{board.code},
    );

    const response = try httpGetClist(aa, url);
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, response, .{});

    const data_obj = parsed.object.get("data") orelse return IndustryStockResult{
        .board_code = try allocator.dupe(u8, board.code),
        .board_name = try allocator.dupe(u8, board.name),
        .items = &.{},
        .err_msg = "no data",
    };
    if (data_obj == .null) return IndustryStockResult{
        .board_code = try allocator.dupe(u8, board.code),
        .board_name = try allocator.dupe(u8, board.name),
        .items = &.{},
        .err_msg = "no data",
    };

    const diff_val = data_obj.object.get("diff") orelse return IndustryStockResult{
        .board_code = try allocator.dupe(u8, board.code),
        .board_name = try allocator.dupe(u8, board.name),
        .items = &.{},
        .err_msg = "no diff data",
    };
    if (diff_val != .array) return IndustryStockResult{
        .board_code = try allocator.dupe(u8, board.code),
        .board_name = try allocator.dupe(u8, board.name),
        .items = &.{},
        .err_msg = "no diff data",
    };

    var items = std.ArrayList(IndustryStock){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
    }

    for (diff_val.array.items) |item_val| {
        if (item_val != .object) continue;
        const obj = item_val.object;
        const code = obj.get("f12") orelse continue;
        const name = obj.get("f14") orelse continue;
        if (code != .string or name != .string) continue;

        try items.append(allocator, IndustryStock{
            .symbol = try allocator.dupe(u8, code.string),
            .name = try allocator.dupe(u8, name.string),
            .price = jsonToFloat(obj.get("f2") orelse .null) orelse 0,
            .change_pct = jsonToFloat(obj.get("f3") orelse .null) orelse 0,
            .change_amount = jsonToFloat(obj.get("f4") orelse .null) orelse 0,
            .volume = jsonToFloat(obj.get("f5") orelse .null) orelse 0,
            .amount = jsonToFloat(obj.get("f6") orelse .null) orelse 0,
            .turnover_rate = jsonToFloat(obj.get("f8") orelse .null) orelse 0,
            .pe_dynamic = jsonToFloat(obj.get("f9") orelse .null) orelse 0,
            .pb = jsonToFloat(obj.get("f23") orelse .null) orelse 0,
        });
    }

    return IndustryStockResult{
        .board_code = try allocator.dupe(u8, board.code),
        .board_name = try allocator.dupe(u8, board.name),
        .items = try items.toOwnedSlice(allocator),
    };
}

const FutureContract = struct {
    name: []const u8,
    secid: []const u8,
};

fn futureContract(symbol: []const u8) ?FutureContract {
    if (std.mem.eql(u8, symbol, "碳酸锂主连")) return .{ .name = "碳酸锂主连", .secid = "225.lcm" };
    if (std.mem.eql(u8, symbol, "沪铜主连")) return .{ .name = "沪铜主连", .secid = "113.cum" };
    if (std.mem.eql(u8, symbol, "沪铝主连")) return .{ .name = "沪铝主连", .secid = "113.alm" };
    if (std.mem.eql(u8, symbol, "沪锌主连")) return .{ .name = "沪锌主连", .secid = "113.znm" };
    if (std.mem.eql(u8, symbol, "螺纹钢主连")) return .{ .name = "螺纹钢主连", .secid = "113.rbm" };
    if (std.mem.eql(u8, symbol, "铁矿石主连")) return .{ .name = "铁矿石主连", .secid = "114.im" };
    return null;
}

pub fn getFutureHistory(allocator: std.mem.Allocator, symbol: []const u8, limit: u16) !FutureHistoryResult {
    const contract = futureContract(symbol) orelse return error.FutureNotMapped;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const url = try std.fmt.allocPrint(
        aa,
        "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid={s}&klt=101&fqt=1&lmt={d}&end=20500000&iscca=1&fields1=f1,f2,f3,f4,f5,f6,f7,f8&fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61,f62,f63,f64&ut=7eea3edcaed734bea9cbfc24409ed989&forcect=1",
        .{ contract.secid, if (limit > 0) limit else 10000 },
    );

    const response = httpGet(aa, url) catch |err| {
        std.debug.print("Future daily kline error for {s}: {any}, trying trends fallback\n", .{ symbol, err });
        return getFutureTrendHistory(allocator, symbol);
    };
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, response, .{});

    const data_obj = parsed.object.get("data") orelse return FutureHistoryResult{
        .name = try allocator.dupe(u8, contract.name),
        .items = &.{},
        .err_msg = "no data",
    };
    if (data_obj == .null) return FutureHistoryResult{
        .name = try allocator.dupe(u8, contract.name),
        .items = &.{},
        .err_msg = "no data",
    };
    const klines_val = data_obj.object.get("klines") orelse return FutureHistoryResult{
        .name = try allocator.dupe(u8, contract.name),
        .items = &.{},
        .err_msg = "no kline data",
    };
    if (klines_val != .array) return FutureHistoryResult{
        .name = try allocator.dupe(u8, contract.name),
        .items = &.{},
        .err_msg = "no kline data",
    };

    var items = std.ArrayList(FutureBar){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);
    errdefer {
        for (items.items) |bar| allocator.free(bar.date);
    }

    for (klines_val.array.items) |item_val| {
        if (item_val != .string) continue;
        var iter = std.mem.splitScalar(u8, item_val.string, ',');
        const date_str = iter.next() orelse continue;
        const open_str = iter.next() orelse continue;
        const close_str = iter.next() orelse continue;
        const high_str = iter.next() orelse continue;
        const low_str = iter.next() orelse continue;
        const volume_str = iter.next() orelse continue;
        const amount_str = iter.next() orelse continue;
        _ = iter.next();
        const change_pct_str = iter.next() orelse continue;
        const change_str = iter.next() orelse continue;
        _ = iter.next();
        _ = iter.next();
        const open_interest_str = iter.next() orelse "0";

        try items.append(allocator, FutureBar{
            .date = try allocator.dupe(u8, date_str),
            .open = std.fmt.parseFloat(f64, open_str) catch 0,
            .high = std.fmt.parseFloat(f64, high_str) catch 0,
            .low = std.fmt.parseFloat(f64, low_str) catch 0,
            .close = std.fmt.parseFloat(f64, close_str) catch 0,
            .change = std.fmt.parseFloat(f64, change_str) catch 0,
            .change_pct = std.fmt.parseFloat(f64, change_pct_str) catch 0,
            .volume = std.fmt.parseFloat(f64, volume_str) catch 0,
            .amount = std.fmt.parseFloat(f64, amount_str) catch 0,
            .open_interest = std.fmt.parseFloat(f64, open_interest_str) catch 0,
        });
    }

    return FutureHistoryResult{
        .name = try allocator.dupe(u8, contract.name),
        .items = try items.toOwnedSlice(allocator),
    };
}

fn getFutureTrendHistory(allocator: std.mem.Allocator, symbol: []const u8) !FutureHistoryResult {
    const contract = futureContract(symbol) orelse return error.FutureNotMapped;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const url = try std.fmt.allocPrint(
        aa,
        "https://push2.eastmoney.com/api/qt/stock/trends2/get?secid={s}&fields1=f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13&fields2=f51,f52,f53,f54,f55,f56,f57,f58&ndays=5&iscr=0",
        .{contract.secid},
    );

    const response = try httpGet(aa, url);
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, aa, response, .{});

    const data_obj = parsed.object.get("data") orelse return FutureHistoryResult{
        .name = try allocator.dupe(u8, contract.name),
        .items = &.{},
        .err_msg = "no trends data",
    };
    if (data_obj == .null) return FutureHistoryResult{
        .name = try allocator.dupe(u8, contract.name),
        .items = &.{},
        .err_msg = "no trends data",
    };
    const trends_val = data_obj.object.get("trends") orelse return FutureHistoryResult{
        .name = try allocator.dupe(u8, contract.name),
        .items = &.{},
        .err_msg = "no trends",
    };
    if (trends_val != .array) return FutureHistoryResult{
        .name = try allocator.dupe(u8, contract.name),
        .items = &.{},
        .err_msg = "no trends",
    };

    var items = std.ArrayList(FutureBar){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);
    errdefer {
        for (items.items) |bar| allocator.free(bar.date);
    }

    var prev_close: ?f64 = null;
    for (trends_val.array.items) |item_val| {
        if (item_val != .string) continue;
        var iter = std.mem.splitScalar(u8, item_val.string, ',');
        const date_str = iter.next() orelse continue;
        const open_str = iter.next() orelse continue;
        const close_str = iter.next() orelse continue;
        const high_str = iter.next() orelse continue;
        const low_str = iter.next() orelse continue;
        const volume_str = iter.next() orelse continue;
        const amount_str = iter.next() orelse continue;

        const close = std.fmt.parseFloat(f64, close_str) catch 0;
        const change = if (prev_close) |prev| close - prev else 0;
        const change_pct = if (prev_close) |prev| if (prev != 0) (close - prev) / prev * 100.0 else 0 else 0;
        prev_close = close;

        try items.append(allocator, FutureBar{
            .date = try allocator.dupe(u8, date_str),
            .open = std.fmt.parseFloat(f64, open_str) catch 0,
            .high = std.fmt.parseFloat(f64, high_str) catch 0,
            .low = std.fmt.parseFloat(f64, low_str) catch 0,
            .close = close,
            .change = change,
            .change_pct = change_pct,
            .volume = std.fmt.parseFloat(f64, volume_str) catch 0,
            .amount = std.fmt.parseFloat(f64, amount_str) catch 0,
            .open_interest = 0,
        });
    }

    return FutureHistoryResult{
        .name = try allocator.dupe(u8, contract.name),
        .items = try items.toOwnedSlice(allocator),
    };
}

fn readChildStdout(allocator: std.mem.Allocator, child: *std.process.Child, max_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (child.stdout) |stdout| {
        const n = try stdout.read(&buf);
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
        if (out.items.len > max_bytes) {
            _ = child.kill() catch {};
            return error.ResponseTooLarge;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn cninfoAcceptKey(allocator: std.mem.Allocator) ![]u8 {
    var child = std.process.Child.init(&.{
        "openssl",
        "enc",
        "-aes-128-cbc",
        "-K",
        "31323334353637383837363534333231",
        "-iv",
        "31323334353637383837363534333231",
        "-base64",
        "-A",
    }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const ts = try std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()});
    defer allocator.free(ts);
    const stdin = child.stdin.?;
    try stdin.writeAll(ts);
    stdin.close();
    child.stdin = null;

    const raw = try readChildStdout(allocator, &child, 1024);
    errdefer allocator.free(raw);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0 or raw.len == 0) return error.CninfoKeyFailed;

    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    const key = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return key;
}

fn cninfoProfileJson(allocator: std.mem.Allocator, symbol: []const u8) ![]u8 {
    const mcode = try cninfoAcceptKey(allocator);
    defer allocator.free(mcode);

    const url = try std.fmt.allocPrint(allocator, "https://webapi.cninfo.com.cn/api/sysapi/p_sysapi1133?scode={s}", .{symbol});
    defer allocator.free(url);
    const accept_header = try std.fmt.allocPrint(allocator, "Accept-Enckey: {s}", .{mcode});
    defer allocator.free(accept_header);

    var child = std.process.Child.init(&.{
        "curl",
        "-sS",
        "--max-time",
        "20",
        "-X",
        "POST",
        url,
        "-H",
        accept_header,
        "-H",
        "Accept: */*",
        "-H",
        "Origin: https://webapi.cninfo.com.cn",
        "-H",
        "Referer: https://webapi.cninfo.com.cn/",
        "-H",
        "X-Requested-With: XMLHttpRequest",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const raw = try readChildStdout(allocator, &child, 4 * 1024 * 1024);
    errdefer allocator.free(raw);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0 or raw.len == 0) return error.CninfoRequestFailed;
    return raw;
}

pub fn getCompanyProfile(allocator: std.mem.Allocator, symbol: []const u8) !CompanyProfile {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const response = try cninfoProfileJson(arena.allocator(), symbol);
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});

    const count = jsonToFloat(parsed.object.get("count") orelse .null) orelse 0;
    if (count < 1) return CompanyProfile{ .err_msg = "no company profile" };

    const records = parsed.object.get("records") orelse return CompanyProfile{ .err_msg = "no records" };
    if (records != .array or records.array.items.len == 0) return CompanyProfile{ .err_msg = "no records" };
    const rec = records.array.items[0];
    if (rec != .object) return CompanyProfile{ .err_msg = "bad profile record" };
    const obj = rec.object;

    return CompanyProfile{
        .company_name = try jsonToOwnedString(allocator, obj.get("ORGNAME")),
        .english_name = try jsonToOwnedString(allocator, obj.get("F001V")),
        .previous_name = try jsonToOwnedString(allocator, obj.get("F002V")),
        .a_code = try jsonToOwnedString(allocator, obj.get("ASECCODE")),
        .a_name = try jsonToOwnedString(allocator, obj.get("ASECNAME")),
        .market = try jsonToOwnedString(allocator, obj.get("MARKET")),
        .industry = try jsonToOwnedString(allocator, obj.get("F032V")),
        .legal_representative = try jsonToOwnedString(allocator, obj.get("F003V")),
        .registered_capital = jsonToFloat(obj.get("F007N") orelse .null),
        .founded_date = try jsonToOwnedString(allocator, obj.get("F010D")),
        .list_date = try jsonToOwnedString(allocator, obj.get("F006D")),
        .website = try jsonToOwnedString(allocator, obj.get("F011V")),
        .email = try jsonToOwnedString(allocator, obj.get("F012V")),
        .phone = try jsonToOwnedString(allocator, obj.get("F013V")),
        .fax = try jsonToOwnedString(allocator, obj.get("F014V")),
        .registered_address = try jsonToOwnedString(allocator, obj.get("F004V")),
        .office_address = try jsonToOwnedString(allocator, obj.get("F005V")),
        .zip_code = try jsonToOwnedString(allocator, obj.get("F006V")),
        .main_business = try jsonToOwnedString(allocator, obj.get("F015V")),
        .business_scope = try jsonToOwnedString(allocator, obj.get("F016V")),
        .description = try jsonToOwnedString(allocator, obj.get("F017V")),
        .chairman = try jsonToOwnedString(allocator, obj.get("F018V")),
    };
}

// Generic HTTP GET using std.http.Client
pub fn httpGet(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var redirect_buffer: [1024]u8 = undefined;

    var io_writer = std.io.Writer.Allocating.init(allocator);
    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36" },
        .{ .name = "Accept", .value = "application/json,text/plain,*/*" },
        .{ .name = "Referer", .value = "https://quote.eastmoney.com/" },
    };

    const result = client.fetch(.{
        .location = .{ .url = url },
        .redirect_buffer = &redirect_buffer,
        .response_writer = &io_writer.writer,
        .extra_headers = &headers,
    }) catch |err| {
        io_writer.deinit();
        return httpGetViaCurl(allocator, url, err);
    };

    if (result.status != .ok) {
        io_writer.deinit();
        return error.HttpError;
    }

    try io_writer.writer.flush();
    return io_writer.toOwnedSlice();
}

fn httpGetViaCurl(allocator: std.mem.Allocator, url: []const u8, original_err: anyerror) ![]const u8 {
    var child = std.process.Child.init(&.{
        "curl",
        "-L",
        "-sS",
        "--retry",
        "3",
        "--retry-all-errors",
        "--max-time",
        "30",
        "-H",
        "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
        "-H",
        "Accept: application/json,text/plain,*/*",
        "-H",
        "Referer: https://quote.eastmoney.com/",
        url,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return original_err;

    var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (child.stdout) |stdout| {
        const n = stdout.read(&buf) catch {
            _ = child.kill() catch {};
            return original_err;
        };
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
        if (out.items.len > 32 * 1024 * 1024) {
            _ = child.kill() catch {};
            return error.ResponseTooLarge;
        }
    }

    const term = child.wait() catch return original_err;
    if (term != .Exited or term.Exited != 0 or out.items.len == 0) {
        out.deinit(allocator);
        return original_err;
    }

    return out.toOwnedSlice(allocator);
}

fn httpGetClist(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    return httpGet(allocator, url) catch httpGetPlainViaCurl(allocator, url);
}

fn httpGetPlainViaCurl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var child = std.process.Child.init(&.{
        "curl",
        "-L",
        "-sS",
        "--retry",
        "3",
        "--retry-all-errors",
        "--max-time",
        "30",
        url,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (child.stdout) |stdout| {
        const n = stdout.read(&buf) catch {
            _ = child.kill() catch {};
            return error.HttpPlainCurlFailed;
        };
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
        if (out.items.len > 32 * 1024 * 1024) {
            _ = child.kill() catch {};
            return error.ResponseTooLarge;
        }
    }

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0 or out.items.len == 0) {
        out.deinit(allocator);
        return error.HttpPlainCurlFailed;
    }

    return out.toOwnedSlice(allocator);
}

/// Convert GBK-encoded bytes to UTF-8 using system iconv command
pub fn gbkToUtf8(allocator: std.mem.Allocator, gbk: []const u8) ![]u8 {
    var child = std.process.Child.init(&.{ "iconv", "-f", "GBK", "-t", "UTF-8" }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const stdin = child.stdin.?;
    try stdin.writeAll(gbk);
    stdin.close();
    child.stdin = null;

    var out_list = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer out_list.deinit(allocator);

    var buf: [256]u8 = undefined;
    while (child.stdout) |stdout| {
        const n = try stdout.read(&buf);
        if (n == 0) break;
        try out_list.appendSlice(allocator, buf[0..n]);
    }

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        out_list.deinit(allocator);
        return error.IconvFailed;
    }

    return out_list.toOwnedSlice(allocator);
}

pub const SearchResult = struct {
    items: []SearchItem,
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.symbol);
            allocator.free(item.name);
        }
        allocator.free(self.items);
    }
};

pub const SearchItem = struct {
    symbol: []const u8,
    name: []const u8,
};

/// Get the full A-share spot list from EastMoney's paged market endpoint.
pub fn getAShareSpot(allocator: std.mem.Allocator, max_items: usize) !SearchResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var items = std.ArrayList(SearchItem){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);
    errdefer {
        for (items.items) |item| {
            allocator.free(item.symbol);
            allocator.free(item.name);
        }
    }

    const page_size: usize = 100;
    var page: usize = 1;
    var seen: usize = 0;
    var total: usize = 0;

    while (page <= 100) : (page += 1) {
        var url_buf: [2048]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "https://82.push2.eastmoney.com/api/qt/clist/get?pn={d}&pz={d}&po=1&np=1&ut=bd1d9ddb04089700cf9c27f6f7426281&fltt=2&invt=2&fid=f6&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048&fields=f12,f14",
            .{ page, page_size },
        );

        const response = try httpGetClist(arena.allocator(), url);
        var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});

        const data_obj = parsed.object.get("data") orelse break;
        if (data_obj == .null) break;
        const data = data_obj.object;

        if (total == 0) {
            if (jsonToFloat(data.get("total") orelse .null)) |v| {
                if (v > 0) total = @intFromFloat(v);
            }
        }

        const diff_val = data.get("diff") orelse break;
        if (diff_val != .array or diff_val.array.items.len == 0) break;

        for (diff_val.array.items) |item_val| {
            if (max_items > 0 and items.items.len >= max_items) break;
            if (item_val != .object) continue;
            const obj = item_val.object;
            const code = obj.get("f12") orelse continue;
            const name = obj.get("f14") orelse continue;
            if (code != .string or name != .string) continue;

            try items.append(allocator, SearchItem{
                .symbol = try allocator.dupe(u8, code.string),
                .name = try allocator.dupe(u8, name.string),
            });
        }

        seen += diff_val.array.items.len;
        if (max_items > 0 and items.items.len >= max_items) break;
        if (diff_val.array.items.len < page_size) break;
        if (total > 0 and seen >= total) break;
    }

    if (items.items.len == 0) {
        return SearchResult{ .items = &.{}, .err_msg = "no data" };
    }

    return SearchResult{ .items = try items.toOwnedSlice(allocator) };
}

/// Search stocks by code or name using EastMoney search API
pub fn searchStock(allocator: std.mem.Allocator, query: []const u8) !SearchResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // URL-decode then URL-encode the query (handles double-encoding from HTTP)
    const decoded = try urlDecode(arena.allocator(), query);
    const encoded = try urlEncode(arena.allocator(), decoded);

    var url_buf: [1024]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "https://searchapi.eastmoney.com/api/suggest/get?input={s}&type=14&token=DCEFDD8C67338FCCC98ABFCD0D946BDD&count=10",
        .{encoded},
    );

    const response = try httpGet(arena.allocator(), url);
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});

    const qct = parsed.object.get("QuotationCodeTable").?;
    if (qct != .object) return SearchResult{ .items = &.{}, .err_msg = "no result" };

    const qct_obj = qct.object;
    const data_val = qct_obj.get("Data").?;
    if (data_val != .array) return SearchResult{ .items = &.{}, .err_msg = "no data" };

    const data_arr = data_val.array.items;

    var items = std.ArrayList(SearchItem){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);

    for (data_arr) |item_val| {
        if (item_val != .object) continue;
        const obj = item_val.object;

        const code = obj.get("Code").?;
        const name = obj.get("Name").?;

        if (code == .null or name == .null) continue;

        const sym = if (code == .string) code.string else continue;
        const nm = if (name == .string) name.string else continue;

        try items.append(allocator, SearchItem{
            .symbol = try allocator.dupe(u8, sym),
            .name = try allocator.dupe(u8, nm),
        });
    }

    const slice = try items.toOwnedSlice(allocator);
    return SearchResult{ .items = slice };
}

/// URL-decode a string (percent-decoding)
pub fn urlDecode(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer out.deinit(arena);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex, 16) catch {
                try out.append(arena, input[i]);
                continue;
            };
            try out.append(arena, byte);
            i += 2;
        } else if (input[i] == '+') {
            try out.append(arena, ' ');
        } else {
            try out.append(arena, input[i]);
        }
    }

    return out.toOwnedSlice(arena);
}

/// URL-encode a string (percent-encoding)
fn urlEncode(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer out.deinit(arena);

    for (input) |b| {
        switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => {
                try out.append(arena, b);
            },
            else => {
                var hex: [2]u8 = undefined;
                _ = std.fmt.bufPrint(&hex, "{X:0>2}", .{b}) catch unreachable;
                try out.append(arena, '%');
                try out.append(arena, hex[0]);
                try out.append(arena, hex[1]);
            },
        }
    }

    return out.toOwnedSlice(arena);
}

/// Get daily K-line data with amount and change_pct fields
pub fn getDailyK(allocator: std.mem.Allocator, symbol: []const u8, days: u16) !KlineResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const market_code: u1 = if (symbol[0] == '6') 1 else 0;
    const secid = try std.fmt.allocPrint(arena.allocator(), "{d}.{s}", .{ market_code, symbol });

    const lmt: u16 = if (days > 0) days else 500;

    var url_buf: [1024]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid={s}&klt=101&fqt=1&lmt={d}&fields1=f1,f2,f3,f4,f5,f6,f7,f8&fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61",
        .{ secid, lmt },
    );

    const response = try httpGet(arena.allocator(), url);
    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), response, .{});

    const data_obj = parsed.object.get("data").?;
    if (data_obj == .null) {
        return KlineResult{ .items = &.{}, .err_msg = "no data" };
    }

    const data = data_obj.object;
    const klines_val = data.get("klines").?;

    if (klines_val != .array) {
        return KlineResult{ .items = &.{}, .err_msg = "no kline data" };
    }

    const klines_arr = klines_val.array.items;

    var items = std.ArrayList(KlineItem){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);

    for (klines_arr) |item_val| {
        if (item_val != .string) continue;
        const line = item_val.string;

        var iter = std.mem.splitSequence(u8, line, ",");
        const date_str = iter.next() orelse continue;
        const open_str = iter.next() orelse continue;
        const close_str = iter.next() orelse continue;
        const high_str = iter.next() orelse continue;
        const low_str = iter.next() orelse continue;
        const vol_str = iter.next() orelse continue;
        const amount_str = iter.next() orelse "";
        _ = iter.next(); // amplitude
        const change_pct_str = iter.next() orelse "";

        const open = std.fmt.parseFloat(f64, open_str) catch continue;
        const close = std.fmt.parseFloat(f64, close_str) catch continue;
        const high = std.fmt.parseFloat(f64, high_str) catch continue;
        const low = std.fmt.parseFloat(f64, low_str) catch continue;
        const volume = std.fmt.parseFloat(f64, vol_str) catch continue;

        try items.append(allocator, KlineItem{
            .date = try allocator.dupe(u8, date_str),
            .open = open,
            .close = close,
            .high = high,
            .low = low,
            .volume = volume,
            .amount = std.fmt.parseFloat(f64, amount_str) catch null,
            .change_pct = std.fmt.parseFloat(f64, change_pct_str) catch null,
        });
    }

    const slice = try items.toOwnedSlice(allocator);
    return KlineResult{ .items = slice };
}
