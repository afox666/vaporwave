pub const ProgressCallback = *const fn (ctx: *anyopaque, stage: []const u8, progress: f64, message: []const u8) void;
pub const CancelCallback = *const fn (ctx: *anyopaque) bool;

pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    progress: ?ProgressCallback = null,
    cancelled: ?CancelCallback = null,
};

pub fn emitProgress(hooks: Hooks, stage: []const u8, progress: f64, message: []const u8) void {
    if (hooks.progress) |callback| {
        if (hooks.ctx) |ctx| {
            callback(ctx, stage, @max(0.0, @min(1.0, progress)), message);
        }
    }
}

pub fn checkCancelled(hooks: Hooks) !void {
    if (hooks.cancelled) |callback| {
        if (hooks.ctx) |ctx| {
            if (callback(ctx)) return error.Cancelled;
        }
    }
}
