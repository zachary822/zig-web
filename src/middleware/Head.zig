//! Middleware that removes the body of responses to `HEAD` requests, but
//! keeps the `Content-Length` of the `GET` response, as HTTP requires.

const std = @import("std");
const httpz = @import("httpz");

const Head = @This();

pub const Config = struct {};

pub fn init(_: Config) !Head {
    return .{};
}

pub fn execute(_: *const Head, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    try executor.next();
    if (req.method != .HEAD or res.chunked) return;

    const buffered = res.buffer.writer.buffered();
    const len = if (buffered.len > 0) buffered.len else res.body.len;
    if (len == 0) return;
    res.header("Content-Length", try std.fmt.allocPrint(res.arena, "{d}", .{len}));
    res.clearWriter();
    res.body = "";
}
