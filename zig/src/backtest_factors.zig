const std = @import("std");
const config = @import("backtest_config.zig");
const types = @import("backtest_types.zig");

const Factor = config.Factor;
const PriceRow = types.PriceRow;
const PePoint = types.PePoint;
const StockData = types.StockData;

pub fn compute(stock: *StockData, hist_idx: usize, date: []const u8, factor: Factor) ?f64 {
    const rows = stock.prices.items;
    return switch (factor) {
        .momentum_20d => momentum(rows, hist_idx, 20),
        .momentum_60d => momentum(rows, hist_idx, 60),
        .momentum_120d => momentum(rows, hist_idx, 120),
        .price_percentile => pricePercentile(rows, hist_idx),
        .volatility_20d => volatility(rows, hist_idx),
        .volume_change => volumeChange(rows, hist_idx),
        .rsi_14 => rsi(rows, hist_idx),
        .ma_deviation_20 => maDeviation(rows, hist_idx),
        .pe_percentile => pePercentile(stock.pe_points.items, date),
    };
}

fn momentum(rows: []const PriceRow, hist_idx: usize, days: usize) ?f64 {
    if (hist_idx < days) return null;
    const base = rows[hist_idx - days].close;
    if (base == 0) return null;
    return (rows[hist_idx].close - base) / base;
}

fn percentile(current: f64, values: []const f64) ?f64 {
    if (values.len == 0 or !std.math.isFinite(current)) return null;
    var less: usize = 0;
    for (values) |v| {
        if (v < current) less += 1;
    }
    return @as(f64, @floatFromInt(less)) / @as(f64, @floatFromInt(values.len)) * 100.0;
}

fn pricePercentile(rows: []const PriceRow, hist_idx: usize) ?f64 {
    if (hist_idx + 1 < 60) return null;
    var values_buf: [4096]f64 = undefined;
    if (hist_idx + 1 > values_buf.len) return percentileDynamic(rows, hist_idx);
    for (rows[0 .. hist_idx + 1], 0..) |row, i| values_buf[i] = row.close;
    return percentile(rows[hist_idx].close, values_buf[0 .. hist_idx + 1]);
}

fn percentileDynamic(rows: []const PriceRow, hist_idx: usize) ?f64 {
    var less: usize = 0;
    const current = rows[hist_idx].close;
    for (rows[0 .. hist_idx + 1]) |row| {
        if (row.close < current) less += 1;
    }
    return @as(f64, @floatFromInt(less)) / @as(f64, @floatFromInt(hist_idx + 1)) * 100.0;
}

fn volatility(rows: []const PriceRow, hist_idx: usize) ?f64 {
    if (hist_idx < 20) return null;
    var vals: [20]f64 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const idx = hist_idx - 19 + i;
        const prev = rows[idx - 1].close;
        if (prev == 0) return null;
        vals[i] = (rows[idx].close - prev) / prev;
    }
    const sd = sampleStd(vals[0..]) orelse return null;
    return sd * std.math.sqrt(252.0);
}

fn volumeChange(rows: []const PriceRow, hist_idx: usize) ?f64 {
    if (hist_idx + 1 < 21) return null;
    const short_avg = meanVolume(rows[hist_idx - 4 .. hist_idx + 1]);
    const long_avg = meanVolume(rows[hist_idx - 19 .. hist_idx + 1]);
    if (long_avg == 0) return null;
    return short_avg / long_avg - 1;
}

fn meanVolume(rows: []const PriceRow) f64 {
    var sum: f64 = 0;
    for (rows) |row| sum += row.volume;
    return sum / @as(f64, @floatFromInt(rows.len));
}

fn rsi(rows: []const PriceRow, hist_idx: usize) ?f64 {
    if (hist_idx < 14) return null;
    var gain: f64 = 0;
    var loss: f64 = 0;
    var i = hist_idx - 13;
    while (i <= hist_idx) : (i += 1) {
        const delta = rows[i].close - rows[i - 1].close;
        if (delta > 0) gain += delta else loss += -delta;
    }
    gain /= 14.0;
    loss /= 14.0;
    if (loss == 0) return 100.0;
    const rs = gain / loss;
    return 100.0 - (100.0 / (1.0 + rs));
}

fn maDeviation(rows: []const PriceRow, hist_idx: usize) ?f64 {
    if (hist_idx + 1 < 21) return null;
    var sum: f64 = 0;
    for (rows[hist_idx - 19 .. hist_idx + 1]) |row| sum += row.close;
    const ma = sum / 20.0;
    if (ma == 0) return null;
    return (rows[hist_idx].close - ma) / ma;
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
    return percentile(current orelse return null, values[0..n]);
}

pub fn lastPeDateOnOrBefore(points: []const PePoint, date: []const u8) ?[]const u8 {
    var out: ?[]const u8 = null;
    for (points) |point| {
        if (std.mem.order(u8, point.date, date) == .gt) continue;
        if (point.value <= 0) continue;
        out = point.date;
    }
    return out;
}

pub fn sampleStd(vals: []const f64) ?f64 {
    if (vals.len < 2) return null;
    var sum: f64 = 0;
    for (vals) |v| sum += v;
    const mean = sum / @as(f64, @floatFromInt(vals.len));
    var ss: f64 = 0;
    for (vals) |v| {
        const d = v - mean;
        ss += d * d;
    }
    return std.math.sqrt(ss / @as(f64, @floatFromInt(vals.len - 1)));
}
