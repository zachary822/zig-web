//! The home page. A starting point: change the page, and add routes next
//! to it in `main.zig`.

const std = @import("std");
const httpz = @import("httpz");
const App = @import("../App.zig");

/// `GET /`.
pub fn index(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    res.header("Cache-Control", "private, no-cache");
    try app.render(req, res, "index", .{});
}

test "the home page greets the logged-in user" {
    var templates: @import("mustache").Library = .init(std.testing.allocator, std.testing.io);
    defer templates.deinit();
    try App.loadTemplates(std.testing.io, &templates, "templates");

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try templates.render(std.testing.allocator, "index", .{
        .current_user = App.User{ .id = 1, .username = "ann" },
        .csrf_token = "t",
    }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Hello, ann.") != null);
}
