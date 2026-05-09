const std = @import("std");
pub const factor_specs = @import("backtest_factor_specs.zig");

pub const MAX_FACTORS = 9;

pub const Factor = enum {
    momentum_20d,
    momentum_60d,
    momentum_120d,
    pe_percentile,
    price_percentile,
    volatility_20d,
    volume_change,
    rsi_14,
    ma_deviation_20,
};

pub const FactorSpec = union(enum) {
    builtin: Factor,
    custom: factor_specs.CustomFactor,

    pub fn deinit(self: *FactorSpec, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .builtin => {},
            .custom => |*custom| custom.deinit(allocator),
        }
    }

    pub fn isCustom(self: FactorSpec) bool {
        return switch (self) {
            .builtin => false,
            .custom => true,
        };
    }

    pub fn key(self: FactorSpec) []const u8 {
        return switch (self) {
            .builtin => |factor| factorName(factor),
            .custom => |custom| custom.key,
        };
    }

    pub fn label(self: FactorSpec) []const u8 {
        return switch (self) {
            .builtin => |factor| factorName(factor),
            .custom => |custom| custom.name,
        };
    }

    pub fn lookback(self: FactorSpec) usize {
        return switch (self) {
            .builtin => |factor| factorLookback(factor),
            .custom => |custom| custom.lookback,
        };
    }

    pub fn higherIsBetter(self: FactorSpec) bool {
        return switch (self) {
            .builtin => |factor| factor != .volatility_20d,
            .custom => true,
        };
    }
};

pub const ExecutionMode = enum {
    close,
    next_open,
};

pub const PoolMode = enum {
    static,
    dynamic,
};

pub const Request = struct {
    factors: std.ArrayList(FactorSpec),
    start_date: []const u8,
    end_date: []const u8,
    rebalance_period: usize,
    top_pct: f64,
    bottom_pct: f64,
    pool_size: usize,
    industry: ?[]const u8,
    commission_rate: f64,
    stamp_tax_rate: f64,
    slippage_rate: f64,
    min_amount: f64,
    min_listed_days: usize,
    limit_pct: f64,
    execution_mode: ExecutionMode,
    pool_mode: PoolMode,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.start_date);
        allocator.free(self.end_date);
        if (self.industry) |industry| allocator.free(industry);
        for (self.factors.items) |*factor| factor.deinit(allocator);
        self.factors.deinit(allocator);
    }
};

pub fn parseRequest(allocator: std.mem.Allocator, body: []const u8) !Request {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    if (parsed != .object) return error.BadRequest;
    const obj = parsed.object;

    var factors = std.ArrayList(FactorSpec){ .items = &.{}, .capacity = 0 };
    errdefer {
        for (factors.items) |*factor| factor.deinit(allocator);
        factors.deinit(allocator);
    }
    const factor_val = obj.get("factors") orelse return error.BadRequest;
    if (factor_val != .array) return error.BadRequest;
    for (factor_val.array.items) |item| {
        if (item != .string) return error.BadRequest;
        if (parseFactor(item.string)) |factor| {
            try factors.append(allocator, FactorSpec{ .builtin = factor });
        } else if (std.mem.startsWith(u8, item.string, "custom:")) {
            const custom = try parseCustomFactorForKey(allocator, obj, item.string);
            try factors.append(allocator, FactorSpec{ .custom = custom });
        } else {
            return error.UnknownFactor;
        }
    }
    if (factors.items.len == 0 or factors.items.len > MAX_FACTORS) return error.BadRequest;

    const start = getString(obj, "start_date") orelse return error.BadRequest;
    const end = getString(obj, "end_date") orelse return error.BadRequest;
    if (!isDate(start) or !isDate(end)) return error.BadRequest;

    const industry_raw = getString(obj, "industry");
    const industry = if (industry_raw) |v| try allocator.dupe(u8, v) else null;

    return Request{
        .factors = factors,
        .start_date = try allocator.dupe(u8, start),
        .end_date = try allocator.dupe(u8, end),
        .rebalance_period = @max(1, @as(usize, @intFromFloat(getNumber(obj, "rebalance_period", 20)))),
        .top_pct = getNumber(obj, "top_pct", 0.2),
        .bottom_pct = getNumber(obj, "bottom_pct", 0.0),
        .pool_size = @max(1, @as(usize, @intFromFloat(getNumber(obj, "pool_size", 100)))),
        .industry = industry,
        .commission_rate = getNumber(obj, "commission_rate", 0.0003),
        .stamp_tax_rate = getNumber(obj, "stamp_tax_rate", 0.0005),
        .slippage_rate = getNumber(obj, "slippage_rate", 0.0002),
        .min_amount = getNumber(obj, "min_amount", 10_000_000),
        .min_listed_days = @max(1, @as(usize, @intFromFloat(getNumber(obj, "min_listed_days", 60)))),
        .limit_pct = getNumber(obj, "limit_pct", 9.8),
        .execution_mode = parseExecutionMode(getString(obj, "execution_price") orelse "next_open"),
        .pool_mode = parsePoolMode(getString(obj, "pool_mode") orelse "dynamic"),
    };
}

