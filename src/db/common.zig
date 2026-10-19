//! Types shared by the MariaDB implementation and the disabled stub, and the
//! parser for `DATABASE_URL`.

const std = @import("std");

/// Where and how to connect. Strings are null-terminated for the C library.
pub const Connection = struct {
    /// Ignored when `socket` is set.
    host: [:0]const u8,
    port: u16,
    /// Unix socket path. Used in place of TCP when set.
    socket: ?[:0]const u8,
    user: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,
    /// TLS for TCP connections. Unix socket connections are local and do
    /// not use TLS.
    tls: Tls = .required,
    /// CA certificate file to verify the server certificate. Without it,
    /// Connector/C 3.4 and MariaDB 11.4 or newer verify the certificate with
    /// the user's password.
    tls_ca: ?[:0]const u8 = null,
};

pub const Tls = enum {
    /// Use TLS and verify the server certificate.
    required,
    /// No TLS, for servers without it. The password and data are sent
    /// unencrypted.
    disabled,
};

pub const Options = struct {
    connection: Connection,
    /// Maximum number of open connections.
    pool_size: u16,
    /// Time that `acquire` waits for a free connection.
    acquire_timeout_ms: u32,
    /// Seconds after which a connection is closed and opened again, when it
    /// is next acquired. Then changes to DNS, to the server (a failover) and
    /// to the password take effect, and session state cannot stay on a
    /// connection for a long time. 0: no limit.
    conn_max_age_s: u32 = 3600,
    /// Allow several statements in one call, for `Conn.execScript`. Only for
    /// trusted SQL such as migration files, never for queries with user input.
    multi_statements: bool = false,
};

pub const Error = error{
    /// The server was started without a database (`DATABASE_URL` is not set).
    DbNotConfigured,
    /// The database server cannot be reached.
    DbUnavailable,
    /// All connections stayed in use for `acquire_timeout_ms`.
    PoolTimeout,
    /// The task was canceled (`std.Io` cancelation) while it waited for a
    /// free connection.
    Canceled,
    /// The database rejected the query, or the result does not match the
    /// requested type. The details are logged.
    QueryFailed,
    OutOfMemory,
};

/// Binary data (BINARY, VARBINARY, BLOB columns). As a query parameter, it
/// is sent as bytes, without a character set; a plain `[]const u8` is sent
/// as utf8mb4 text. Make one with `binary`. As a result field, it holds the
/// bytes of the column.
pub const Binary = struct {
    bytes: []const u8,
};

/// Marks `bytes` as binary data for a query parameter.
pub fn binary(bytes: []const u8) Binary {
    return .{ .bytes = bytes };
}

pub const ExecResult = struct {
    affected_rows: u64,
    insert_id: u64,
};

pub const UrlError = std.Uri.ParseError || std.mem.Allocator.Error || error{
    UnsupportedScheme,
    MissingUser,
    MissingDatabase,
    UnknownParameter,
    InvalidParameter,
};

/// Parses a connection string:
///
///     mariadb://USER[:PASSWORD]@[HOST][:PORT]/DATABASE[?PARAM=VALUE&...]
///
/// `mysql://` is also accepted. HOST defaults to 127.0.0.1 and PORT to 3306.
/// Parameters:
///   - `socket=PATH`: use this Unix socket in place of TCP.
///   - `tls=required|disabled`: TLS for TCP connections (default: required,
///     with verification of the server certificate).
///   - `tls_ca=PATH`: CA certificate file for the verification.
/// Special characters in the parts must be percent-encoded, for example
/// `@` as `%40`. All strings are allocated with `arena`.
pub fn parseUrl(arena: std.mem.Allocator, url: []const u8) UrlError!Connection {
    const uri = try std.Uri.parse(url);
    if (!std.mem.eql(u8, uri.scheme, "mariadb") and !std.mem.eql(u8, uri.scheme, "mysql")) {
        return error.UnsupportedScheme;
    }

    const user = try decode(arena, uri.user orelse return error.MissingUser);
    if (user.len == 0) return error.MissingUser;
    const password = if (uri.password) |p| try decode(arena, p) else try arena.dupeSentinel(u8, "", 0);
    const host = if (uri.host) |h| try decode(arena, h) else try arena.dupeSentinel(u8, "127.0.0.1", 0);

    const path = try decode(arena, uri.path);
    const database = std.mem.trimStart(u8, path, "/");
    if (database.len == 0 or std.mem.indexOfScalar(u8, database, '/') != null) return error.MissingDatabase;

    var socket: ?[:0]const u8 = null;
    var tls: Tls = .required;
    var tls_ca: ?[:0]const u8 = null;
    if (uri.query) |query| {
        const encoded = switch (query) {
            .raw, .percent_encoded => |s| s,
        };
        var params = std.mem.splitScalar(u8, encoded, '&');
        while (params.next()) |param| {
            if (param.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, param, '=') orelse param.len;
            const value = if (eq < param.len) param[eq + 1 ..] else "";
            const name = param[0..eq];
            if (value.len == 0) return error.InvalidParameter;
            if (std.mem.eql(u8, name, "socket")) {
                socket = try decode(arena, .{ .percent_encoded = value });
            } else if (std.mem.eql(u8, name, "tls")) {
                tls = std.meta.stringToEnum(Tls, value) orelse return error.InvalidParameter;
            } else if (std.mem.eql(u8, name, "tls_ca")) {
                tls_ca = try decode(arena, .{ .percent_encoded = value });
            } else {
                return error.UnknownParameter;
            }
        }
    }

    return .{
        .host = host,
        .port = uri.port orelse 3306,
        .socket = socket,
        .user = user,
        .password = password,
        .database = try arena.dupeSentinel(u8, database, 0),
        .tls = tls,
        .tls_ca = tls_ca,
    };
}

