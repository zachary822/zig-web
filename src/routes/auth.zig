//! Login and logout. There is no registration: create users with
//! `zig build user -- create USERNAME EMAIL` (see `user.zig`).

const std = @import("std");
const httpz = @import("httpz");
const App = @import("../App.zig");
const db = @import("../db.zig");
const form = @import("../form.zig");
const flash = @import("../flash.zig");
const Session = @import("../middleware/session.zig");

const log = std.log.scoped(.auth);

/// The login form. The password is not trimmed, and has no length rule: a
/// password that is too long is only not correct (`PasswordHasher.verify`).
const LoginModel = struct {
    /// A user name or an email address (at most 254 characters).
    username: form.Field = .{ .type = []const u8, .required = true, .max_len = 254 },
    password: form.Field = .{ .type = []const u8, .required = true, .trim = false },
};
const LoginForm = form.Validator(LoginModel);

/// `GET /login`: the login form. Users that are logged in go to the home page.
pub fn loginForm(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (app.currentUser(req) != null) return app.redirect(res, "/");
    try renderForm(app, req, res, "", null);
}

/// `POST /login`: the user name (or email) and the password from the form.
pub fn login(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const input = try LoginForm.fromRequest(req);
    const username = input.values.username;
    const password = input.values.password;
    if (input.firstError()) |err| {
        res.status = 400;
        return renderForm(app, req, res, username, err);
    }

    // The value is a user name or an email address. User names do not
    // contain `@` and email addresses do, so at most one row matches.
    // The connection goes back to the pool before the hash, which is slow.
    const user = blk: {
        const conn = try app.dbConn();
        defer conn.release();
        break :blk try conn.one(struct { id: u64, password_hash: []const u8 }, res.arena,
            \\SELECT id, password_hash FROM `user` WHERE username = ? OR email = ?
        , .{ username, username });
    };

    // An unknown user takes the same time as a wrong password, and gets the
    // same answer when the hasher is busy.
    const verified = if (user) |u| app.passwords.verify(u.password_hash, password) else unknown: {
        app.passwords.verifyDummy(password) catch |err| break :unknown err;
        break :unknown false;
    };
    const ok = verified catch |err| switch (err) {
        error.HasherBusy => {
            res.status = 503;
            return renderForm(app, req, res, username, "The server is busy. Try again in a moment.");
        },
        else => return err,
    };
    if (!ok) {
        res.status = 401;
        return renderForm(app, req, res, username, "The username or password is not correct.");
    }

    const u = user.?;
    const conn = try app.dbConn();
    defer conn.release();
    if (app.passwords.needsRehash(u.password_hash)) {
        rehash(app, conn, res.arena, u.id, password) catch |err| {
            // The old hash stays valid, so the login continues.
            log.warn("cannot upgrade the password hash of user {d}: {t}", .{ u.id, err });
        };
    }

    try app.session.create(conn, req, res, u.id);
    try flash.add(req, .success, "You are logged in.");
    app.redirect(res, "/");
}

/// `POST /logout`. Without a login there is nothing to end, and no message:
/// the message would make a new visitor session, so each request without a
/// cookie would add a row to the `session` table.
pub fn logout(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (Session.userId(req) == null) return app.redirect(res, "/");
    const conn = try app.dbConn();
    defer conn.release();
    try app.session.destroy(conn, req, res);
    try flash.add(req, .info, "You are logged out.");
    app.redirect(res, "/");
}

/// Replaces the stored hash with one made with the current parameters. This
/// occurs only after the parameters change, so the connection can wait for
/// the hash.
fn rehash(app: *App, conn: *db.Conn, arena: std.mem.Allocator, user_id: u64, password: []const u8) !void {
    const new = try app.passwords.hash(arena, password);
    _ = try conn.exec(
        \\UPDATE `user` SET password_hash = ? WHERE id = ?
    , .{ new, user_id });
}

fn renderForm(app: *App, req: *httpz.Request, res: *httpz.Response, username: []const u8, err: ?[]const u8) !void {
    res.header("Cache-Control", "no-store");
    try app.render(req, res, "login", .{
        .username = username,
        .@"error" = err,
    });
}
