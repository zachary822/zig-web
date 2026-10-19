//! Application configuration, read from environment variables.
//!
//! In development, a `.env` file in the working directory is loaded first.
//! Variables that are already set in the environment take priority over the
//! file, so in production the real environment always wins.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

/// Each field is read from the environment variable with the upper-case name
/// of the field, for example `port` from `PORT`. Fields without a default are
/// required.
pub const Config = struct {
    /// IP address to listen on. Use `0.0.0.0` to listen on all interfaces.
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    /// Serve `static_url` from `static_dir`. Set to false if a different
    /// server (for example nginx) sends the static files.
    serve_static: bool = build_options.serve_static,
    static_dir: []const u8 = "static",
    /// The URL path of the static files, in the `{{#static}}` URLs and in the
    /// route. It must start and end with `/`.
    static_url: []const u8 = "/static/",
    /// Read the static files from disk again for each request, so changes
    /// show up without a restart. When false, they are loaded into memory one
    /// time at startup.
    reload_static: bool = builtin.mode == .debug,
    /// Directory with the `*.mustache` templates.
    template_dir: []const u8 = "templates",
    /// Read the templates from disk again for each request, so changes show
    /// up without a restart. When false, they are loaded one time at startup.
    reload_templates: bool = builtin.mode == .debug,
    /// Directory for the uploaded files (see `media.zig`). The server must
    /// be able to write to it, and makes it when it does not exist.
    media_dir: []const u8 = "media",
    /// The URL path of the uploaded files. It must start and end with `/`.
    /// With `serve_static`, the server sends them; else a different server
    /// (nginx) must.
    media_url: []const u8 = "/media/",

    /// Secret for signing CSRF tokens; at least 32 characters, for example
    /// from `openssl rand -base64 48`. Without it, a random key is used, so
    /// tokens become invalid when the server restarts. Login sessions are in
    /// the database and do not use it.
    secret_key: ?[]const u8 = null,
    /// Set the `Secure` attribute on cookies, so browsers send them only over
    /// HTTPS. Default: true for release builds.
    cookie_secure: bool = builtin.mode != .debug,
    /// Maximum number of password hashes (logins, registrations) that run at
    /// the same time. Each one uses 19 MiB of memory for a short time.
    password_hash_concurrency: u16 = 2,

    /// MariaDB connection string, see `parseUrl` in zig-db (`db.parseUrl`):
    /// `mariadb://USER:PASSWORD@HOST:PORT/DATABASE[?socket=PATH]`.
    /// Optional: without it, the server runs without a database. When the
    /// database cannot be reached, the server still starts; requests that
    /// need the database get 500 until it is back.
    database_url: ?[]const u8 = null,
    /// Maximum number of database connections.
    db_pool_size: u16 = 8,
    /// Milliseconds a request waits for a free connection before it gets 500.
    db_pool_timeout_ms: u32 = 5000,
    /// Seconds after which a database connection is closed and opened again,
    /// when it is next used. 0: no limit.
    db_conn_max_age_s: u32 = 3600,

    /// The OpenTelemetry collector (Grafana Alloy) for traces, as an OTLP/HTTP
    /// base URL, for example `http://127.0.0.1:4319`. The spans go to
    /// `/v1/traces` (see `trace.zig`). Optional: without it, the server makes
    /// no spans.
    otel_exporter_otlp_endpoint: ?[]const u8 = null,
    /// The `service.name` of the spans.
    otel_service_name: []const u8 = "zig-web",
};

/// Details about the last error from `loadDotEnv`, `parseDotEnv` or `fromEnv`.
pub const Diagnostic = struct {
    /// Line number in the `.env` file (1-based), or 0 for `fromEnv` errors.
    line: usize = 0,
    /// The environment variable name, when known.
    key: []const u8 = "",
    /// The rejected value, when known.
    value: []const u8 = "",
};

