//! Static files: the URLs that templates get with `{{#static}}...{{/static}}`,
//! and a handler for the URL prefix (`/static/` by default, see
//! `Options.url_prefix`). The examples below use the default prefix.
//!
//! - Development (`reload = true`): `{{#static}}css/style.css{{/static}}`
//!   gives `/static/css/style.css`. The handler reads files from disk on
//!   every request, so edits show up without a restart.
//! - Production (`reload = false`): all files are hashed at startup, and
//!   `{{#static}}css/style.css{{/static}}` gives the hashed name, for example
//!   `/static/css/style.3f2a9c1b7d4e.css` (see `hashedName`). The
//!   collectstatic program (`src/collectstatic.zig`) copies the files to
//!   `STATIC_ROOT` with the same names, for nginx. When the content of a file
//!   changes, its URL changes too, so browsers and Cloudflare can keep each
//!   hashed file for a long time.
//!
//! Responses have an `ETag` (a hash of the content). A matching
//! `If-None-Match` gets `304 Not Modified`. Hashed names also get a long
//! `Cache-Control` (`immutable_cache_control`). Other names get no
//! `Cache-Control` header, like from nginx; a CDN in front (Cloudflare)
//! applies its own caching rules.

const std = @import("std");
const httpz = @import("httpz");
const mustache = @import("mustache");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Static = @This();

/// The default URL prefix that maps to the static directory.
pub const default_url_prefix = "/static/";

/// Largest file that is served.
pub const max_file_size = 16 * 1024 * 1024;

/// Number of hex digits of the content hash in a hashed name.
pub const hash_len = 12;

/// `Cache-Control` for hashed names. The content of a hashed name never
/// changes, so it can stay in caches for one year.
pub const immutable_cache_control = "public, max-age=31536000, immutable";

const File = struct {
    body: []const u8,
    /// Quoted, for example `"9f86d081884c7d65"`.
    etag: []const u8,
    content_type: httpz.ContentType,
    /// Set for hashed names.
    cache_control: ?[]const u8 = null,
};

pub const Options = struct {
    /// Read files from disk again for each request, and give templates
    /// names without a hash.
    reload: bool,
    /// Keep the files in memory for `register`. When false, only the hashed
    /// names are kept (nginx sends the files).
    serve: bool,
    /// The URL path that maps to the static directory. It must start and end
    /// with `/`, and it cannot be only `/`.
    url_prefix: []const u8 = default_url_prefix,
};

io: std.Io,
dir: std.Io.Dir,
/// Holds `files`, `hashed` and the contents.
arena: std.heap.ArenaAllocator,
/// Files by path relative to the static directory, with and without the
/// hash. Empty when `reload` is set or `serve` is not set.
files: std.StringHashMapUnmanaged(File),
/// Hashed names by path relative to the static directory. Empty when
/// `reload` is set.
hashed: std.StringHashMapUnmanaged([]const u8),
reload: bool,
/// `Options.url_prefix`.
url_prefix: []const u8,
/// `url_prefix` with `*` at the end, for the router. The router keeps
/// slices of it, so it is in `arena`.
route: []const u8,

/// Opens the static directory at `path`. Unless `reload` is set, all files
/// in it are hashed, and with `serve` also kept in memory.
pub fn init(io: std.Io, gpa: Allocator, path: []const u8, options: Options) !Static {
    if (!config.isValidUrlPrefix(options.url_prefix)) return error.InvalidUrlPrefix;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    errdefer dir.close(io);

    var self: Static = .{
        .io = io,
        .dir = dir,
        .arena = .init(gpa),
        .files = .empty,
        .hashed = .empty,
        .reload = options.reload,
        .url_prefix = undefined,
        .route = undefined,
    };
    errdefer self.arena.deinit();
    self.route = try std.mem.concat(self.arena.allocator(), u8, &.{ options.url_prefix, "*" });
    self.url_prefix = self.route[0 .. self.route.len - 1];
    if (!options.reload) try self.loadAll(gpa, options.serve);
    return self;
}

pub fn deinit(self: *Static) void {
    self.arena.deinit();
    self.dir.close(self.io);
}

/// Number of files that have a hashed name.
pub fn count(self: *const Static) usize {
    return self.hashed.count();
}

fn loadAll(self: *Static, gpa: Allocator, keep: bool) !void {
    const arena = self.arena.allocator();
    var walker = try self.dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(self.io)) |entry| {
        if (entry.kind != .file) continue;
        const sub_path = try arena.dupe(u8, entry.path);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, sub_path, std.fs.path.sep, '/');
        // Without `keep`, the content is necessary only for the hash.
        const body_gpa = if (keep) arena else gpa;
        const body = try entry.dir.readFileAlloc(self.io, entry.basename, body_gpa, .limited(max_file_size));
        defer if (!keep) gpa.free(body);

        const name = try hashedName(arena, sub_path, body);
        try self.hashed.put(arena, sub_path, name);
        if (keep) {
            const file = try makeFile(arena, sub_path, body);
            try self.files.put(arena, sub_path, file);
            var immutable = file;
            immutable.cache_control = immutable_cache_control;
            try self.files.put(arena, name, immutable);
        }
    }
}

