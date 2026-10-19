//! User accounts, managed with `zig build user -- COMMAND`. The app has no
//! registration page, so this is the way to add users.
//!
//! The password is read from the terminal without echo (two times, to catch
//! typing mistakes). When stdin is not a terminal, the first line of stdin
//! is the password, for scripts:
//!
//!     printf '%s\n' "$PASSWORD" | zig_web_user create ann ann@example.com
//!
//! Configuration comes from `.env` and the environment, like the server:
//! `DATABASE_URL` (required).

const std = @import("std");
const config = @import("config.zig");
const db = @import("db.zig");
const PasswordHasher = @import("password.zig");

const Allocator = std.mem.Allocator;

const Settings = struct {
    database_url: ?[]const u8 = null,
};

const usage =
    \\Usage: zig build user -- COMMAND
    \\
    \\Commands:
    \\  create USERNAME EMAIL   Add a user. Asks for the password.
    \\  passwd USERNAME         Set a new password. Asks for the password.
    \\  list                    Show all users.
    \\
    \\USERNAME: 1 to 64 characters from A-Z, a-z, 0-9, '.', '_' and '-'.
    \\Passwords: at least 8 characters.
    \\
;

pub const min_password_len = 8;
const max_username_len = 64;
const max_email_len = 254;

const Command = enum { create, passwd, list };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buf: [4096]u8 = undefined;
    var out_file: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const command = if (args.len > 1) std.meta.stringToEnum(Command, args[1]) else null;
    const arg_count: usize = if (command) |c| switch (c) {
        .create => 4,
        .passwd => 3,
        .list => 2,
    } else 0;
    if (command == null or args.len != arg_count) {
        try out.writeAll(usage);
        return 2;
    }

    // Check the arguments before the password prompt and the connection.
    if (command.? != .list) {
        if (!isValidUsername(args[2])) {
            std.log.err("USERNAME is not valid: {s}", .{args[2]});
            return 2;
        }
    }
    if (command.? == .create and !isValidEmail(args[3])) {
        std.log.err("EMAIL is not valid: {s}", .{args[3]});
        return 2;
    }

    var diag: config.Diagnostic = .{};
    config.loadDotEnv(io, gpa, init.environ_map, ".env", &diag) catch |err| {
        std.log.err(".env line {d}: {t}", .{ diag.line, err });
        return 1;
    };
    const settings = config.fromEnv(Settings, init.environ_map, &diag) catch |err| {
        std.log.err("{s}=\"{s}\": {t}", .{ diag.key, diag.value, err });
        return 1;
    };

    if (!db.enabled) {
        std.log.err("this build has no MariaDB support (install libmariadb and build with -Ddb=true)", .{});
        return 1;
    }
    const url = settings.database_url orelse {
        std.log.err("DATABASE_URL is not set", .{});
        return 1;
    };
    db.libraryInit() catch |err| {
        std.log.err("cannot initialize the MariaDB library: {t}", .{err});
        return 1;
    };
    defer db.libraryEnd();
    const pool = db.Pool.open(gpa, io, url, .{
        .pool_size = 1,
        .acquire_timeout_ms = 1000,
    }) catch |err| {
        std.log.err("DATABASE_URL is not valid: {t}", .{err});
        return 1;
    };
    defer pool.destroy();
    const connection = pool.connection;
    const conn = pool.acquire() catch |err| {
        std.log.err("cannot connect to database {s}@{s}/{s}: {t}", .{ connection.user, connection.socket orelse connection.host, connection.database, err });
        return 1;
    };
    defer conn.release();

    var passwords: PasswordHasher = .init(io, gpa, .{ .max_concurrent = 1 });
    switch (command.?) {
        .list => return list(conn, arena, out),
        .create => return create(io, conn, arena, out, &passwords, args[2], args[3]),
        .passwd => return passwd(io, conn, arena, out, &passwords, args[2]),
    }
}

fn list(conn: *db.Conn, arena: Allocator, out: *std.Io.Writer) !u8 {
    const users = try conn.query(
        struct { id: u64, username: []const u8, email: []const u8, created_at: []const u8 },
        arena,
        \\SELECT id, username, email, DATE_FORMAT(created_at, '%Y-%m-%d %H:%i')
        \\FROM `user` ORDER BY id
    ,
        .{},
    );
    if (users.len == 0) {
        try out.writeAll("No users.\n");
        return 0;
    }
    try out.print("{s:>6}  {s:<24} {s:<32} {s}\n", .{ "ID", "USERNAME", "EMAIL", "CREATED" });
    for (users) |u| try out.print("{d:>6}  {s:<24} {s:<32} {s}\n", .{ u.id, u.username, u.email, u.created_at });
    return 0;
}

fn create(
    io: std.Io,
    conn: *db.Conn,
    arena: Allocator,
    out: *std.Io.Writer,
    passwords: *PasswordHasher,
    username: []const u8,
    email: []const u8,
) !u8 {
    // The columns compare without regard to case, like the unique keys.
    const taken = try conn.one(
        struct { username: bool, email: bool },
        arena,
        \\SELECT username = ?, email = ? FROM `user`
        \\WHERE username = ? OR email = ? LIMIT 1
    ,
        .{ username, email, username, email },
    );
    if (taken) |t| {
        std.log.err("a user with this {s} exists", .{if (t.username) "username" else "email"});
        return 1;
    }

    const password = try readNewPassword(io, arena) orelse return 1;
    const hash = try passwords.hash(arena, password);
    const result = try conn.exec(
        \\INSERT INTO `user` (username, email, password_hash) VALUES (?, ?, ?)
    , .{ username, email, hash });
    try out.print("created user {s} (id {d})\n", .{ username, result.insert_id });
    return 0;
}