/// Loads `path` (if it exists) into `env`. Variables that are already in
/// `env` are not changed. If a key occurs more than one time in the file,
/// the last value is used.
pub fn loadDotEnv(
    io: std.Io,
    gpa: Allocator,
    env: *Environ.Map,
    path: []const u8,
    diag: ?*Diagnostic,
) !void {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer gpa.free(content);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var entries = try parseDotEnv(arena.allocator(), content, diag);
    var it = entries.iterator();
    while (it.next()) |entry| {
        if (!env.contains(entry.key_ptr.*)) {
            try env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

/// Parses the content of a `.env` file. All memory is allocated with `arena`.
///
/// Supported syntax:
///   - `KEY=value`, with an optional `export ` prefix
///   - blank lines and `#` comment lines
///   - unquoted values, with an optional ` # comment` after the value
///   - `'single quoted'` values, which are used exactly as written
///   - `"double quoted"` values, with `\n`, `\r`, `\t`, `\"` and `\\` escapes
pub fn parseDotEnv(arena: Allocator, content: []const u8, diag: ?*Diagnostic) !std.StringArrayHashMapUnmanaged([]const u8) {
    var entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        errdefer if (diag) |d| {
            d.* = .{ .line = line_number };
        };

        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) {
            line = std.mem.trimStart(u8, line["export ".len..], " \t");
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidDotEnv;
        const key = std.mem.trimEnd(u8, line[0..eq], " \t");
        if (!isValidKey(key)) return error.InvalidDotEnv;

        const value = try parseValue(arena, std.mem.trimStart(u8, line[eq + 1 ..], " \t"));
        try entries.put(arena, key, value);
    }
    return entries;
}

fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or std.ascii.isDigit(key[0])) return false;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn parseValue(arena: Allocator, text: []const u8) ![]const u8 {
    if (text.len == 0) return "";

    switch (text[0]) {
        '\'' => {
            const end = std.mem.indexOfScalarPos(u8, text, 1, '\'') orelse return error.InvalidDotEnv;
            try expectEndOfLine(text[end + 1 ..]);
            return text[1..end];
        },
        '"' => {
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 1;
            while (i < text.len) : (i += 1) {
                switch (text[i]) {
                    '"' => {
                        try expectEndOfLine(text[i + 1 ..]);
                        return out.items;
                    },
                    '\\' => {
                        i += 1;
                        if (i == text.len) return error.InvalidDotEnv;
                        try out.append(arena, switch (text[i]) {
                            'n' => '\n',
                            'r' => '\r',
                            't' => '\t',
                            '"', '\\' => text[i],
                            else => return error.InvalidDotEnv,
                        });
                    },
                    else => |c| try out.append(arena, c),
                }
            }
            return error.InvalidDotEnv; // no closing quote
        },
        else => {
            // An unquoted value ends at a `#` that follows whitespace.
            var end = text.len;
            for (text[1..], 1..) |c, i| {
                if (c == '#' and (text[i - 1] == ' ' or text[i - 1] == '\t')) {
                    end = i;
                    break;
                }
            }
            return std.mem.trimEnd(u8, text[0..end], " \t");
        },
    }
}

/// After a closing quote, only whitespace or a comment is allowed.
fn expectEndOfLine(rest: []const u8) !void {
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    if (trimmed.len != 0 and trimmed[0] != '#') return error.InvalidDotEnv;
}

/// Fills a `T` from `env`. Each field reads the environment variable with the
/// upper-case field name. Supported field types: strings, bools, integers,
/// enums and optionals of these. Returned strings point into `env`.
pub fn fromEnv(comptime T: type, env: *const Environ.Map, diag: ?*Diagnostic) !T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs) |name, FieldType, attrs| {
        const key = comptime upperCase(name);
        if (env.get(&key)) |value| {
            @field(result, name) = parseField(FieldType, value) catch |err| {
                if (diag) |d| d.* = .{ .key = &key, .value = value };
                return err;
            };
        } else if (comptime attrs.defaultValue(FieldType)) |default| {
            @field(result, name) = default;
        } else {
            if (diag) |d| d.* = .{ .key = &key };
            return error.MissingEnvVar;
        }
    }
    return result;
}

fn parseField(comptime T: type, value: []const u8) !T {
    if (T == []const u8) return value;
    switch (@typeInfo(T)) {
        .bool => {
            const truthy = [_][]const u8{ "1", "true", "yes", "on" };
            const falsy = [_][]const u8{ "0", "false", "no", "off" };
            for (truthy) |s| if (std.ascii.eqlIgnoreCase(value, s)) return true;
            for (falsy) |s| if (std.ascii.eqlIgnoreCase(value, s)) return false;
            return error.InvalidEnvVar;
        },
        .int => return std.fmt.parseInt(T, value, 10) catch error.InvalidEnvVar,
        .@"enum" => return std.meta.stringToEnum(T, value) orelse error.InvalidEnvVar,
        .optional => |opt| return try parseField(opt.child, value),
        else => @compileError("unsupported config field type: " ++ @typeName(T)),
    }
}

fn upperCase(comptime name: []const u8) [name.len]u8 {
    var buf: [name.len]u8 = undefined;
    _ = std.ascii.upperString(&buf, name);
    return buf;
}

const testing = std.testing;

