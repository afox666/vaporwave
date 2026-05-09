const std = @import("std");

pub const SCHEMA_VERSION = 1;
pub const ENGINE_VERSION = "custom-factor-v1";
pub const MAX_COMPONENTS = 5;

pub const ComponentKind = enum {
    momentum,
    volatility,
    ma_deviation,
    volume_ratio,
    rsi,
    price_percentile,
    pe_percentile,
};

pub const Field = enum {
    close,
    volume,
    amount,
};

pub const Direction = enum {
    higher,
    lower,
};

pub const Component = struct {
    kind: ComponentKind,
    field: ?Field,
    window: ?usize,
    short_window: ?usize,
    long_window: ?usize,
    direction: Direction,
    weight: f64,
    weight_ppm: u32 = 0,

    pub fn lookback(self: Component) usize {
        return switch (self.kind) {
            .momentum => (self.window orelse 0) + 2,
            .volatility => (self.window orelse 0) + 1,
            .ma_deviation => (self.window orelse 0) + 1,
            .volume_ratio => (self.long_window orelse 0) + 1,
            .rsi => (self.window orelse 0) + 1,
            .price_percentile => (self.window orelse 0),
            .pe_percentile => 60,
        };
    }
};

pub const CustomFactor = struct {
    key: []const u8,
    name: []const u8,
    description: []const u8,
    combine: []const u8,
    normalize: []const u8,
    canonical: []const u8,
    components: []Component,
    lookback: usize,
    schema_version: i64,
    engine_version: []const u8,

    pub fn deinit(self: *CustomFactor, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.combine);
        allocator.free(self.normalize);
        allocator.free(self.canonical);
        allocator.free(self.components);
        allocator.free(self.engine_version);
    }
};

pub fn parseJsonValue(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{});
}

pub fn parseCustomFactorValue(allocator: std.mem.Allocator, value: std.json.Value) !CustomFactor {
    if (value != .object) return error.BadCustomFactor;
    const obj = value.object;

    const schema_version = getInteger(obj, "schema_version") orelse return error.BadCustomFactor;
    if (schema_version != SCHEMA_VERSION) return error.BadCustomFactor;
    const engine_version_raw = getString(obj, "engine_version") orelse ENGINE_VERSION;
    if (!std.mem.eql(u8, engine_version_raw, ENGINE_VERSION)) return error.BadCustomFactor;
    const combine_raw = getString(obj, "combine") orelse "weighted_sum";
    if (!std.mem.eql(u8, combine_raw, "weighted_sum")) return error.BadCustomFactor;
    const normalize_raw = getString(obj, "normalize") orelse "cross_section_rank";
    if (!std.mem.eql(u8, normalize_raw, "cross_section_rank")) return error.BadCustomFactor;

    const name = try allocator.dupe(u8, getString(obj, "name") orelse "自定义因子");
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, getString(obj, "description") orelse "");
    errdefer allocator.free(description);
    const combine = try allocator.dupe(u8, combine_raw);
    errdefer allocator.free(combine);
    const normalize = try allocator.dupe(u8, normalize_raw);
    errdefer allocator.free(normalize);
    const engine_version = try allocator.dupe(u8, engine_version_raw);
    errdefer allocator.free(engine_version);

    const component_val = obj.get("components") orelse return error.BadCustomFactor;
    if (component_val != .array) return error.BadCustomFactor;
    if (component_val.array.items.len == 0 or component_val.array.items.len > MAX_COMPONENTS) return error.BadCustomFactor;

    var components = std.ArrayList(Component){ .items = &.{}, .capacity = 0 };
    errdefer components.deinit(allocator);
    for (component_val.array.items) |item| {
        try components.append(allocator, try parseComponent(item));
    }
    std.mem.sort(Component, components.items, {}, lessComponent);
    var i: usize = 1;
    while (i < components.items.len) : (i += 1) {
        if (sameComponentTuple(components.items[i - 1], components.items[i])) return error.DuplicateComponent;
    }
    normalizeWeights(components.items) catch return error.BadCustomFactor;

    var lookback: usize = 30;
    for (components.items) |component| lookback = @max(lookback, component.lookback());

    const canonical = try canonicalJson(allocator, schema_version, engine_version_raw, combine_raw, normalize_raw, components.items);
    errdefer allocator.free(canonical);
    const key = try customKey(allocator, canonical);
    errdefer allocator.free(key);
    const owned_components = try components.toOwnedSlice(allocator);

    return CustomFactor{
        .key = key,
        .name = name,
        .description = description,
        .combine = combine,
        .normalize = normalize,
        .canonical = canonical,
        .components = owned_components,
        .lookback = lookback,
        .schema_version = schema_version,
        .engine_version = engine_version,
    };
}