fn passwd(
    io: std.Io,
    conn: *db.Conn,
    arena: Allocator,
    out: *std.Io.Writer,
    passwords: *PasswordHasher,
    username: []const u8,
) !u8 {
    const user = try conn.one(struct { id: u64 }, arena,
        \\SELECT id FROM `user` WHERE username = ?
    , .{username}) orelse {
        std.log.err("no user with the username {s}", .{username});
        return 1;
    };

    const password = try readNewPassword(io, arena) orelse return 1;
    const hash = try passwords.hash(arena, password);
    // A person who knew the old password can have a session: end them all,
    // in the same transaction as the change.
    try conn.begin();
    errdefer conn.rollback();
    _ = try conn.exec(
        \\UPDATE `user` SET password_hash = ? WHERE id = ?
    , .{ hash, user.id });
    const ended = try conn.exec(
        \\DELETE FROM session WHERE user_id = ?
    , .{user.id});
    try conn.commit();
    try out.print("changed the password of {s}; ended {d} session(s)\n", .{ username, ended.affected_rows });
    return 0;
}

/// Reads a new password: from the terminal two times without echo, or the
/// first line of stdin when it is not a terminal. Returns null (after logging
/// why) when the password is not acceptable.
fn readNewPassword(io: std.Io, arena: Allocator) !?[]const u8 {
    const stdin: std.Io.File = .stdin();
    var buf: [PasswordHasher.max_password_len + 2]u8 = undefined;
    var reader: std.Io.File.Reader = .init(stdin, io, &buf);

    const password = if (try stdin.isTty(io)) blk: {
        const first = try promptNoEcho(io, arena, &reader.interface, "Password: ") orelse return null;
        const again = try promptNoEcho(io, arena, &reader.interface, "Password (again): ") orelse return null;
        if (!std.mem.eql(u8, first, again)) {
            std.log.err("the passwords are not the same", .{});
            return null;
        }
        break :blk first;
    } else try readLine(arena, &reader.interface) orelse {
        std.log.err("no password on stdin", .{});
        return null;
    };

    const chars = std.unicode.utf8CountCodepoints(password) catch password.len;
    if (chars < min_password_len) {
        std.log.err("the password must have at least {d} characters", .{min_password_len});
        return null;
    }
    if (password.len > PasswordHasher.max_password_len) {
        std.log.err("the password must have at most {d} bytes", .{PasswordHasher.max_password_len});
        return null;
    }
    return password;
}

/// Writes `prompt` to stderr and reads one line with echo off.
fn promptNoEcho(io: std.Io, arena: Allocator, reader: *std.Io.Reader, prompt: []const u8) !?[]const u8 {
    var err_buf: [64]u8 = undefined;
    var err_file: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &err_file.interface;
    try stderr.writeAll(prompt);
    try stderr.flush();

    const fd = std.Io.File.stdin().handle;
    const original = try std.posix.tcgetattr(fd);
    var no_echo = original;
    no_echo.lflag.ECHO = false;
    try std.posix.tcsetattr(fd, .FLUSH, no_echo);
    defer {
        std.posix.tcsetattr(fd, .FLUSH, original) catch {};
        // The Enter key was not echoed.
        stderr.writeAll("\n") catch {};
        stderr.flush() catch {};
    }

    return readLine(arena, reader);
}

/// Reads one line without its `\n` (and `\r`). Returns null at the end of
/// input, and an error if the line is longer than the reader's buffer.
fn readLine(allocator: Allocator, reader: *std.Io.Reader) !?[]const u8 {
    const line = try reader.takeDelimiter('\n') orelse return null;
    return try allocator.dupe(u8, std.mem.trimEnd(u8, line, "\r"));
}

fn isValidUsername(name: []const u8) bool {
    if (name.len == 0 or name.len > max_username_len) return false;
    for (name) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// A simple check that finds typing mistakes. It does not try to accept
/// only addresses that can receive mail.
fn isValidEmail(email: []const u8) bool {
    if (email.len > max_email_len) return false;
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return false;
    if (at == 0 or at == email.len - 1) return false;
    if (std.mem.indexOfScalar(u8, email[at + 1 ..], '@') != null) return false;
    for (email) |c| if (c <= ' ' or c == 0x7f) return false;
    return true;
}

test isValidUsername {
    try std.testing.expect(isValidUsername("ann"));
    try std.testing.expect(isValidUsername("Ann.B_c-9"));
    try std.testing.expect(!isValidUsername(""));
    try std.testing.expect(!isValidUsername("ann@example.com"));
    try std.testing.expect(!isValidUsername("ann b"));
    try std.testing.expect(!isValidUsername("änn"));
    try std.testing.expect(!isValidUsername(&@as([max_username_len + 1]u8, @splat('a'))));
}

test isValidEmail {
    try std.testing.expect(isValidEmail("ann@example.com"));
    try std.testing.expect(isValidEmail("a@b"));
    try std.testing.expect(!isValidEmail("ann"));
    try std.testing.expect(!isValidEmail("@example.com"));
    try std.testing.expect(!isValidEmail("ann@"));
    try std.testing.expect(!isValidEmail("a@b@c"));
    try std.testing.expect(!isValidEmail("ann @example.com"));
}

test readLine {
    var r: std.Io.Reader = .fixed("secret pw\r\nsecond\n");
    const a = std.testing.allocator;
    const first = (try readLine(a, &r)).?;
    defer a.free(first);
    try std.testing.expectEqualStrings("secret pw", first);
    const second = (try readLine(a, &r)).?;
    defer a.free(second);
    try std.testing.expectEqualStrings("second", second);
    try std.testing.expectEqual(null, try readLine(a, &r));
}