test parseDotEnv {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const content =
        \\# comment
        \\
        \\PLAIN=value
        \\export EXPORTED=yes
        \\  SPACED  =  padded value
        \\TRAILING=value # a comment
        \\HASH=a#b
        \\EMPTY=
        \\SINGLE='raw \n # kept'
        \\DOUBLE="line\nnext \"quoted\" \\"  # comment
        \\EQUALS=a=b=c
        \\PLAIN=last wins
        \\CRLF=value
    ++ "\r\n";

    var entries = try parseDotEnv(arena.allocator(), content, null);
    try testing.expectEqualStrings("last wins", entries.get("PLAIN").?);
    try testing.expectEqualStrings("yes", entries.get("EXPORTED").?);
    try testing.expectEqualStrings("padded value", entries.get("SPACED").?);
    try testing.expectEqualStrings("value", entries.get("TRAILING").?);
    try testing.expectEqualStrings("a#b", entries.get("HASH").?);
    try testing.expectEqualStrings("", entries.get("EMPTY").?);
    try testing.expectEqualStrings("raw \\n # kept", entries.get("SINGLE").?);
    try testing.expectEqualStrings("line\nnext \"quoted\" \\", entries.get("DOUBLE").?);
    try testing.expectEqualStrings("a=b=c", entries.get("EQUALS").?);
    try testing.expectEqualStrings("value", entries.get("CRLF").?);
    try testing.expectEqual(10, entries.count());
}

test "parseDotEnv: invalid lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const cases = [_][]const u8{
        "OK=1\nNO_EQUALS",
        "OK=1\n=value",
        "OK=1\n1KEY=value",
        "OK=1\nBAD-KEY=value",
        "OK=1\nKEY='unterminated",
        "OK=1\nKEY=\"unterminated",
        "OK=1\nKEY=\"bad escape \\q\"",
        "OK=1\nKEY='quoted' junk",
    };
    for (cases) |content| {
        var diag: Diagnostic = .{};
        try testing.expectError(error.InvalidDotEnv, parseDotEnv(arena.allocator(), content, &diag));
        try testing.expectEqual(2, diag.line);
    }
}

test fromEnv {
    const T = struct {
        name: []const u8,
        port: u16 = 8080,
        debug: bool = false,
        level: enum { low, high } = .low,
        limit: ?u32 = null,
    };

    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();

    var diag: Diagnostic = .{};
    try testing.expectError(error.MissingEnvVar, fromEnv(T, &env, &diag));
    try testing.expectEqualStrings("NAME", diag.key);

    try env.put("NAME", "app");
    const defaults = try fromEnv(T, &env, null);
    try testing.expectEqualStrings("app", defaults.name);
    try testing.expectEqual(8080, defaults.port);
    try testing.expectEqual(false, defaults.debug);
    try testing.expectEqual(.low, defaults.level);
    try testing.expectEqual(null, defaults.limit);

    try env.put("PORT", "9000");
    try env.put("DEBUG", "Yes");
    try env.put("LEVEL", "high");
    try env.put("LIMIT", "5");
    const set = try fromEnv(T, &env, null);
    try testing.expectEqual(9000, set.port);
    try testing.expectEqual(true, set.debug);
    try testing.expectEqual(.high, set.level);
    try testing.expectEqual(5, set.limit);

    try env.put("PORT", "99999");
    try testing.expectError(error.InvalidEnvVar, fromEnv(T, &env, &diag));
    try testing.expectEqualStrings("PORT", diag.key);
    try testing.expectEqualStrings("99999", diag.value);
}

test loadDotEnv {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".env", .data = "FROM_FILE=file\nALREADY_SET=file\n" });

    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("ALREADY_SET", "env");

    // loadDotEnv reads relative to the working directory, so pass the full
    // path of the temporary file.
    const path = try tmp.dir.realPathFileAlloc(testing.io, ".env", testing.allocator);
    defer testing.allocator.free(path);
    try loadDotEnv(testing.io, testing.allocator, &env, path, null);

    try testing.expectEqualStrings("file", env.get("FROM_FILE").?);
    try testing.expectEqualStrings("env", env.get("ALREADY_SET").?);

    // A missing file is not an error.
    try loadDotEnv(testing.io, testing.allocator, &env, "does-not-exist.env", null);
}

/// Reports whether `prefix` can be a URL prefix: a path that starts and ends
/// with `/`, other than `/`, without characters that have a special meaning
/// in a URL or in a route (`:` for parameters, `*` for globs).
pub fn isValidUrlPrefix(prefix: []const u8) bool {
    if (prefix.len < 2 or prefix[0] != '/' or prefix[prefix.len - 1] != '/') return false;
    return std.mem.indexOfAny(u8, prefix, ":*?#\\ \t\r\n\x00") == null;
}

test isValidUrlPrefix {
    try std.testing.expect(isValidUrlPrefix("/static/"));
    try std.testing.expect(isValidUrlPrefix("/assets/v1/"));
    try std.testing.expect(!isValidUrlPrefix("/"));
    try std.testing.expect(!isValidUrlPrefix(""));
    try std.testing.expect(!isValidUrlPrefix("static/"));
    try std.testing.expect(!isValidUrlPrefix("/static"));
    try std.testing.expect(!isValidUrlPrefix("/:id/"));
    try std.testing.expect(!isValidUrlPrefix("/a*/"));
    try std.testing.expect(!isValidUrlPrefix("/a?b/"));
    try std.testing.expect(!isValidUrlPrefix("https://cdn.example.com/static/"));
}