pub fn templatesJson(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8,
        \\[
        \\{"name":"稳健动量","description":"60日趋势动量 + 20日波动率惩罚","category":"custom","definition":{"schema_version":1,"engine_version":"custom-factor-v1","name":"稳健动量","description":"60日趋势动量 + 20日波动率惩罚","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"momentum","field":"close","window":60,"direction":"higher","weight":0.55},{"kind":"volatility","field":"close","window":20,"direction":"lower","weight":0.45}]}},
        \\{"name":"量价确认","description":"20日动量 + 5/20日量能确认","category":"custom","definition":{"schema_version":1,"engine_version":"custom-factor-v1","name":"量价确认","description":"20日动量 + 5/20日量能确认","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"momentum","field":"close","window":20,"direction":"higher","weight":0.60},{"kind":"volume_ratio","field":"volume","short_window":5,"long_window":20,"direction":"higher","weight":0.40}]}},
        \\{"name":"估值修复","description":"低PE历史分位 + 价格低位修复","category":"custom","definition":{"schema_version":1,"engine_version":"custom-factor-v1","name":"估值修复","description":"低PE历史分位 + 价格历史分位","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"pe_percentile","direction":"lower","weight":0.55},{"kind":"price_percentile","field":"close","window":120,"direction":"lower","weight":0.45}]}}
        \\]
    );
}

pub fn validateJson(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try parseJsonValue(allocator, body);
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadCustomFactor;
    const obj = parsed.value.object;
    const mode = getString(obj, "mode") orelse "schema";

    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .whitespace = .minified } };

    const factor_key = firstFactorKey(obj) orelse "";
    var custom: ?CustomFactor = null;
    defer if (custom) |*c| c.deinit(allocator);

    if (factor_key.len > 0) {
        custom = findCustomFactor(allocator, obj, factor_key) catch null;
    }
    if (custom == null) {
        custom = firstCustomFactor(allocator, obj) catch null;
    }

    try s.beginObject();
    try s.objectField("mode");
    try s.write(mode);
    if (custom) |c| {
        try s.objectField("factor_key");
        try s.write(c.key);
        try s.objectField("factor_label");
        try s.write(c.name);
        try s.objectField("summary");
        const summary = try std.fmt.allocPrint(allocator, "{s}：结构校验通过，最大历史需求 {d} 个交易日", .{ c.name, c.lookback });
        defer allocator.free(summary);
        try s.write(summary);
        try s.objectField("schema_valid");
        try s.write(true);
        try s.objectField("lookback");
        try s.write(c.lookback);
        try s.objectField("engine_version");
        try s.write(c.engine_version);
        try s.objectField("estimated_valid_observation_rate");
        try s.write(null);
        try s.objectField("component_missing_counts");
        try s.beginObject();
        try s.endObject();
        try s.objectField("sample_scope");
        try s.beginObject();
        try s.objectField("estimated");
        try s.write(std.mem.eql(u8, mode, "sample"));
        try s.objectField("symbols");
        try s.write(0);
        try s.objectField("rebalance_dates");
        try s.write(0);
        try s.endObject();
        try s.objectField("warnings");
        try s.beginArray();
        if (!std.mem.eql(u8, factor_key, c.key)) try s.write("custom factor id does not match canonical key");
        try s.endArray();
        try s.objectField("errors");
        try s.beginArray();
        try s.endArray();
        try s.objectField("suggestions");
        try s.beginArray();
        try s.endArray();
    } else {
        try s.objectField("factor_key");
        try s.write(factor_key);
        try s.objectField("factor_label");
        try s.write("");
        try s.objectField("summary");
        try s.write("自定义因子定义无效");
        try s.objectField("schema_valid");
        try s.write(false);
        try s.objectField("lookback");
        try s.write(0);
        try s.objectField("engine_version");
        try s.write(ENGINE_VERSION);
        try s.objectField("estimated_valid_observation_rate");
        try s.write(null);
        try s.objectField("component_missing_counts");
        try s.beginObject();
        try s.endObject();
        try s.objectField("sample_scope");
        try s.beginObject();
        try s.objectField("estimated");
        try s.write(false);
        try s.endObject();
        try s.objectField("warnings");
        try s.beginArray();
        try s.endArray();
        try s.objectField("errors");
        try s.beginArray();
        try s.write("custom factor definition missing or invalid");
        try s.endArray();
        try s.objectField("suggestions");
        try s.beginArray();
        try s.write("重新选择一个因子模板");
        try s.endArray();
    }
    try s.endObject();
    return out.toOwnedSlice();
}

fn firstFactorKey(obj: std.json.ObjectMap) ?[]const u8 {
    const factors = obj.get("factors") orelse return null;
    if (factors != .array or factors.array.items.len == 0) return null;
    const first = factors.array.items[0];
    return if (first == .string) first.string else null;
}

fn findCustomFactor(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !CustomFactor {
    const val = obj.get("custom_factors") orelse return error.BadCustomFactor;
    if (val != .array) return error.BadCustomFactor;
    for (val.array.items) |item| {
        var custom = parseCustomFactorValue(allocator, item) catch continue;
        if (std.mem.eql(u8, custom.key, key)) return custom;
        custom.deinit(allocator);
    }
    return error.BadCustomFactor;
}

fn firstCustomFactor(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !CustomFactor {
    const val = obj.get("custom_factors") orelse return error.BadCustomFactor;
    if (val != .array or val.array.items.len == 0) return error.BadCustomFactor;
    return parseCustomFactorValue(allocator, val.array.items[0]);
}

fn parseComponent(value: std.json.Value) !Component {
    if (value != .object) return error.BadCustomFactor;
    const obj = value.object;
    const kind = parseComponentKind(getString(obj, "kind") orelse return error.BadCustomFactor) orelse return error.BadCustomFactor;
    const direction = parseDirection(getString(obj, "direction") orelse "higher") orelse return error.BadCustomFactor;
    const weight = getNumber(obj, "weight") orelse return error.BadCustomFactor;
    if (!std.math.isFinite(weight) or weight <= 0) return error.BadCustomFactor;

    var component = Component{
        .kind = kind,
        .field = null,
        .window = null,
        .short_window = null,
        .long_window = null,
        .direction = direction,
        .weight = weight,
    };

    switch (kind) {
        .momentum => {
            component.field = parseField(getString(obj, "field") orelse "close") orelse return error.BadCustomFactor;
            component.window = parseWindow(obj, "window");
            if (component.window == null) return error.BadCustomFactor;
        },
        .volatility, .ma_deviation, .rsi, .price_percentile => {
            const field = parseField(getString(obj, "field") orelse "close") orelse return error.BadCustomFactor;
            if (field != .close) return error.BadCustomFactor;
            component.field = field;
            component.window = parseWindow(obj, "window");
            if (component.window == null) return error.BadCustomFactor;
        },
        .volume_ratio => {
            const field = parseField(getString(obj, "field") orelse "volume") orelse return error.BadCustomFactor;
            if (field != .volume) return error.BadCustomFactor;
            component.field = field;
            component.short_window = parseWindow(obj, "short_window");
            component.long_window = parseWindow(obj, "long_window");
            const short = component.short_window orelse return error.BadCustomFactor;
            const long = component.long_window orelse return error.BadCustomFactor;
            if (short >= long) return error.BadCustomFactor;
        },
        .pe_percentile => {
            if (obj.get("window") != null) return error.BadCustomFactor;
            component.field = null;
        },
    }
    return component;
}

fn parseWindow(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const n = getInteger(obj, key) orelse return null;
    if (n < 5 or n > 252) return null;
    return @intCast(n);
}

fn normalizeWeights(components: []Component) !void {
    var sum: f64 = 0;
    for (components) |component| sum += component.weight;
    if (!std.math.isFinite(sum) or sum <= 0) return error.BadCustomFactor;

    var assigned: i64 = 0;
    for (components, 0..) |*component, i| {
        if (i + 1 == components.len) {
            const residual = 1_000_000 - assigned;
            if (residual <= 0) return error.BadCustomFactor;
            component.weight_ppm = @intCast(residual);
            component.weight = @as(f64, @floatFromInt(residual)) / 1_000_000.0;
            break;
        }
        const ppm = @as(i64, @intFromFloat(@round(component.weight / sum * 1_000_000.0)));
        if (ppm <= 0) return error.BadCustomFactor;
        component.weight_ppm = @intCast(ppm);
        component.weight = @as(f64, @floatFromInt(ppm)) / 1_000_000.0;
        assigned += ppm;
    }
}

fn canonicalJson(
    allocator: std.mem.Allocator,
    schema_version: i64,
    engine_version: []const u8,
    combine: []const u8,
    normalize: []const u8,
    components: []const Component,
) ![]const u8 {
    var out = std.io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{{\"schema_version\":{d},\"engine_version\":\"{s}\",\"combine\":\"{s}\",\"normalize\":\"{s}\",\"components\":[", .{
        schema_version,
        engine_version,
        combine,
        normalize,
    });
    for (components, 0..) |component, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"kind\":\"{s}\",\"field\":", .{componentKindName(component.kind)});
        if (component.field) |field| try w.print("\"{s}\"", .{fieldName(field)}) else try w.writeAll("null");
        try w.writeAll(",\"window\":");
        if (component.window) |window| try w.print("{d}", .{window}) else try w.writeAll("null");
        try w.writeAll(",\"short_window\":");
        if (component.short_window) |window| try w.print("{d}", .{window}) else try w.writeAll("null");
        try w.writeAll(",\"long_window\":");
        if (component.long_window) |window| try w.print("{d}", .{window}) else try w.writeAll("null");
        try w.print(",\"direction\":\"{s}\",\"weight_ppm\":{d}}}", .{ directionName(component.direction), component.weight_ppm });
    }
    try w.writeAll("]}");
    return out.toOwnedSlice();
}

fn customKey(allocator: std.mem.Allocator, canonical: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "custom:{s}", .{hex[0..16]});
}

fn lessComponent(_: void, a: Component, b: Component) bool {
    const kind_order = std.mem.order(u8, componentKindName(a.kind), componentKindName(b.kind));
    if (kind_order != .eq) return kind_order == .lt;
    const field_order = std.mem.order(u8, optionalFieldName(a.field), optionalFieldName(b.field));
    if (field_order != .eq) return field_order == .lt;
    if ((a.window orelse 0) != (b.window orelse 0)) return (a.window orelse 0) < (b.window orelse 0);
    if ((a.short_window orelse 0) != (b.short_window orelse 0)) return (a.short_window orelse 0) < (b.short_window orelse 0);
    if ((a.long_window orelse 0) != (b.long_window orelse 0)) return (a.long_window orelse 0) < (b.long_window orelse 0);
    return std.mem.order(u8, directionName(a.direction), directionName(b.direction)) == .lt;
}

fn sameComponentTuple(a: Component, b: Component) bool {
    return a.kind == b.kind and
        a.field == b.field and
        (a.window orelse 0) == (b.window orelse 0) and
        (a.short_window orelse 0) == (b.short_window orelse 0) and
        (a.long_window orelse 0) == (b.long_window orelse 0) and
        a.direction == b.direction;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn getNumber(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn parseComponentKind(name: []const u8) ?ComponentKind {
    if (std.mem.eql(u8, name, "momentum")) return .momentum;
    if (std.mem.eql(u8, name, "volatility")) return .volatility;
    if (std.mem.eql(u8, name, "ma_deviation")) return .ma_deviation;
    if (std.mem.eql(u8, name, "volume_ratio")) return .volume_ratio;
    if (std.mem.eql(u8, name, "rsi")) return .rsi;
    if (std.mem.eql(u8, name, "price_percentile")) return .price_percentile;
    if (std.mem.eql(u8, name, "pe_percentile")) return .pe_percentile;
    return null;
}

pub fn parseField(name: []const u8) ?Field {
    if (std.mem.eql(u8, name, "close")) return .close;
    if (std.mem.eql(u8, name, "volume")) return .volume;
    if (std.mem.eql(u8, name, "amount")) return .amount;
    return null;
}

pub fn parseDirection(name: []const u8) ?Direction {
    if (std.mem.eql(u8, name, "higher")) return .higher;
    if (std.mem.eql(u8, name, "lower")) return .lower;
    return null;
}

pub fn componentKindName(kind: ComponentKind) []const u8 {
    return switch (kind) {
        .momentum => "momentum",
        .volatility => "volatility",
        .ma_deviation => "ma_deviation",
        .volume_ratio => "volume_ratio",
        .rsi => "rsi",
        .price_percentile => "price_percentile",
        .pe_percentile => "pe_percentile",
    };
}

pub fn fieldName(field: Field) []const u8 {
    return switch (field) {
        .close => "close",
        .volume => "volume",
        .amount => "amount",
    };
}

fn optionalFieldName(field: ?Field) []const u8 {
    return if (field) |f| fieldName(f) else "";
}

pub fn directionName(direction: Direction) []const u8 {
    return switch (direction) {
        .higher => "higher",
        .lower => "lower",
    };
}

test "custom factor canonical key ignores display fields and component order" {
    const allocator = std.testing.allocator;
    const body_a =
        \\{"schema_version":1,"engine_version":"custom-factor-v1","name":"稳健动量","description":"A","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"volatility","field":"close","window":20,"direction":"lower","weight":0.45},{"kind":"momentum","field":"close","window":60,"direction":"higher","weight":0.55}]}
    ;
    const body_b =
        \\{"description":"B","name":"改名不改key","engine_version":"custom-factor-v1","schema_version":1,"normalize":"cross_section_rank","combine":"weighted_sum","components":[{"weight":55,"direction":"higher","window":60,"field":"close","kind":"momentum"},{"weight":45,"direction":"lower","window":20,"field":"close","kind":"volatility"}]}
    ;

    var parsed_a = try parseJsonValue(allocator, body_a);
    defer parsed_a.deinit();
    var parsed_b = try parseJsonValue(allocator, body_b);
    defer parsed_b.deinit();

    var a = try parseCustomFactorValue(allocator, parsed_a.value);
    defer a.deinit(allocator);
    var b = try parseCustomFactorValue(allocator, parsed_b.value);
    defer b.deinit(allocator);

    try std.testing.expectEqualStrings(a.key, b.key);
    try std.testing.expect(std.mem.startsWith(u8, a.key, "custom:"));
}

test "custom factor rejects duplicate components" {
    const allocator = std.testing.allocator;
    const body =
        \\{"schema_version":1,"engine_version":"custom-factor-v1","name":"重复","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"momentum","field":"close","window":60,"direction":"higher","weight":0.5},{"kind":"momentum","field":"close","window":60,"direction":"higher","weight":0.5}]}
    ;
    var parsed = try parseJsonValue(allocator, body);
    defer parsed.deinit();
    try std.testing.expectError(error.DuplicateComponent, parseCustomFactorValue(allocator, parsed.value));
}

test "custom factor rejects pe percentile window" {
    const allocator = std.testing.allocator;
    const body =
        \\{"schema_version":1,"engine_version":"custom-factor-v1","name":"PE","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"pe_percentile","window":60,"direction":"lower","weight":1}]}
    ;
    var parsed = try parseJsonValue(allocator, body);
    defer parsed.deinit();
    try std.testing.expectError(error.BadCustomFactor, parseCustomFactorValue(allocator, parsed.value));
}

test "schema validation returns key summary and lookback" {
    const allocator = std.testing.allocator;
    const body =
        \\{"mode":"schema","factors":["custom:7a1812bdc13ca752"],"custom_factors":[{"schema_version":1,"engine_version":"custom-factor-v1","name":"稳健动量","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"momentum","field":"close","window":60,"direction":"higher","weight":0.55},{"kind":"volatility","field":"close","window":20,"direction":"lower","weight":0.45}]}]}
    ;
    const out = try validateJson(allocator, body);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"factor_key\":\"custom:7a1812bdc13ca752\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"summary\":\"稳健动量") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"lookback\":62") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"errors\":[]") != null);
}

test "schema validation accepts draft before canonical key is known" {
    const allocator = std.testing.allocator;
    const body =
        \\{"mode":"schema","factors":["custom:pending"],"custom_factors":[{"schema_version":1,"engine_version":"custom-factor-v1","name":"稳健动量","combine":"weighted_sum","normalize":"cross_section_rank","components":[{"kind":"momentum","field":"close","window":60,"direction":"higher","weight":0.55},{"kind":"volatility","field":"close","window":20,"direction":"lower","weight":0.45}]}]}
    ;
    const out = try validateJson(allocator, body);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"factor_key\":\"custom:7a1812bdc13ca752\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "custom factor id does not match canonical key") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"errors\":[]") != null);
}