/// Returns `sub_path` with the first 12 hex digits (`hash_len`) of the
/// SHA-256 of `body` before the extension, for example
/// `css/style.3f2a9c1b7d4e.css`. A name without an extension gets the hash
/// at the end. collectstatic and the `{{#static}}` lambda use this function,
/// so they always agree.
pub fn hashedName(gpa: Allocator, sub_path: []const u8, body: []const u8) Allocator.Error![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(body, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0 .. hash_len / 2], .lower);

    const base = if (std.mem.lastIndexOfScalar(u8, sub_path, '/')) |i| i + 1 else 0;
    // A dot at the start of the base name (`.htaccess`) is not an extension.
    const ext = if (std.mem.lastIndexOfScalar(u8, sub_path[base..], '.')) |i|
        if (i > 0) base + i else sub_path.len
    else
        sub_path.len;
    return std.fmt.allocPrint(gpa, "{s}.{s}{s}", .{ sub_path[0..ext], &hex, sub_path[ext..] });
}

test hashedName {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "css/style.css", "css/style.2cf24dba5fb0.css" },
        .{ "vendor/htmx-4.0.0.min.js", "vendor/htmx-4.0.0.min.2cf24dba5fb0.js" },
        .{ "LICENSE", "LICENSE.2cf24dba5fb0" },
        .{ "a.b/LICENSE", "a.b/LICENSE.2cf24dba5fb0" },
        .{ ".htaccess", ".htaccess.2cf24dba5fb0" },
    };
    for (cases) |case| {
        // The SHA-256 of "hello" starts with 2cf24dba5fb0.
        const got = try hashedName(gpa, case[0], "hello");
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

/// The value for `static` in the template data: the lambda for
/// `{{#static}}path{{/static}}`, which writes the URL of the file `path`
/// (relative to the static directory). Without `reload`, the URL has the
/// hashed name. For a file that does not exist, it logs a warning and writes
/// the URL without a hash.
pub fn lambda(self: *const Static) mustache.Value {
    return .{ .lambda = .{ .ctx = self, .func = writeUrl } };
}

test lambda {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "static/css");
    try tmp.dir.writeFile(io, .{ .sub_path = "static/css/style.css", .data = "hello" });
    const path = try tmp.dir.realPathFileAlloc(io, "static", gpa);
    defer gpa.free(path);

    const template = "{{#static}} css/style.css {{/static}} {{#static}}missing.js{{/static}}";
    const cases = [_]struct { Options, []const u8 }{
        .{ .{ .reload = true, .serve = true }, "/static/css/style.css /static/missing.js" },
        .{ .{ .reload = false, .serve = false }, "/static/css/style.2cf24dba5fb0.css /static/missing.js" },
        .{ .{ .reload = false, .serve = true }, "/static/css/style.2cf24dba5fb0.css /static/missing.js" },
        .{ .{ .reload = true, .serve = true, .url_prefix = "/assets/" }, "/assets/css/style.css /assets/missing.js" },
        .{ .{ .reload = false, .serve = false, .url_prefix = "/a/b/" }, "/a/b/css/style.2cf24dba5fb0.css /a/b/missing.js" },
    };
    for (cases) |case| {
        var static: Static = try .init(io, gpa, path, case[0]);
        defer static.deinit();
        const out = try mustache.renderAlloc(gpa, template, .{ .static = static.lambda() }, .{});
        defer gpa.free(out);
        try std.testing.expectEqualStrings(case[1], out);
        if (case[0].serve and !case[0].reload) {
            try std.testing.expectEqualStrings(immutable_cache_control, static.files.get("css/style.2cf24dba5fb0.css").?.cache_control.?);
            try std.testing.expectEqual(null, static.files.get("css/style.css").?.cache_control);
        }
    }
}

fn writeUrl(ctx: ?*const anyopaque, text: []const u8, out: *std.Io.Writer) std.Io.Writer.Error!void {
    const self: *const Static = @ptrCast(@alignCast(ctx.?));
    const sub_path = std.mem.trim(u8, text, " \t\r\n");
    try out.writeAll(self.url_prefix);
    if (self.reload) return out.writeAll(sub_path);
    const name = self.hashed.get(sub_path) orelse {
        std.log.warn("{{{{#static}}}}: no file {s} in the static directory", .{sub_path});
        return out.writeAll(sub_path);
    };
    try out.writeAll(name);
}

fn makeFile(arena: Allocator, sub_path: []const u8, body: []const u8) !File {
    return .{
        .body = body,
        .etag = try std.fmt.allocPrint(arena, "\"{x:0>16}\"", .{std.hash.Wyhash.hash(0, body)}),
        .content_type = switch (httpz.ContentType.forFile(sub_path)) {
            .UNKNOWN => .BINARY,
            else => |ct| ct,
        },
    };
}

