//! Cross-site request forgery (CSRF) protection, with two independent layers
//! for unsafe methods (everything except GET, HEAD, OPTIONS and TRACE):
//!
//! 1. Fetch Metadata: the browser's `Sec-Fetch-Site` header must be
//!    `same-origin` or `none`. Browsers that do not send it must send an
//!    `Origin` that matches the `Host`. Requests with neither header (not
//!    from a browser) pass this layer.
//! 2. Signed double-submit token: the CSRF cookie (`cookieName`) holds a random
//!    value and its HMAC (made with `SECRET_KEY`). The request must send the
//!    same token in the `X-CSRF-Token` header or in a `csrf_token` form
//!    field (application/x-www-form-urlencoded or multipart/form-data).
//!
//! Pages get the token with `Csrf.token` and put it in the page:
//! `templates/base.mustache` gives it to htmx with `hx-headers`, and forms
//! include `{{>csrf_field}}`.

const std = @import("std");
const httpz = @import("httpz");
const Escaped = @import("RequestLogger.zig").Escaped;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const base64 = std.base64.url_safe_no_pad;

const log = std.log.scoped(.csrf);

const Csrf = @This();

/// The name of the cookie. As `Session.cookieName`: with `Secure`, the
/// `__Host-` prefix, so a different subdomain cannot set the cookie.
pub fn cookieName(secure_cookie: bool) []const u8 {
    return if (secure_cookie) "__Host-csrf_token" else "csrf_token";
}
pub const header_name = "x-csrf-token";
pub const form_field = "csrf_token";

const random_len = 32;
const encoded_random_len = base64.Encoder.calcSize(random_len);
const encoded_mac_len = base64.Encoder.calcSize(HmacSha256.mac_length);
/// `<random>.<mac>`, both base64url without padding.
pub const token_len = encoded_random_len + 1 + encoded_mac_len;

io: std.Io,
/// HMAC key. Tokens are valid as long as the key stays the same.
key: [HmacSha256.key_length]u8,
/// Set the `Secure` attribute on the cookie (HTTPS only).
secure_cookie: bool,
/// `cookieName(secure_cookie)`.
cookie_name: []const u8,

/// `secret` is the `SECRET_KEY` setting (at least 32 bytes). Without it, a
/// random key is used, so tokens become invalid when the server restarts.
pub fn init(io: std.Io, secret: ?[]const u8, secure_cookie: bool) !Csrf {
    var self: Csrf = .{ .io = io, .key = undefined, .secure_cookie = secure_cookie, .cookie_name = cookieName(secure_cookie) };
    if (secret) |s| {
        if (s.len < 32) return error.SecretKeyTooShort;
        // Derive a fixed-size key, and keep CSRF tokens separate from other
        // uses of the same secret.
        HmacSha256.create(&self.key, "zig-web csrf", s);
    } else {
        try io.randomSecure(&self.key);
    }
    return self;
}

/// Returns the CSRF token for this browser, for a page that sends unsafe
/// requests. Uses the token from the cookie when it is valid; otherwise makes
/// a new one and sets the cookie.
pub fn token(self: *const Csrf, req: *httpz.Request, res: *httpz.Response) ![]const u8 {
    if (req.cookies().get(self.cookie_name)) |existing| {
        if (self.isValid(existing)) return existing;
    }

    const new = try res.arena.alloc(u8, token_len);
    var random: [random_len]u8 = undefined;
    self.io.random(&random);
    self.sign(&random, new[0..token_len]);
    try res.setCookie(self.cookie_name, new, .{
        .path = "/",
        .max_age = 365 * 24 * 60 * 60,
        .http_only = true,
        .secure = self.secure_cookie,
        .same_site = .lax,
    });
    return new;
}

fn sign(self: *const Csrf, random: *const [random_len]u8, out: *[token_len]u8) void {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, random, &self.key);
    _ = base64.Encoder.encode(out[0..encoded_random_len], random);
    out[encoded_random_len] = '.';
    _ = base64.Encoder.encode(out[encoded_random_len + 1 ..], &mac);
}

/// Reports whether `value` is a token that this server made.
fn isValid(self: *const Csrf, value: []const u8) bool {
    if (value.len != token_len or value[encoded_random_len] != '.') return false;
    var random: [random_len]u8 = undefined;
    base64.Decoder.decode(&random, value[0..encoded_random_len]) catch return false;
    var expected: [token_len]u8 = undefined;
    self.sign(&random, &expected);
    return std.crypto.timing_safe.eql([token_len]u8, expected, value[0..token_len].*);
}

/// The reason a request was rejected, for the log.
const Rejection = enum { cross_site, origin_mismatch, missing_cookie, invalid_cookie, missing_token, token_mismatch };

/// Checks an unsafe request. Returns null when it is allowed.
fn check(self: *const Csrf, req: *httpz.Request) !?Rejection {
    if (req.header("sec-fetch-site")) |site| {
        if (!std.mem.eql(u8, site, "same-origin") and !std.mem.eql(u8, site, "none")) return .cross_site;
    } else if (req.header("origin")) |origin| {
        if (!originMatchesHost(origin, req.header("host") orelse "")) return .origin_mismatch;
    }

    const cookie = req.cookies().get(self.cookie_name) orelse return .missing_cookie;
    if (!self.isValid(cookie)) return .invalid_cookie;

    const submitted = req.header(header_name) orelse try formToken(req) orelse return .missing_token;

    if (submitted.len != token_len) return .token_mismatch;
    if (!std.crypto.timing_safe.eql([token_len]u8, cookie[0..token_len].*, submitted[0..token_len].*)) return .token_mismatch;
    return null;
}

