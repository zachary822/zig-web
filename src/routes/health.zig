//! Health check for monitoring.

const httpz = @import("httpz");
const App = @import("../App.zig");

/// 200 when the server works, and the database too if one is configured;
/// 500 otherwise.
pub fn healthz(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.header("Cache-Control", "no-store");
    const pool = app.db orelse return res.json(.{ .status = "ok", .db = "not configured" }, .{});
    const ok = blk: {
        const conn = pool.acquire() catch break :blk false;
        defer conn.release();
        const row = conn.one(struct { one: i64 }, res.arena,
            \\SELECT 1
        , .{}) catch break :blk false;
        break :blk row != null and row.?.one == 1;
    };
    if (!ok) res.status = 500;
    try res.json(.{ .status = if (ok) "ok" else "error", .db = if (ok) "ok" else "unavailable" }, .{});
}
