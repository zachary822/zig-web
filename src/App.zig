//! Shared state for all requests. httpz passes a `*App` to each action.

const std = @import("std");
const httpz = @import("httpz");
const mustache = @import("mustache");
const database = @import("db.zig");
const Csrf = @import("middleware/csrf.zig");
const PasswordHasher = @import("password.zig");
const Session = @import("middleware/session.zig");
const flash = @import("flash.zig");
const current_user = @import("middleware/current_user.zig");
const Static = @import("static.zig");
const MediaStorage = @import("media.zig").Storage;

const App = @This();

io: std.Io,
/// Directory with the `*.mustache` templates.
template_dir: []const u8,
/// Templates loaded one time at startup, by file name without `.mustache`.
/// Thread-safe: many requests can render at the same time. `null` when
/// `reload_templates` is set.
templates: ?*mustache.Library,
/// `null` when no database is configured.
db: ?*database.Pool,
/// CSRF tokens. `render` gives each page its token as `csrf_token`.
csrf: *const Csrf,
/// Argon2id password hashing, see `password.zig`.
passwords: *PasswordHasher,
/// Login sessions, see `middleware/session.zig`.
session: *const Session,
/// Static file URLs. `render` gives each page the `static` lambda.
static: *const Static,
/// The uploaded files, see `media.zig`.
media: *const MediaStorage,

/// The logged-in user, as the pages use it (`currentUser`, and
/// `current_user` in the templates). Add fields here and to the query in
/// `load`; `current_user.Middleware` loads it for each request with a login.
pub const User = struct {
    id: u64,
    username: []const u8,

    /// Loads the user with `id`, or null when there is none.
    pub fn load(conn: *database.Conn, arena: std.mem.Allocator, id: u64) !?User {
        return conn.one(User, arena,
            \\SELECT id, username FROM `user` WHERE id = ?
        , .{id});
    }
};

/// Takes a database connection from the pool. Call `release` on it when
/// done. Fails with `error.DbNotConfigured` when there is no database, and
/// with `error.DbUnavailable` when it cannot be reached; the request logger
/// turns errors into 500.
pub fn dbConn(self: *App) database.Error!*database.Conn {
    const pool = self.db orelse return error.DbNotConfigured;
    return pool.acquire();
}

/// Returns the logged-in user of `req`, or null. The routes in the `pages`
/// group of `main.zig` load the user with `current_user.Middleware`; for
/// other routes this is always null.
pub fn currentUser(_: *App, req: *httpz.Request) ?User {
    return current_user.get(User, req);
}

/// Sends a `303 See Other` to `location`, the response to a successful form
/// post. For htmx requests, `Htmx` (middleware/Htmx.zig) makes it an `HX-Location`.
pub fn redirect(_: *App, res: *httpz.Response, location: []const u8) void {
    res.status = 303;
    res.header("Location", location);
}

/// Sends the "not found" page with the status 404.
pub fn notFound(self: *App, req: *httpz.Request, res: *httpz.Response) !void {
    res.status = 404;
    res.header("Cache-Control", "private, no-cache");
    try self.render(req, res, "not_found", .{});
}

/// Renders the template `name` with `data` as the HTML response body. The
/// template also gets the fields that all pages use (`base.mustache`):
/// `current_user` (see `currentUser`), `csrf_token`, `messages` (the flash
/// messages, which this page shows and so removes; see `flash.zig`) and
/// `static` (the lambda for `{{#static}}path{{/static}}`, see `static.zig`).
/// `data` must not have fields with these names.
///
/// Without a startup library (development), the templates are read from disk
/// again for each request, so changes show up without a restart. The library
/// is allocated in the request arena, so it is not shared between threads.
pub fn render(self: *App, req: *httpz.Request, res: *httpz.Response, name: []const u8, data: anytype) !void {
    const page = merge(data, .{
        .current_user = self.currentUser(req),
        .csrf_token = try self.csrf.token(req, res),
        .messages = try flash.take(req),
        .static = self.static.lambda(),
    });
    res.content_type = .HTML;
    if (self.templates) |templates| {
        return templates.render(res.arena, name, page, res.writer());
    }

    var templates: mustache.Library = .init(res.arena, self.io);
    defer templates.deinit();
    try loadTemplates(self.io, &templates, self.template_dir);
    try templates.render(res.arena, name, page, res.writer());
}

/// A struct with the fields of `a` and then the fields of `b`. A name in both
/// is a compile error.
fn Merged(comptime A: type, comptime B: type) type {
    const a = @typeInfo(A).@"struct";
    const b = @typeInfo(B).@"struct";
    const names = a.field_names ++ b.field_names;
    comptime var types: [names.len]type = undefined;
    for (a.field_types ++ b.field_types, &types) |T, *out| out.* = Runtime(T);
    const final = types;
    return @Struct(.auto, null, names, &final, &@splat(.{}));
}

/// A type that a struct field can have at run time, for the types of
/// comptime-known values in anonymous struct literals.
fn Runtime(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .comptime_int => i64,
        .comptime_float => f64,
        .null => ?u8,
        else => T,
    };
}

fn merge(a: anytype, b: anytype) Merged(@TypeOf(a), @TypeOf(b)) {
    var out: Merged(@TypeOf(a), @TypeOf(b)) = undefined;
    inline for (@typeInfo(@TypeOf(a)).@"struct".field_names) |name| @field(out, name) = @field(a, name);
    inline for (@typeInfo(@TypeOf(b)).@"struct".field_names) |name| @field(out, name) = @field(b, name);
    return out;
}

test merge {
    const m = merge(.{ .title = "Hi", .count = 3, .none = null, .flag = true }, .{ .csrf_token = @as([]const u8, "t") });
    try std.testing.expectEqualStrings("Hi", m.title);
    try std.testing.expectEqual(@as(i64, 3), m.count);
    try std.testing.expectEqual(null, m.none);
    try std.testing.expect(m.flag);
    try std.testing.expectEqualStrings("t", m.csrf_token);
}

/// Adds each `*.mustache` file in `path` to `templates`.
pub fn loadTemplates(io: std.Io, templates: *mustache.Library, path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    try templates.addDir(io, dir);
}
