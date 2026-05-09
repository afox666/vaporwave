const std = @import("std");
const specs = @import("backtest_factor_specs.zig");
const types = @import("backtest_types.zig");
const factor_math = @import("backtest_factors.zig");

const Component = specs.Component;
const PriceRow = types.PriceRow;
const PePoint = types.PePoint;
const StockData = types.StockData;

pub fn computeComponent(stock: *StockData, hist_idx: usize, date: []const u8, component: Component) ?f64 {
    const rows = stock.prices.items;
    return switch (component.kind) {
        .momentum => momentum(rows, hist_idx, component.window orelse return null),
        .volatility => volatility(rows, hist_idx, component.window orelse return null),
        .ma_deviation => maDeviation(rows, hist_idx, component.window orelse return null),
        .volume_ratio => volumeRatio(rows, hist_idx, component.short_window orelse return null, component.long_window orelse return null),
        .rsi => rsi(rows, hist_idx, component.window orelse return null),
        .price_percentile => pricePercentile(rows, hist_idx, component.window orelse return null),
        .pe_percentile => pePercentile(stock.pe_points.items, date),
    };
}

fn momentum(rows: []const PriceRow, hist_idx: usize, days: usize) ?f64 {
    if (hist_idx < days) return null;
    const base = rows[hist_idx - days].close;
    if (base == 0) return null;
    return (rows[hist_idx].close - base) / base;
}

fn volatility(rows: []const PriceRow, hist_idx: usize, days: usize) ?f64 {
    if (days < 2 or hist_idx < days) return null;
    var vals_buf: [252]f64 = undefined;
    if (days > vals_buf.len) return null;
    var i: usize = 0;
    while (i < days) : (i += 1) {
        const idx = hist_idx - days + 1 + i;
        const prev = rows[idx - 1].close;
        if (prev == 0) return null;
        vals_buf[i] = (rows[idx].close - prev) / prev;
    }
    const sd = factor_math.sampleStd(vals_buf[0..days]) orelse return null;
    return sd * std.math.sqrt(252.0);
}

fn maDeviation(rows: []const PriceRow, hist_idx: usize, days: usize) ?f64 {
    if (hist_idx + 1 < days) return null;
    var sum: f64 = 0;
    for (rows[hist_idx + 1 - days .. hist_idx + 1]) |row| sum += row.close;
    const ma = sum / @as(f64, @floatFromInt(days));
    if (ma == 0) return null;
    return (rows[hist_idx].close - ma) / ma;
}

fn volumeRatio(rows: []const PriceRow, hist_idx: usize, short_days: usize, long_days: usize) ?f64 {
    if (short_days == 0 or long_days == 0 or short_days >= long_days) return null;
    if (hist_idx + 1 < long_days) return null;
    const short_avg = meanVolume(rows[hist_idx + 1 - short_days .. hist_idx + 1]);
    const long_avg = meanVolume(rows[hist_idx + 1 - long_days .. hist_idx + 1]);
    if (long_avg == 0) return null;
    return short_avg / long_avg - 1.0;
}

fn meanVolume(rows: []const PriceRow) f64 {
    var sum: f64 = 0;
    for (rows) |row| sum += row.volume;
    return sum / @as(f64, @floatFromInt(rows.len));
}

fn rsi(rows: []const PriceRow, hist_idx: usize, days: usize) ?f64 {
    if (days == 0 or hist_idx < days) return null;
    var gain: f64 = 0;
    var loss: f64 = 0;
    var i = hist_idx + 1 - days;
    while (i <= hist_idx) : (i += 1) {
        const delta = rows[i].close - rows[i - 1].close;
        if (delta > 0) gain += delta else loss += -delta;
    }
    gain /= @as(f64, @floatFromInt(days));
    loss /= @as(f64, @floatFromInt(days));
    if (loss == 0) return 100.0;
    const rs = gain / loss;
    return 100.0 - (100.0 / (1.0 + rs));
}

fn pricePercentile(rows: []const PriceRow, hist_idx: usize, days: usize) ?f64 {
    if (days == 0 or hist_idx + 1 < days) return null;
    const window = rows[hist_idx + 1 - days .. hist_idx + 1];
    const current = rows[hist_idx].close;
    if (!std.math.isFinite(current)) return null;
    var less: usize = 0;
    for (window) |row| {
        if (row.close < current) less += 1;
    }
    return @as(f64, @floatFromInt(less)) / @as(f64, @floatFromInt(window.len)) * 100.0;
}

fn pePercentile(points: []const PePoint, date: []const u8) ?f64 {
    var values: [2048]f64 = undefined;
    var n: usize = 0;
    var current: ?f64 = null;
    for (points) |point| {
        if (std.mem.order(u8, point.date, date) == .gt) continue;
        if (point.value <= 0) continue;
        if (n < values.len) {
            values[n] = point.value;
            n += 1;
            current = point.value;
        }
    }
    if (n < 20) return null;
    const cur = current orelse return null;
    var less: usize = 0;
    for (values[0..n]) |v| {
        if (v < cur) less += 1;
    }
    return @as(f64, @floatFromInt(less)) / @as(f64, @floatFromInt(n)) * 100.0;
}
