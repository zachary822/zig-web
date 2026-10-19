//! Sessions, kept in the `session` table (`migrations/0002_create_session.sql`
//! and `0003_session_data.sql`): the id of the logged-in user, and data that
//! handlers keep between requests of one browser (for example flash
//! messages). This file does not know the user struct of the app: see
//! `middleware/current_user.zig`, which loads it from `userId`.
//!
//! The session cookie (`cookieName`) holds a random token: 32 bytes,
//! base64url without padding. The table keeps only the SHA-256 of the token, so a copy of the
//! table does not give cookies that work.
//!
//! A visitor who is not logged in gets a session only when a handler first
//! stores data. A visitor session ends 14 days after the last activity. A
//! login makes a new session (with a new token, against session fixation)
//! with the data of the visitor session; it ends 30 days after the login, at
//! logout, and when the password changes (`zig build user -- passwd`).
//!
//! Data: declare each key one time, with its type, then use it in handlers:
//!
//!     const return_to = Session.Key([]const u8, "return_to");
//!
//!     const data = Session.data(req).?;
//!     try data.put(return_to, "/settings");
//!     const url = try data.get(return_to); // ?[]const u8
//!
//! The values are JSON in the `data` column. `Middleware` loads them with
//! the session, and at the end of the request writes only the keys that
//! changed, so two requests at the same time that change different keys do
//! not lose a change.

