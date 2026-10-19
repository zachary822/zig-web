//! The logged-in user as a struct of the app. `session.zig` keeps only the
//! user id; `Middleware(User)` loads the `User` for it with the app's own
//! query, after `Session.Middleware`:
//!
//!     const User = struct {
//!         id: u64,
//!         username: []const u8,
//!
//!         pub fn load(conn: *db.Conn, arena: std.mem.Allocator, id: u64) !?User {
//!             return conn.one(User, arena,
//!                 \\SELECT id, username FROM `user` WHERE id = ?
//!             , .{id});
//!         }
//!     };
//!
//!     const mw = try server.middleware(current_user.Middleware(User), .{ .pool = db_pool });
//!     current_user.get(User, req) // ?User
//!
//! `User` can be any struct with that `load` function. Each `User` type has
//! its own place in the request, so two types do not mix.

const std = @import("std");
const httpz = @import("httpz");
const db = @import("../db.zig");
const Session = @import("session.zig");

/// The `User` of `req`, as `Middleware(User)` loaded it. null when the
/// request has no login, when the route does not use the middleware, or
/// after a logout in this request.
pub fn get(comptime User: type, req: *httpz.Request) ?User {
    const ptr = req.middlewares.get(key(User)) orelse return null;
    const loaded: *const Loaded(User) = @ptrCast(@alignCast(ptr));
    // The session can change in the request (logout): then the user is not
    // valid.
    if (Session.userId(req) != loaded.id) return null;
    return loaded.user;
}

/// httpz middleware that loads the `User` of the session. It must come
/// after `Session.Middleware`. It uses the database only when the session
/// has a user. If the user cannot be loaded, the request gets 500; a user
/// that no longer exists is no user.
pub fn Middleware(comptime User: type) type {
    comptime checkUser(User);
    return struct {
        pool: ?*db.Pool,

        const Self = @This();

        pub const Config = struct {
            /// null when no database is configured.
            pool: ?*db.Pool,
        };

        pub fn init(config: Config) !Self {
            return .{ .pool = config.pool };
        }

        pub fn execute(self: *const Self, req: *httpz.Request, _: *httpz.Response, executor: anytype) !void {
            if (Session.userId(req)) |id| {
                const pool = self.pool orelse return error.DbNotConfigured;
                const user = blk: {
                    const conn = try pool.acquire();
                    defer conn.release();
                    break :blk try User.load(conn, req.arena, id);
                };
                if (user) |u| {
                    const loaded = try req.arena.create(Loaded(User));
                    loaded.* = .{ .id = id, .user = u };
                    try req.middlewares.put(key(User), loaded);
                }
            }
            return executor.next();
        }
    };
}

/// A loaded user, and the session user id that it is for.
fn Loaded(comptime User: type) type {
    return struct { id: u64, user: User };
}

fn key(comptime User: type) []const u8 {
    return "current_user." ++ @typeName(User);
}

fn checkUser(comptime User: type) void {
    if (!@hasDecl(User, "load")) @compileError(@typeName(User) ++ " needs `pub fn load(conn: *db.Conn, arena: Allocator, id: u64) !?" ++ @typeName(User) ++ "`");
}

test Middleware {
    const TestUser = struct {
        name: []const u8,

        pub fn load(_: *db.Conn, _: std.mem.Allocator, id: u64) !?@This() {
            return if (id == 7) .{ .name = "ann" } else null;
        }
    };
    const Other = struct {
        pub fn load(_: *db.Conn, _: std.mem.Allocator, _: u64) !?@This() {
            return .{};
        }
    };

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    // Without a session, or with no user: null, and no database.
    try std.testing.expectEqual(null, get(TestUser, ht.req));
    const mw = try Middleware(TestUser).init(.{ .pool = null });
    _ = try Session.attachForTest(ht.req, null);
    const Next = struct {
        pub fn next(_: *@This()) !void {}
    };
    var next: Next = .{};
    try mw.execute(ht.req, ht.res, &next);
    try std.testing.expectEqual(null, get(TestUser, ht.req));

    // A value that the middleware loaded is for the session user id only,
    // and only for its own type.
    _ = try Session.attachForTest(ht.req, 7);
    const loaded = try ht.req.arena.create(Loaded(TestUser));
    loaded.* = .{ .id = 7, .user = .{ .name = "ann" } };
    try ht.req.middlewares.put(key(TestUser), loaded);
    try std.testing.expectEqualStrings("ann", get(TestUser, ht.req).?.name);
    try std.testing.expectEqual(null, get(Other, ht.req));
    _ = try Session.attachForTest(ht.req, null); // logout
    try std.testing.expectEqual(null, get(TestUser, ht.req));
}
