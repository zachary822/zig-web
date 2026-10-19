//! Middleware that logs one line for each request, in the spirit of Django's
//! `django.server` logger:
//!
//!     "GET /login HTTP/1.1" 200 2026 341.0us
//!
//! Like Django, 2xx/3xx responses are logged at `info`, 4xx at `warn` and 5xx
//! at `err`. Errors returned by an action are logged and turned into a 500
//! response here, so the logged status and size match what the client gets.

const std = @import("std");
const httpz = @import("httpz");

const log = std.log.scoped(.server);

const RequestLogger = @This();

io: std.Io,

pub const Config = struct {
    io: std.Io,
};

pub fn init(config: Config) !RequestLogger {
    return .{ .io = config.io };
}

pub fn execute(self: *const RequestLogger, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    const start = std.Io.Timestamp.now(self.io, .awake);

    executor.next() catch |err| {
        log.err("Internal Server Error: {f}: {t}", .{ Escaped{ .text = req.url.path }, err });
        res.status = 500;
        res.content_type = .TEXT;
        res.clearWriter();
        res.body = "Internal Server Error";
    };

    const elapsed = start.untilNow(self.io, .awake);

    const method = if (req.method == .OTHER) req.method_string else @tagName(req.method);
    const protocol = switch (req.protocol) {
        .HTTP10 => "HTTP/1.0",
        .HTTP11 => "HTTP/1.1",
    };
    const fmt = "\"{f} {f} {s}\" {d} {f} {f}";
    const args = .{
        Escaped{ .text = method },
        Escaped{ .text = req.url.raw },
        protocol,
        res.status,
        Size{ .res = res },
        elapsed,
    };

    switch (res.status) {
        500...599 => log.err(fmt, args),
        400...499 => log.warn(fmt, args),
        else => log.info(fmt, args),
    }
}

/// Text from the client, with `"`, `\\` and non-printable bytes escaped, so
/// a request cannot make a log line ambiguous or send terminal escape codes.
/// Use it for all text from the client in the log.
pub const Escaped = struct {
    text: []const u8,

    pub fn format(self: Escaped, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.text) |c| switch (c) {
            '"', '\\' => try w.print("\\{c}", .{c}),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(c),
            else => try w.print("\\x{x:0>2}", .{c}),
        };
    }
};

test Escaped {
    var buf: [64]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{f}", .{Escaped{ .text = "/a\"b\\c\x1b[0m\xff" }});
    try std.testing.expectEqualStrings("/a\\\"b\\\\c\\x1b[0m\\xff", out);
}

/// Body size in bytes, or "-" when it is unknown (chunked/streamed responses).
const Size = struct {
    res: *httpz.Response,

    pub fn format(self: Size, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const res = self.res;
        if (res.chunked) return w.writeAll("-");
        const buffered = res.buffer.writer.buffered();
        try w.print("{d}", .{if (buffered.len > 0) buffered.len else res.body.len});
    }
};
