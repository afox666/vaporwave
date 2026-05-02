const std = @import("std");

pub const PriceRow = struct {
    date: []const u8,
    open: f64,
    close: f64,
    high: f64,
    low: f64,
    volume: f64,
    amount: f64,
    change_pct: f64,
};

pub const PePoint = struct {
    date: []const u8,
    value: f64,
};

pub const StockData = struct {
    symbol: []const u8,
    prices: std.ArrayList(PriceRow),
    pe_points: std.ArrayList(PePoint),

    pub fn init(allocator: std.mem.Allocator, symbol: []const u8) !StockData {
        return StockData{
            .symbol = try allocator.dupe(u8, symbol),
            .prices = std.ArrayList(PriceRow){ .items = &.{}, .capacity = 0 },
            .pe_points = std.ArrayList(PePoint){ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *StockData, allocator: std.mem.Allocator) void {
        allocator.free(self.symbol);
        for (self.prices.items) |row| allocator.free(row.date);
        self.prices.deinit(allocator);
        for (self.pe_points.items) |point| allocator.free(point.date);
        self.pe_points.deinit(allocator);
    }
};