/// Registers `GET` and `HEAD` routes for the URL prefix (`route`). `Handler` is the
/// handler type of the httpz server.
pub fn register(self: *const Static, comptime Handler: type, router: anytype) void {
    const action = struct {
        fn action(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
            return serve(req, res);
        }
    }.action;
    router.get(self.route, action, .{ .data = self });
    router.head(self.route, action, .{ .data = self });
}

fn serve(req: *httpz.Request, res: *httpz.Response) !void {
    const self: *const Static = @ptrCast(@alignCast(req.route_data.?));
    const raw_path = req.url.path[self.url_prefix.len..];
    const buf = try res.arena.alloc(u8, raw_path.len);
    const sub_path = normalizePath(buf, raw_path) orelse return notFound(res);

    const file = if (self.reload) blk: {
        const body = self.dir.readFileAlloc(self.io, sub_path, res.arena, .limited(max_file_size)) catch |err| switch (err) {
            error.FileNotFound, error.IsDir, error.NotDir => return notFound(res),
            else => return err,
        };
        break :blk try makeFile(res.arena, sub_path, body);
    } else self.files.get(sub_path) orelse return notFound(res);

    res.header("ETag", file.etag);
    if (file.cache_control) |cc| res.header("Cache-Control", cc);
    if (req.header("if-none-match")) |if_none_match| {
        if (etagMatches(if_none_match, file.etag)) {
            res.status = 304;
            return;
        }
    }
    res.content_type = file.content_type;
    res.body = file.body;
}

fn notFound(res: *httpz.Response) void {
    res.status = 404;
    res.body = "Not Found";
}

/// Reports whether an `If-None-Match` header value matches `etag`. The value
/// is `*` or a comma-separated list of tags, which can have a `W/` prefix.
fn etagMatches(if_none_match: []const u8, etag: []const u8) bool {
    if (std.mem.eql(u8, std.mem.trim(u8, if_none_match, " "), "*")) return true;
    var it = std.mem.splitScalar(u8, if_none_match, ',');
    while (it.next()) |raw| {
        var tag = std.mem.trim(u8, raw, " \t");
        if (std.mem.startsWith(u8, tag, "W/")) tag = tag[2..];
        if (std.mem.eql(u8, tag, etag)) return true;
    }
    return false;
}

test etagMatches {
    const etag = "\"abc123\"";
    try std.testing.expect(etagMatches("\"abc123\"", etag));
    try std.testing.expect(etagMatches("W/\"abc123\"", etag));
    try std.testing.expect(etagMatches("\"other\", \"abc123\"", etag));
    try std.testing.expect(etagMatches("*", etag));
    try std.testing.expect(!etagMatches("\"other\"", etag));
    try std.testing.expect(!etagMatches("abc123", etag));
    try std.testing.expect(!etagMatches("", etag));
}

/// Resolves `.`, `..` and empty segments in `path`, and writes the result
/// to `out`, which must be at least as long as `path`. Returns null if a `..`
/// would go above the static directory, if the result is empty (the directory
/// itself), or if `path` contains a backslash or a NUL byte.
fn normalizePath(out: []u8, path: []const u8) ?[]const u8 {
    std.debug.assert(out.len >= path.len);
    if (std.mem.indexOfAny(u8, path, "\\\x00") != null) return null;

    var len: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (len == 0) return null;
            len = std.mem.lastIndexOfScalar(u8, out[0..len], '/') orelse 0;
            continue;
        }
        if (len > 0) {
            out[len] = '/';
            len += 1;
        }
        @memcpy(out[len..][0..segment.len], segment);
        len += segment.len;
    }
    return if (len == 0) null else out[0..len];
}

test normalizePath {
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "css/style.css", "css/style.css" },
        .{ "app.js", "app.js" },
        .{ "css/./style.css", "css/style.css" },
        .{ "./css/style.css", "css/style.css" },
        .{ "css//style.css", "css/style.css" },
        .{ "/css/style.css", "css/style.css" },
        .{ "css/../app.js", "app.js" },
        .{ "vendor/x/../../css/style.css", "css/style.css" },
        .{ "css/style.css/.", "css/style.css" },
        .{ "a/b/c/../../d", "a/d" },
        .{ "...", "..." },
        .{ "..foo/bar", "..foo/bar" },
        .{ "", null },
        .{ ".", null },
        .{ "css/..", null },
        .{ "css/", "css" },
        .{ "..", null },
        .{ "../build.zig", null },
        .{ "css/../../build.zig", null },
        .{ "a/b/../../../build.zig", null },
        .{ "..\\build.zig", null },
        .{ "css/style.css\x00", null },
    };
    for (cases) |case| {
        var buf: [64]u8 = undefined;
        const got = normalizePath(&buf, case[0]);
        if (case[1]) |want| {
            try std.testing.expectEqualStrings(want, got orelse return error.TestUnexpectedNull);
        } else {
            try std.testing.expectEqual(null, got);
        }
    }
}