fn decode(arena: std.mem.Allocator, component: std.Uri.Component) ![:0]const u8 {
    return arena.dupeSentinel(u8, try component.toRawMaybeAlloc(arena), 0);
}

test parseUrl {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const full = try parseUrl(arena, "mariadb://app:p%40ss%3Aw0rd@db.example.com:3307/zig_web");
    try std.testing.expectEqualStrings("app", full.user);
    try std.testing.expectEqualStrings("p@ss:w0rd", full.password);
    try std.testing.expectEqualStrings("db.example.com", full.host);
    try std.testing.expectEqual(3307, full.port);
    try std.testing.expectEqualStrings("zig_web", full.database);
    try std.testing.expectEqual(null, full.socket);

    const defaults = try parseUrl(arena, "mysql://app@/zig_web");
    try std.testing.expectEqualStrings("", defaults.password);
    try std.testing.expectEqualStrings("127.0.0.1", defaults.host);
    try std.testing.expectEqual(3306, defaults.port);

    const socket = try parseUrl(arena, "mariadb://app:pw@localhost/zig_web?socket=/run/mysqld/mysqld.sock");
    try std.testing.expectEqualStrings("/run/mysqld/mysqld.sock", socket.socket.?);

    const encoded_socket = try parseUrl(arena, "mariadb://app@localhost/zig_web?socket=%2Ftmp%2Fmy%20db.sock");
    try std.testing.expectEqualStrings("/tmp/my db.sock", encoded_socket.socket.?);

    try std.testing.expectEqual(.required, full.tls);
    try std.testing.expectEqual(null, full.tls_ca);
    const no_tls = try parseUrl(arena, "mariadb://app@db/zig_web?tls=disabled");
    try std.testing.expectEqual(.disabled, no_tls.tls);
    const with_ca = try parseUrl(arena, "mariadb://app@db/zig_web?tls=required&tls_ca=/etc/ssl/ca.pem");
    try std.testing.expectEqualStrings("/etc/ssl/ca.pem", with_ca.tls_ca.?);

    try std.testing.expectError(error.InvalidParameter, parseUrl(arena, "mariadb://app@db/zig_web?tls=maybe"));
    try std.testing.expectError(error.InvalidParameter, parseUrl(arena, "mariadb://app@db/zig_web?socket="));
    try std.testing.expectError(error.UnsupportedScheme, parseUrl(arena, "postgres://app@localhost/zig_web"));
    try std.testing.expectError(error.MissingUser, parseUrl(arena, "mariadb://localhost/zig_web"));
    try std.testing.expectError(error.MissingDatabase, parseUrl(arena, "mariadb://app@localhost"));
    try std.testing.expectError(error.MissingDatabase, parseUrl(arena, "mariadb://app@localhost/"));
    try std.testing.expectError(error.MissingDatabase, parseUrl(arena, "mariadb://app@localhost/a/b"));
    try std.testing.expectError(error.UnknownParameter, parseUrl(arena, "mariadb://app@localhost/db?sockt=/x"));
    try std.testing.expectError(error.InvalidPort, parseUrl(arena, "mariadb://app@localhost:99999/db"));
}
