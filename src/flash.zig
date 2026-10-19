//! Flash messages: one-time messages for the next page, usually after a
//! redirect ("Saved."). They are kept in the session data (see
//! `middleware/session.zig`), so they also work for visitors who are not logged in.
//!
//!     try flash.add(req, .success, "Saved.");
//!     app.redirect(res, "/uploads");
//!
//! `App.render` takes the messages for each page as `messages`, and
//! `base.mustache` shows them. A response that does not render a page (a
//! redirect, JSON, an error) keeps them for the next page.

const std = @import("std");
const httpz = @import("httpz");
const Session = @import("middleware/session.zig");

pub const Level = enum { success, info, warning, @"error" };

pub const Message = struct {
    level: Level,
    text: []const u8,
};

/// More messages than this before a page shows them: the oldest go.
const max_messages = 10;

const key = Session.Key([]const Message, "flash");

/// Adds a message for the next page. The route must use
/// `Session.Middleware`.
pub fn add(req: *httpz.Request, level: Level, text: []const u8) !void {
    const data = Session.data(req) orelse return error.NoSession;
    const old = try data.get(key) orelse &.{};
    const kept = old[old.len -| (max_messages - 1)..];
    const messages = try req.arena.alloc(Message, kept.len + 1);
    @memcpy(messages[0..kept.len], kept);
    messages[kept.len] = .{ .level = level, .text = text };
    try data.put(key, messages);
}

/// A message for a template, with one flag for each level, because Mustache
/// has no comparisons.
pub const View = struct {
    text: []const u8,
    is_success: bool,
    is_info: bool,
    is_warning: bool,
    is_error: bool,
};

/// Returns the messages and removes them, for the page that shows them.
/// Empty when the route does not use `Session.Middleware`.
pub fn take(req: *httpz.Request) ![]const View {
    const data = Session.data(req) orelse return &.{};
    const messages = try data.take(key) orelse return &.{};
    const views = try req.arena.alloc(View, messages.len);
    for (messages, views) |m, *v| v.* = .{
        .text = m.text,
        .is_success = m.level == .success,
        .is_info = m.level == .info,
        .is_warning = m.level == .warning,
        .is_error = m.level == .@"error",
    };
    return views;
}

test "add and take" {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    // Without `Session.Middleware` there are no messages and no place for them.
    try std.testing.expectEqual(0, (try take(ht.req)).len);
    try std.testing.expectError(error.NoSession, add(ht.req, .info, "x"));

    _ = try Session.attachForTest(ht.req, null);
    try add(ht.req, .success, "Saved.");
    try add(ht.req, .@"error", "Not saved.");
    const views = try take(ht.req);
    try std.testing.expectEqual(2, views.len);
    try std.testing.expectEqualStrings("Saved.", views[0].text);
    try std.testing.expect(views[0].is_success and !views[0].is_error);
    try std.testing.expect(views[1].is_error);
    try std.testing.expectEqual(0, (try take(ht.req)).len);

    for (0..max_messages + 3) |_| try add(ht.req, .info, "x");
    try std.testing.expectEqual(max_messages, (try take(ht.req)).len);
}