const std = @import("std");
const httpz = @import("httpz");
const db = @import("../db.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64 = std.base64.url_safe_no_pad;

const log = std.log.scoped(.session);

const Session = @This();

/// The name of the session cookie. With `Secure`, the `__Host-` prefix makes
/// the browser accept the cookie only from this host, with `Path=/` and
/// without `Domain`, so a different subdomain cannot set it (for example to
/// log in the user as a different user). Browsers reject the prefix without
/// `Secure`, so HTTP (development) uses the plain name.
pub fn cookieName(secure_cookie: bool) []const u8 {
    return if (secure_cookie) "__Host-session" else "session";
}

/// Time a session stays valid after login.
pub const max_age_s = 30 * 24 * 60 * 60;
/// Time a visitor session stays valid after the last activity.
pub const visitor_max_age_s = 14 * 24 * 60 * 60;
/// Maximum size of the data of one session, as JSON.
pub const max_data_len = 64 * 1024;
/// Each new session deletes at most this number of expired sessions, so the
/// table does not grow.
const cleanup_limit = 100;

const token_len = 32;
const encoded_token_len = base64.Encoder.calcSize(token_len);

/// The SHA-256 of a token: the key of the `session` table.
pub const TokenHash = [Sha256.digest_length]u8;

io: std.Io,
/// Set the `Secure` attribute on the cookie (HTTPS only).
secure_cookie: bool,
/// `cookieName(secure_cookie)`.
cookie_name: []const u8,

pub fn init(io: std.Io, secure_cookie: bool) Session {
    return .{ .io = io, .secure_cookie = secure_cookie, .cookie_name = cookieName(secure_cookie) };
}

/// A key for session data: `name` (1 to 64 characters from a-z, 0-9 and
/// `_`) and the type of its value, which `std.json` must be able to read and
/// write.
pub fn Key(comptime T: type, comptime name: []const u8) type {
    comptime {
        if (name.len == 0 or name.len > 64) @compileError("session key name must have 1 to 64 characters: " ++ name);
        for (name) |c| switch (c) {
            'a'...'z', '0'...'9', '_' => {},
            else => @compileError("session key name must use only a-z, 0-9 and _: " ++ name),
        };
    }
    return struct {
        pub const Value = T;
        pub const key_name = name;
    };
}

/// The session data of one request. Reads come from the data that was
/// loaded and the changes of this request; `Middleware` writes the changes
/// at the end of the request.
pub const Data = struct {
    arena: Allocator,
    /// The `data` column, as it was loaded.
    stored_text: []const u8 = "{}",
    /// `stored_text`, parsed at the first read.
    stored: ?std.json.ObjectMap = null,
    /// The changes of this request: the new value as JSON, or null to
    /// remove the key.
    changes: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty,

    /// Returns the value of `K`, or null when there is none. A value that
    /// does not fit the type (for example after a change of the type) is
    /// also null.
    pub fn get(self: *Data, comptime K: type) !?K.Value {
        if (self.changes.get(K.key_name)) |change| {
            const text = change orelse return null;
            return std.json.parseFromSliceLeaky(K.Value, self.arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable, // `put` wrote it from a K.Value
            };
        }
        const object = try self.storedObject();
        const value = object.get(K.key_name) orelse return null;
        return std.json.parseFromValueLeaky(K.Value, self.arena, value, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("session key {s} has a value of a different type; it is not used", .{K.key_name});
                return null;
            },
        };
    }

    /// Sets the value of `K`.
    pub fn put(self: *Data, comptime K: type, value: K.Value) !void {
        const text = try std.json.Stringify.valueAlloc(self.arena, value, .{});
        if (self.size() + text.len > max_data_len) return error.SessionDataTooLarge;
        try self.changes.put(self.arena, K.key_name, text);
    }

    /// Removes `K`, if it has a value.
    pub fn remove(self: *Data, comptime K: type) !void {
        if (try self.get(K) == null) return;
        try self.changes.put(self.arena, K.key_name, null);
    }

    /// Returns the value of `K` and removes it, for values that are used one
    /// time.
    pub fn take(self: *Data, comptime K: type) !?K.Value {
        const value = try self.get(K) orelse return null;
        try self.changes.put(self.arena, K.key_name, null);
        return value;
    }

    /// Forgets the stored data and the changes, for example after logout.
    fn reset(self: *Data) void {
        self.stored_text = "{}";
        self.stored = null;
        self.changes = .empty;
    }

    fn storedObject(self: *Data) !std.json.ObjectMap {
        if (self.stored) |object| return object;
        const value = std.json.parseFromSliceLeaky(std.json.Value, self.arena, self.stored_text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.json.Value{ .null = {} },
        };
        self.stored = if (value == .object) value.object else try .init(self.arena, &.{}, &.{});
        return self.stored.?;
    }

    /// An upper limit for the size of the data after the changes.
    fn size(self: *const Data) usize {
        var n = self.stored_text.len;
        for (self.changes.keys(), self.changes.values()) |name, change| {
            n += name.len + 4 + if (change) |text| text.len else 0;
        }
        return n;
    }

    /// The two JSON merge patches (RFC 7396) for the changes: `clear` sets
    /// each changed key to null (that is, removes it), then `set` adds the
    /// new values. In two steps, a new object replaces the old one and is
    /// not merged into it.
    fn patches(self: *const Data) !struct { clear: []const u8, set: []const u8 } {
        var clear: std.Io.Writer.Allocating = .init(self.arena);
        var set: std.Io.Writer.Allocating = .init(self.arena);
        try clear.writer.writeByte('{');
        try set.writer.writeByte('{');
        var first_set = true;
        for (self.changes.keys(), self.changes.values(), 0..) |name, change, i| {
            // Key names are checked at compile time, so they need no escapes.
            try clear.writer.print("{s}\"{s}\":null", .{ if (i == 0) "" else ",", name });
            if (change) |text| {
                try set.writer.print("{s}\"{s}\":{s}", .{ if (first_set) "" else ",", name, text });
                first_set = false;
            }
        }
        try clear.writer.writeByte('}');
        try set.writer.writeByte('}');
        return .{ .clear = clear.written(), .set = set.written() };
    }

    fn hasValues(self: *const Data) bool {
        for (self.changes.values()) |change| if (change != null) return true;
        return false;
    }
};

/// The session of one request, made by `Middleware`.
const State = struct {
    /// The row of the session, when it exists.
    hash: ?TokenHash = null,
    /// The logged-in user, when there is one.
    user_id: ?u64 = null,
    /// The last activity is more than one day ago.
    stale: bool = false,
    data: Data,
};

/// The key of the state in `req.middlewares`.
const state_key = "session";