/// The `csrf_token` field of a form post. httpz parses the body one time,
/// with the first of `formData` and `multiFormData` that reads it, so a
/// multipart form (a file upload) must be read with `multiFormData`: then
/// the action can read its fields too. A multipart body that is not valid
/// has no token.
fn formToken(req: *httpz.Request) !?[]const u8 {
    const content_type = req.header("content-type") orelse "";
    if (std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) {
        const form = req.multiFormData() catch return null;
        return if (form.get(form_field)) |field| field.value else null;
    }
    const form = try req.formData();
    return form.get(form_field);
}

/// Compares the host and port of `origin` (for example
/// `https://app.example.com`) with the `Host` header.
fn originMatchesHost(origin: []const u8, host: []const u8) bool {
    const sep = std.mem.indexOf(u8, origin, "://") orelse return false;
    return host.len > 0 and std.ascii.eqlIgnoreCase(origin[sep + 3 ..], host);
}

/// GET, HEAD, OPTIONS and TRACE do not change state, so they are not checked.
/// TRACE has no value in httpz's method enum; it arrives as `.OTHER`.
fn isSafeMethod(req: *const httpz.Request) bool {
    return switch (req.method) {
        .GET, .HEAD, .OPTIONS => true,
        .OTHER => std.ascii.eqlIgnoreCase(req.method_string, "TRACE"),
        else => false,
    };
}

/// httpz middleware that rejects unsafe requests that fail the check with
/// 403 Forbidden.
pub const Middleware = struct {
    csrf: *const Csrf,

    pub const Config = struct {
        csrf: *const Csrf,
    };

    pub fn init(config: Config) !Middleware {
        return .{ .csrf = config.csrf };
    }

    pub fn execute(self: *const Middleware, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
        if (!isSafeMethod(req)) {
            if (try self.csrf.check(req)) |reason| {
                log.warn("rejected {t} {f}: {t}", .{ req.method, Escaped{ .text = req.url.path }, reason });
                res.status = 403;
                res.content_type = .TEXT;
                res.body = "Forbidden (CSRF check failed)";
                return;
            }
        }
        return executor.next();
    }
};

test "token round trip" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = try Csrf.init(io, "0123456789abcdef0123456789abcdef", false);
    const b = try Csrf.init(io, "fedcba9876543210fedcba9876543210", false);

    var random: [random_len]u8 = @splat(7);
    var tok: [token_len]u8 = undefined;
    a.sign(&random, &tok);

    try std.testing.expect(a.isValid(&tok));
    try std.testing.expect(!b.isValid(&tok)); // other key
    var tampered = tok;
    tampered[0] ^= 1;
    try std.testing.expect(!a.isValid(&tampered));
    try std.testing.expect(!a.isValid(tok[0 .. token_len - 1]));
    try std.testing.expect(!a.isValid(""));
    try std.testing.expectError(error.SecretKeyTooShort, Csrf.init(io, "short", false));
}

test "token in a multipart form" {
    const csrf = try Csrf.init(std.testing.io, "0123456789abcdef0123456789abcdef", false);
    var random: [random_len]u8 = @splat(3);
    var tok: [token_len]u8 = undefined;
    csrf.sign(&random, &tok);
    const cookie = "csrf_token=" ++ tok;

    const Case = struct { field: []const u8, expected: ?Rejection };
    for ([_]Case{ .{ .field = &tok, .expected = null }, .{ .field = &@as([token_len]u8, @splat('x')), .expected = .token_mismatch } }) |case| {
        var ht = httpz.testing.init(.{ .request = .{ .max_multiform_count = 4 } });
        defer ht.deinit();
        ht.header("cookie", cookie);
        ht.header("content-type", "multipart/form-data; boundary=XyZ");
        ht.body(try std.fmt.allocPrint(ht.arena, "--XyZ\r\nContent-Disposition: form-data; name=\"csrf_token\"\r\n\r\n{s}\r\n" ++
            "--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\n\r\nPNG\r\n--XyZ--\r\n", .{case.field}));
        try std.testing.expectEqual(case.expected, try csrf.check(ht.req));
        // The action can still read the file.
        try std.testing.expectEqualStrings("a.png", (try ht.req.multiFormData()).get("file").?.filename.?);
    }
}

test originMatchesHost {
    try std.testing.expect(originMatchesHost("https://app.example.com", "app.example.com"));
    try std.testing.expect(originMatchesHost("http://127.0.0.1:8080", "127.0.0.1:8080"));
    try std.testing.expect(originMatchesHost("https://App.Example.com", "app.example.com"));
    try std.testing.expect(!originMatchesHost("https://evil.com", "app.example.com"));
    try std.testing.expect(!originMatchesHost("https://app.example.com.evil.com", "app.example.com"));
    try std.testing.expect(!originMatchesHost("null", "app.example.com"));
    try std.testing.expect(!originMatchesHost("https://app.example.com", ""));
}
