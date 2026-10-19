//! Middleware that translates responses for htmx requests (`HX-Request`), so
//! that actions answer htmx and other requests the same way.
//!
//! A redirect (`App.redirect`) becomes a `200` with `HX-Location`. `fetch`
//! follows a redirect without htmx, so htmx would swap the next page into
//! the target of the request (the preview, for example) and keep the old
//! URL. With `HX-Location`, htmx loads the page into the body and pushes its
//! URL, as for a boosted link.

const std = @import("std");
const httpz = @import("httpz");

const Htmx = @This();

pub const Config = struct {};

pub fn init(_: Config) !Htmx {
    return .{};
}

pub fn execute(_: *const Htmx, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    try executor.next();
    if (req.header("hx-request") == null) return;
    if (res.status < 300 or res.status >= 400) return;
    const location = removeHeader(res, "Location") orelse return;
    res.status = 200;
    res.header("HX-Location", location);
}

/// Removes the first header `name` (case-sensitive, as httpz compares
/// them) and returns its value, or null when there is none.
fn removeHeader(res: *httpz.Response, name: []const u8) ?[]const u8 {
    const headers = &res.headers;
    const i = for (headers.keys[0..headers.len], 0..) |key, i| {
        if (std.mem.eql(u8, key, name)) break i;
    } else return null;
    const value = headers.values[i];
    const last = headers.len - 1;
    std.mem.copyForwards([]const u8, headers.keys[i..last], headers.keys[i + 1 .. headers.len]);
    std.mem.copyForwards([]const u8, headers.values[i..last], headers.values[i + 1 .. headers.len]);
    std.mem.copyForwards(u8, headers.hashes[i..last], headers.hashes[i + 1 .. headers.len]);
    headers.len = last;
    return value;
}

test Htmx {
    const mw = try Htmx.init(.{});
    const Redirect = struct {
        res: *httpz.Response,
        pub fn next(self: *@This()) !void {
            self.res.status = 303;
            self.res.header("Cache-Control", "no-store");
            self.res.header("Location", "/uploads");
        }
    };

    // Without htmx: the redirect stays.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        var next: Redirect = .{ .res = ht.res };
        try mw.execute(ht.req, ht.res, &next);
        try ht.expectStatus(303);
        try ht.expectHeader("Location", "/uploads");
        try ht.expectHeader("HX-Location", null);
    }

    // With htmx: `HX-Location`, and the other headers stay.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.header("hx-request", "true");
        var next: Redirect = .{ .res = ht.res };
        try mw.execute(ht.req, ht.res, &next);
        try ht.expectStatus(200);
        try ht.expectHeader("Location", null);
        try ht.expectHeader("HX-Location", "/uploads");
        try ht.expectHeader("Cache-Control", "no-store");
    }
}