fn state(req: *httpz.Request) ?*State {
    const ptr = req.middlewares.get(state_key) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// The id of the logged-in user of `req`. null when the request has no
/// valid login, or when the route does not use `Middleware`.
pub fn userId(req: *httpz.Request) ?u64 {
    return (state(req) orelse return null).user_id;
}

/// The session data of `req`. null when the route does not use
/// `Middleware`.
pub fn data(req: *httpz.Request) ?*Data {
    return &(state(req) orelse return null).data;
}

/// Gives `req` an empty session (no row) with `user_id`, for tests of code
/// that uses the session without `Middleware`.
pub fn attachForTest(req: *httpz.Request, user_id: ?u64) !*Data {
    const st = try req.arena.create(State);
    st.* = .{ .user_id = user_id, .data = .{ .arena = req.arena } };
    try req.middlewares.put(state_key, st);
    return &st.data;
}

/// Logs in `user_id`: makes a new session with the data of the visitor
/// session (which it deletes), and sets the cookie. Uses a transaction on
/// `conn`. The changes of this request go to the new session, and
/// `userId` gives `user_id` for the rest of the request.
pub fn create(self: *const Session, conn: *db.Conn, req: *httpz.Request, res: *httpz.Response, user_id: u64) !void {
    var token: [token_len]u8 = undefined;
    try self.io.randomSecure(&token);
    var hash: TokenHash = undefined;
    Sha256.hash(&token, &hash, .{});
    const s = state(req);
    const old: ?TokenHash = if (s) |st| st.hash else null;

    try conn.begin();
    errdefer conn.rollback();
    try deleteExpired(conn);
    // MAX gives one row also when there is no old session; then `{}`.
    _ = try conn.exec(
        \\INSERT INTO session (token_hash, user_id, expires_at, data)
        \\SELECT ?, ?, NOW() + INTERVAL ? SECOND, COALESCE(MAX(data), '{}')
        \\FROM session WHERE token_hash = ?
    , .{ db.binary(&hash), user_id, @as(u32, max_age_s), if (old) |*h| db.binary(h) else null });
    if (old) |*h| _ = try conn.exec(
        \\DELETE FROM session WHERE token_hash = ?
    , .{db.binary(h)});
    try conn.commit();

    if (s) |st| {
        st.hash = hash;
        st.user_id = user_id;
        st.stale = false;
    }
    try self.setCookie(res, &token, max_age_s);
}

/// Ends the session of `req`: deletes its row and its data, then removes the
/// cookie from the browser. If the row cannot be deleted, the error comes
/// first, so the user does not see a logout that did not occur. Data that
/// the request stores after this goes into a new visitor session.
pub fn destroy(self: *const Session, conn: *db.Conn, req: *httpz.Request, res: *httpz.Response) !void {
    if (self.tokenHash(req)) |hash| {
        _ = try conn.exec(
            \\DELETE FROM session WHERE token_hash = ?
        , .{db.binary(&hash)});
    }
    if (state(req)) |st| {
        st.hash = null;
        st.user_id = null;
        st.data.reset();
    }
    try res.setCookie(self.cookie_name, "", self.cookieOpts(0));
}

/// httpz middleware that loads the session of each request (the user id and
/// the data) and, after the action, writes the changes of the data. It uses
/// the database only when the request has a session cookie or changes the
/// data. If the database cannot be reached, the request gets 500.
pub const Middleware = struct {
    session: *const Session,
    pool: ?*db.Pool,

    pub const Config = struct {
        session: *const Session,
        /// null when no database is configured.
        pool: ?*db.Pool,
    };

    pub fn init(config: Config) !Middleware {
        return .{ .session = config.session, .pool = config.pool };
    }

    pub fn execute(self: *const Middleware, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
        const st = try req.arena.create(State);
        st.* = .{ .data = .{ .arena = req.arena } };
        if (self.session.tokenHash(req)) |hash| try self.load(st, hash, req.arena);
        try req.middlewares.put(state_key, st);

        try executor.next();
        try self.save(st, req, res);
    }

    fn load(self: *const Middleware, st: *State, hash: TokenHash, arena: Allocator) !void {
        const pool = self.pool orelse return error.DbNotConfigured;
        const conn = try pool.acquire();
        defer conn.release();
        const row = try conn.one(
            struct { user_id: ?u64, data: []const u8, stale: bool },
            arena,
            \\SELECT user_id, data, last_seen_at < NOW() - INTERVAL 1 DAY FROM session
            \\WHERE token_hash = ? AND expires_at > NOW()
        ,
            .{db.binary(&hash)},
        ) orelse return;
        st.hash = hash;
        st.stale = row.stale;
        st.data.stored_text = row.data;
        st.user_id = row.user_id;
    }

    fn save(self: *const Middleware, st: *State, req: *httpz.Request, res: *httpz.Response) !void {
        const changed = st.data.changes.count() > 0;
        if (!changed and !(st.hash != null and st.stale)) return;
        // A new session only to store values, not only to remove them.
        if (st.hash == null and !st.data.hasValues()) return;

        const pool = self.pool orelse return error.DbNotConfigured;
        const conn = try pool.acquire();
        defer conn.release();

        if (st.hash) |*hash| {
            const p = try st.data.patches();
            _ = try conn.exec(
                \\UPDATE session
                \\SET data = JSON_MERGE_PATCH(JSON_MERGE_PATCH(data, ?), ?),
                \\    last_seen_at = NOW(),
                \\    expires_at = IF(user_id IS NULL, NOW() + INTERVAL ? SECOND, expires_at)
                \\WHERE token_hash = ?
            , .{ p.clear, p.set, @as(u32, visitor_max_age_s), db.binary(hash) });
            // The browser keeps a visitor cookie as long as the session.
            if (st.user_id == null and st.stale) {
                const name = self.session.cookie_name;
                if (req.cookies().get(name)) |value| try res.setCookie(name, value, self.session.cookieOpts(visitor_max_age_s));
            }
            return;
        }

        var token: [token_len]u8 = undefined;
        try self.session.io.randomSecure(&token);
        var hash: TokenHash = undefined;
        Sha256.hash(&token, &hash, .{});
        try deleteExpired(conn);
        _ = try conn.exec(
            \\INSERT INTO session (token_hash, user_id, expires_at, data)
            \\VALUES (?, NULL, NOW() + INTERVAL ? SECOND, ?)
        , .{ db.binary(&hash), @as(u32, visitor_max_age_s), (try st.data.patches()).set });
        st.hash = hash;
        try self.session.setCookie(res, &token, visitor_max_age_s);
    }
};

fn deleteExpired(conn: *db.Conn) !void {
    _ = try conn.exec(
        \\DELETE FROM session WHERE expires_at <= NOW() LIMIT ?
    , .{cleanup_limit});
}

/// Returns the hash of the session token of `req`, or null when there is no
/// cookie or it is malformed.
fn tokenHash(self: *const Session, req: *httpz.Request) ?TokenHash {
    return hashCookie(req.cookies().get(self.cookie_name) orelse return null);
}

fn hashCookie(value: []const u8) ?TokenHash {
    if (value.len != encoded_token_len) return null;
    var token: [token_len]u8 = undefined;
    base64.Decoder.decode(&token, value) catch return null;
    var hash: TokenHash = undefined;
    Sha256.hash(&token, &hash, .{});
    return hash;
}

fn setCookie(self: *const Session, res: *httpz.Response, token: *const [token_len]u8, max_age: i32) !void {
    const value = try res.arena.alloc(u8, encoded_token_len);
    _ = base64.Encoder.encode(value, token);
    try res.setCookie(self.cookie_name, value, self.cookieOpts(max_age));
}

fn cookieOpts(self: *const Session, max_age: i32) httpz.response.CookieOpts {
    return .{
        .path = "/",
        .max_age = max_age,
        .http_only = true,
        .secure = self.secure_cookie,
        .same_site = .lax,
    };
}

test hashCookie {
    var token: [token_len]u8 = @splat(7);
    var encoded: [encoded_token_len]u8 = undefined;
    _ = base64.Encoder.encode(&encoded, &token);
    var expected: TokenHash = undefined;
    Sha256.hash(&token, &expected, .{});

    try std.testing.expectEqual(expected, hashCookie(&encoded).?);
    try std.testing.expectEqual(null, hashCookie(""));
    try std.testing.expectEqual(null, hashCookie(encoded[1..]));
    var bad = encoded;
    bad[0] = '*';
    try std.testing.expectEqual(null, hashCookie(&bad));
}

test Data {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const Point = struct { x: i32, y: i32 };
    const name = Key([]const u8, "name");
    const point = Key(Point, "point");
    const count = Key(u32, "count");
    const missing = Key(bool, "missing");

    var d: Data = .{ .arena = arena_state.allocator(), .stored_text = "{\"name\":\"ann\",\"count\":\"not a number\",\"point\":{\"x\":1,\"y\":2}}" };
    try std.testing.expectEqualStrings("ann", (try d.get(name)).?);
    try std.testing.expectEqual(Point{ .x = 1, .y = 2 }, (try d.get(point)).?);
    try std.testing.expectEqual(null, try d.get(count)); // a different type
    try std.testing.expectEqual(null, try d.get(missing));
    try std.testing.expectEqual(0, d.changes.count());

    try d.put(count, 3);
    try d.put(point, .{ .x = 5, .y = 6 });
    try std.testing.expectEqual(3, (try d.get(count)).?);
    try std.testing.expectEqualStrings("ann", (try d.take(name)).?);
    try std.testing.expectEqual(null, try d.get(name));
    try d.remove(missing); // no value: no change
    try std.testing.expectEqual(3, d.changes.count());

    const p = try d.patches();
    try std.testing.expectEqualStrings("{\"count\":null,\"point\":null,\"name\":null}", p.clear);
    try std.testing.expectEqualStrings("{\"count\":3,\"point\":{\"x\":5,\"y\":6}}", p.set);

    var big: Data = .{ .arena = arena_state.allocator() };
    try std.testing.expectError(error.SessionDataTooLarge, big.put(name, &@as([max_data_len]u8, @splat('a'))));
}

/// The pool of the `Middleware` test, for its actions.
var test_pool: ?*db.Pool = null;

// Needs a database: set TEST_DATABASE_URL (as DATABASE_URL) and use
// `zig build test-db`. It uses a temporary `session` table, which hides the
// real one on this connection, so it does not change data.
test Middleware {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!db.enabled) return error.SkipZigTest;
    const url = std.testing.environ.getAlloc(gpa, "TEST_DATABASE_URL") catch return error.SkipZigTest;
    defer gpa.free(url);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try db.libraryInit();
    defer db.libraryEnd();
    // One connection, which has the temporary tables.
    const pool = try db.Pool.open(gpa, io, url, .{
        .pool_size = 1,
        .acquire_timeout_ms = 1000,
    });
    defer pool.destroy();
    {
        const conn = try pool.acquire();
        defer conn.release();
        _ = try conn.exec(
            \\CREATE TEMPORARY TABLE session (
            \\    token_hash BINARY(32) NOT NULL PRIMARY KEY,
            \\    user_id BIGINT UNSIGNED NULL,
            \\    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            \\    expires_at TIMESTAMP NOT NULL,
            \\    data JSON NOT NULL DEFAULT '{}',
            \\    last_seen_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            \\)
        , .{});
        // An expired session, which the next new session deletes.
        _ = try conn.exec(
            \\INSERT INTO session (token_hash, user_id, expires_at)
            \\VALUES (?, NULL, NOW() - INTERVAL 1 SECOND)
        , .{db.binary(&@as(TokenHash, @splat(1)))});
    }
    test_pool = pool;
    defer test_pool = null;

    const session: Session = .init(io, false);
    const middleware = try Middleware.init(.{ .session = &session, .pool = pool });
    const Count = struct { n: i64 };
    const count_sql =
        \\SELECT COUNT(*) FROM session
    ;

    // A visitor that only reads gets no session.
    try std.testing.expectEqual(null, try runRequest(&middleware, arena, null, TestActions.readOnly));
    // The first value makes a visitor session; it also deletes the expired one.
    const visitor = (try runRequest(&middleware, arena, null, TestActions.putNote)).?;
    {
        const conn = try pool.acquire();
        defer conn.release();
        try std.testing.expectEqual(1, (try conn.one(Count, arena, count_sql, .{})).?.n);
    }
    try std.testing.expectEqual(null, try runRequest(&middleware, arena, visitor, TestActions.nothing));

    // Two requests that change different keys at the same time: both
    // changes stay.
    {
        var a = httpz.testing.init(.{});
        defer a.deinit();
        var b = httpz.testing.init(.{});
        defer b.deinit();
        const cookie = try std.fmt.allocPrint(arena, "session={s}", .{visitor});
        a.header("Cookie", cookie);
        b.header("Cookie", cookie);
        var sa: State = .{ .data = .{ .arena = arena } };
        var sb: State = .{ .data = .{ .arena = arena } };
        try middleware.load(&sa, session.tokenHash(a.req).?, arena);
        try middleware.load(&sb, session.tokenHash(b.req).?, arena);
        try sa.data.put(test_point, .{ .x = 1 });
        try sb.data.put(Key(u32, "other"), 9);
        try middleware.save(&sa, a.req, a.res);
        try middleware.save(&sb, b.req, b.res);
    }
    _ = try runRequest(&middleware, arena, visitor, TestActions.expectBoth);

    // Login: a new token, with the data of the visitor session.
    const logged_in = (try runRequest(&middleware, arena, visitor, TestActions.login)).?;
    try std.testing.expect(!std.mem.eql(u8, visitor, logged_in));
    _ = try runRequest(&middleware, arena, visitor, TestActions.expectEmpty); // the old token is gone
    _ = try runRequest(&middleware, arena, logged_in, TestActions.expectLoggedIn);
    _ = try runRequest(&middleware, arena, logged_in, TestActions.expectTaken);

    // Logout deletes the session and its data.
    _ = try runRequest(&middleware, arena, logged_in, TestActions.logout);
    {
        const conn = try pool.acquire();
        defer conn.release();
        try std.testing.expectEqual(0, (try conn.one(Count, arena, count_sql, .{})).?.n);
    }
}