fn parseCustomFactorForKey(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !factor_specs.CustomFactor {
    const val = obj.get("custom_factors") orelse return error.UnknownFactor;
    if (val != .array) return error.BadRequest;
    for (val.array.items) |item| {
        var custom = factor_specs.parseCustomFactorValue(allocator, item) catch |err| switch (err) {
            error.BadCustomFactor, error.DuplicateComponent => return error.BadRequest,
            else => return err,
        };
        if (std.mem.eql(u8, custom.key, key)) return custom;
        custom.deinit(allocator);
    }
    return error.UnknownFactor;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getNumber(obj: std.json.ObjectMap, key: []const u8, default: f64) f64 {
    const val = obj.get(key) orelse return default;
    return switch (val) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        .string => |s| std.fmt.parseFloat(f64, s) catch default,
        else => default,
    };
}

pub fn isDate(value: []const u8) bool {
    if (value.len != 10) return false;
    return std.ascii.isDigit(value[0]) and std.ascii.isDigit(value[1]) and
        std.ascii.isDigit(value[2]) and std.ascii.isDigit(value[3]) and
        value[4] == '-' and std.ascii.isDigit(value[5]) and
        std.ascii.isDigit(value[6]) and value[7] == '-' and
        std.ascii.isDigit(value[8]) and std.ascii.isDigit(value[9]);
}

pub fn parseFactor(name: []const u8) ?Factor {
    if (std.mem.eql(u8, name, "momentum_20d")) return .momentum_20d;
    if (std.mem.eql(u8, name, "momentum_60d")) return .momentum_60d;
    if (std.mem.eql(u8, name, "momentum_120d")) return .momentum_120d;
    if (std.mem.eql(u8, name, "pe_percentile")) return .pe_percentile;
    if (std.mem.eql(u8, name, "price_percentile")) return .price_percentile;
    if (std.mem.eql(u8, name, "volatility_20d")) return .volatility_20d;
    if (std.mem.eql(u8, name, "volume_change")) return .volume_change;
    if (std.mem.eql(u8, name, "rsi_14")) return .rsi_14;
    if (std.mem.eql(u8, name, "ma_deviation_20")) return .ma_deviation_20;
    return null;
}

fn parseExecutionMode(name: []const u8) ExecutionMode {
    if (std.mem.eql(u8, name, "close")) return .close;
    return .next_open;
}

pub fn executionModeName(mode: ExecutionMode) []const u8 {
    return switch (mode) {
        .close => "close",
        .next_open => "next_open",
    };
}

fn parsePoolMode(name: []const u8) PoolMode {
    if (std.mem.eql(u8, name, "static")) return .static;
    return .dynamic;
}

pub fn poolModeName(mode: PoolMode) []const u8 {
    return switch (mode) {
        .static => "static",
        .dynamic => "dynamic",
    };
}

pub fn factorName(factor: Factor) []const u8 {
    return switch (factor) {
        .momentum_20d => "momentum_20d",
        .momentum_60d => "momentum_60d",
        .momentum_120d => "momentum_120d",
        .pe_percentile => "pe_percentile",
        .price_percentile => "price_percentile",
        .volatility_20d => "volatility_20d",
        .volume_change => "volume_change",
        .rsi_14 => "rsi_14",
        .ma_deviation_20 => "ma_deviation_20",
    };
}

pub fn higherIsBetter(factor: Factor) bool {
    return factor != .volatility_20d;
}

pub fn factorLookback(factor: Factor) usize {
    return switch (factor) {
        .momentum_20d => 22,
        .momentum_60d => 62,
        .momentum_120d => 122,
        .pe_percentile => 60,
        .price_percentile => 60,
        .volatility_20d => 21,
        .volume_change => 21,
        .rsi_14 => 15,
        .ma_deviation_20 => 21,
    };
}

pub fn maxLookback(factors: []const FactorSpec) usize {
    var out: usize = 30;
    for (factors) |factor| out = @max(out, factor.lookback());
    return out;
}

pub fn hasFactor(factors: []const FactorSpec, target: Factor) bool {
    for (factors) |factor| {
        switch (factor) {
            .builtin => |builtin| if (builtin == target) return true,
            .custom => {},
        }
    }
    return false;
}

pub fn factorSpecKey(factor: FactorSpec) []const u8 {
    return factor.key();
}

pub fn factorSpecLabel(factor: FactorSpec) []const u8 {
    return factor.label();
}

pub fn factorSpecHigherIsBetter(factor: FactorSpec) bool {
    return factor.higherIsBetter();
}

test "parse request accepts custom factor specs" {
    const allocator = std.testing.allocator;
    const body =
        \\{"factors":["custom:7a1812bdc13ca752"],"custom_factors":[{"schema_version":1,"engine_version":"custom-factor-v1","name":"稳健动量","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"momentum","field":"close","window":60,"direction":"higher","weight":0.55},{"kind":"volatility","field":"close","window":20,"direction":"lower","weight":0.45}]}],"start_date":"2024-01-01","end_date":"2026-05-01"}
    ;
    var req = try parseRequest(allocator, body);
    defer req.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), req.factors.items.len);
    try std.testing.expect(req.factors.items[0].isCustom());
    try std.testing.expectEqualStrings("custom:7a1812bdc13ca752", req.factors.items[0].key());
}

test "parse request rejects custom factor key mismatch" {
    const allocator = std.testing.allocator;
    const body =
        \\{"factors":["custom:badbadbadbadbad1"],"custom_factors":[{"schema_version":1,"engine_version":"custom-factor-v1","name":"稳健动量","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"momentum","field":"close","window":60,"direction":"higher","weight":0.55},{"kind":"volatility","field":"close","window":20,"direction":"lower","weight":0.45}]}],"start_date":"2024-01-01","end_date":"2026-05-01"}
    ;
    try std.testing.expectError(error.UnknownFactor, parseRequest(allocator, body));
}
