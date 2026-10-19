//! Middleware that adds security headers to all responses. HSTS is not set
//! here: it belongs where TLS ends (Cloudflare in production).

const std = @import("std");
const httpz = @import("httpz");

const SecurityHeaders = @This();

pub const Config = struct {};

/// Only same-origin scripts, styles, images and requests. htmx is
/// configured in templates/base.mustache to add no styles, and the
/// templates use no `hx-on` or `js:` values (htmx runs them with
/// `new Function`). Alpine.js uses `new Function` for its expressions, thus
/// `script-src` has 'unsafe-eval'. Alpine.js sets styles through the DOM
/// (`x-show`), which `style-src` does not block.
pub const csp: Csp = .{
    .default_src = &.{"'self'"},
    .script_src = &.{ "'self'", "'unsafe-eval'" },
    .style_src = &.{"'self'"},
    .img_src = &.{ "'self'", "data:" },
    .connect_src = &.{"'self'"},
    .font_src = &.{"'self'"},
    .object_src = &.{"'none'"},
    .base_uri = &.{"'self'"},
    .form_action = &.{"'self'"},
    .frame_ancestors = &.{"'none'"},
};
const csp_header = csp.header();

pub fn init(_: Config) !SecurityHeaders {
    return .{};
}

pub fn execute(_: *const SecurityHeaders, _: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    res.header("Content-Security-Policy", csp_header);
    res.header("X-Content-Type-Options", "nosniff");
    res.header("X-Frame-Options", "DENY");
    res.header("Referrer-Policy", "strict-origin-when-cross-origin");
    return executor.next();
}

/// A Content-Security-Policy. Each field is a directive, with the name in
/// snake_case (`script_src` is `script-src`). The value is the list of
/// sources, as they appear in the header: keywords keep their quotes
/// (`"'self'"`). A null directive is not in the header. An empty list gives
/// only the name, for directives without sources (`upgrade-insecure-requests`).
pub const Csp = struct {
    default_src: ?[]const []const u8 = null,
    script_src: ?[]const []const u8 = null,
    style_src: ?[]const []const u8 = null,
    img_src: ?[]const []const u8 = null,
    connect_src: ?[]const []const u8 = null,
    font_src: ?[]const []const u8 = null,
    object_src: ?[]const []const u8 = null,
    base_uri: ?[]const []const u8 = null,
    form_action: ?[]const []const u8 = null,
    frame_ancestors: ?[]const []const u8 = null,
    upgrade_insecure_requests: ?[]const []const u8 = null,

    /// The header value, built at compile time. The directives are in the
    /// order of the fields.
    pub fn header(comptime self: Csp) []const u8 {
        comptime {
            var out: []const u8 = "";
            for (std.meta.fieldNames(Csp)) |field_name| {
                const sources = @field(self, field_name) orelse continue;
                if (out.len > 0) out = out ++ "; ";
                var name = field_name[0..field_name.len].*;
                std.mem.replaceScalar(u8, &name, '_', '-');
                out = out ++ &name;
                for (sources) |source| out = out ++ " " ++ source;
            }
            const final = out[0..out.len].*;
            return &final;
        }
    }
};

test "Csp.header" {
    try std.testing.expectEqualStrings("", comptime (Csp{}).header());
    try std.testing.expectEqualStrings(
        "default-src 'self'; img-src 'self' data:; upgrade-insecure-requests",
        comptime (Csp{
            .upgrade_insecure_requests = &.{},
            .img_src = &.{ "'self'", "data:" },
            .default_src = &.{"'self'"},
        }).header(),
    );
    try std.testing.expectEqualStrings(
        "default-src 'self'; script-src 'self' 'unsafe-eval'; style-src 'self'; img-src 'self' data:; " ++
            "connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'self'; " ++
            "form-action 'self'; frame-ancestors 'none'",
        csp_header,
    );
}