const test_note = Key([]const u8, "note");
const test_point = Key(struct { x: i32 }, "point");

/// Runs `action` through `mw` as a request with the session cookie
/// `cookie`, and returns the session cookie that the response sets, if any.
fn runRequest(
    mw: *const Middleware,
    arena: Allocator,
    cookie: ?[]const u8,
    action: *const fn (*httpz.Request, *httpz.Response) anyerror!void,
) !?[]const u8 {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    if (cookie) |c| ht.header("Cookie", try std.fmt.allocPrint(arena, "session={s}", .{c}));
    const Next = struct {
        req: *httpz.Request,
        res: *httpz.Response,
        action: *const fn (*httpz.Request, *httpz.Response) anyerror!void,

        pub fn next(n: *@This()) !void {
            return n.action(n.req, n.res);
        }
    };
    var next: Next = .{ .req = ht.req, .res = ht.res, .action = action };
    try mw.execute(ht.req, ht.res, &next);
    const set = ht.res.headers.get("Set-Cookie") orelse return null;
    return try arena.dupe(u8, set["session=".len..std.mem.indexOfScalar(u8, set, ';').?]);
}

const TestActions = struct {
    fn nothing(_: *httpz.Request, _: *httpz.Response) !void {}

    fn readOnly(req: *httpz.Request, _: *httpz.Response) !void {
        try std.testing.expectEqual(null, try data(req).?.get(test_note));
    }

    fn putNote(req: *httpz.Request, _: *httpz.Response) !void {
        try data(req).?.put(test_note, "hello");
    }

    fn expectBoth(req: *httpz.Request, _: *httpz.Response) !void {
        try std.testing.expectEqualStrings("hello", (try data(req).?.get(test_note)).?);
        try std.testing.expectEqual(1, (try data(req).?.get(test_point)).?.x);
        try std.testing.expectEqual(9, (try data(req).?.get(Key(u32, "other"))).?);
        try std.testing.expectEqual(null, userId(req));
    }

    fn login(req: *httpz.Request, res: *httpz.Response) !void {
        const s: Session = .init(std.testing.io, false);
        const conn = try test_pool.?.acquire();
        defer conn.release();
        try s.create(conn, req, res, 7);
        try std.testing.expectEqual(7, userId(req).?);
        try data(req).?.put(test_point, .{ .x = 2 });
    }

    fn expectEmpty(req: *httpz.Request, _: *httpz.Response) !void {
        try std.testing.expectEqual(null, try data(req).?.get(test_note));
        try std.testing.expectEqual(null, userId(req));
    }

    fn expectLoggedIn(req: *httpz.Request, _: *httpz.Response) !void {
        try std.testing.expectEqual(7, userId(req).?);
        try std.testing.expectEqualStrings("hello", (try data(req).?.take(test_note)).?);
        try std.testing.expectEqual(2, (try data(req).?.get(test_point)).?.x);
    }

    fn expectTaken(req: *httpz.Request, _: *httpz.Response) !void {
        try std.testing.expectEqual(null, try data(req).?.get(test_note));
        try std.testing.expectEqual(2, (try data(req).?.get(test_point)).?.x);
    }

    fn logout(req: *httpz.Request, res: *httpz.Response) !void {
        const s: Session = .init(std.testing.io, false);
        const conn = try test_pool.?.acquire();
        defer conn.release();
        try s.destroy(conn, req, res);
        try std.testing.expectEqual(null, userId(req));
    }
};
