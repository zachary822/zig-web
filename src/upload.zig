//! Receiving uploaded files: a file field of a `multipart/form-data` POST,
//! checked and processed. Nothing here keeps the file or uses the database:
//! the route decides what to do with the result. The uploads library
//! (`uploads.zig`) keeps the files; a different route can use the result and
//! discard it.
//!
//! A processor is a type with these declarations (`image.Processor` is one):
//!
//!     pub const noun: []const u8;         // for messages, for example "image"
//!     pub const description: []const u8;  // "a JPEG, PNG, GIF or WebP image"
//!     pub const Result: type;
//!     pub fn detect(data: []const u8) bool;
//!     pub fn process(arena: Allocator, data: []const u8) error{ InvalidFile, OutOfMemory }!Result;
//!
//! A route uses it like this:
//!
//!     const outcome = try upload.receive(image.Processor, req, res.arena, .{ .max_size = 2 * 1024 * 1024 });
//!     const file = switch (outcome) {
//!         .ok => |file| file,
//!         .rejected => |rejection| return upload.refuse(req, res, "/back", rejection),
//!     };
//!     // file.original_name, file.result (an `image.Cleaned`)
//!
//! Each route with uploads needs two more things: its `max_size` must be at
//! most the body limit of httpz (see `requestSize` in main.zig), and nginx
//! needs a location for the route with `client_max_body_size`
//! (deploy/nginx/zig_web.conf).

const std = @import("std");
const httpz = @import("httpz");
const flash = @import("flash.zig");

const Allocator = std.mem.Allocator;

/// The rules of one upload route.
pub const Spec = struct {
    /// The name of the form field with the file.
    field: []const u8 = "file",
    /// The largest file, in bytes.
    max_size: usize,
};

/// A file from the form, before a processor.
pub const File = struct {
    /// The name of the file on the computer of the user (`originalName`).
    original_name: []const u8,
    data: []const u8,
};

/// A file that a processor accepted.
pub fn Received(comptime Processor: type) type {
    return struct {
        original_name: []const u8,
        result: Processor.Result,
    };
}

/// Why a file is not accepted: an HTTP status and a message for the user.
pub const Rejection = struct {
    status: u16,
    message: []const u8,
};

pub fn Outcome(comptime T: type) type {
    return union(enum) {
        ok: T,
        rejected: Rejection,
    };
}

/// The bytes of the form around the file (boundaries, the CSRF token).
pub const form_overhead = 64 * 1024;

/// The request body for a file of at most `max_size` bytes.
pub fn requestSize(max_size: usize) usize {
    return max_size + form_overhead;
}

/// Reads the file field of `req`. Rejects a request without the file, an
/// empty file and a file larger than `spec.max_size`.
pub fn read(req: *httpz.Request, arena: Allocator, spec: Spec) !Outcome(File) {
    const form = req.multiFormData() catch return reject(400, "Choose a file.");
    const field = form.get(spec.field) orelse return reject(400, "Choose a file.");
    const filename = field.filename orelse return reject(400, "Choose a file.");
    if (field.value.len == 0) return reject(400, "The file is empty.");
    if (field.value.len > spec.max_size) return .{ .rejected = try tooLarge(arena, "file", spec.max_size) };
    return .{ .ok = .{ .original_name = try originalName(arena, filename), .data = field.value } };
}

/// Gives `data` to the processor. Rejects a file that it does not detect
/// (415) or cannot process (400).
pub fn process(comptime Processor: type, arena: Allocator, data: []const u8) !Outcome(Processor.Result) {
    comptime checkProcessor(Processor);
    if (!Processor.detect(data)) return .{ .rejected = unsupported(Processor.description) };
    const result = Processor.process(arena, data) catch |err| switch (err) {
        error.InvalidFile => return .{ .rejected = try invalid(arena, Processor.noun) },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .ok = result };
}

/// `read`, then `process`.
pub fn receive(comptime Processor: type, req: *httpz.Request, arena: Allocator, spec: Spec) !Outcome(Received(Processor)) {
    const file = switch (try read(req, arena, spec)) {
        .ok => |file| file,
        .rejected => |rejection| return .{ .rejected = rejection },
    };
    const result = switch (try process(Processor, arena, file.data)) {
        .ok => |result| result,
        .rejected => |rejection| return .{ .rejected = rejection },
    };
    return .{ .ok = .{ .original_name = file.original_name, .result = result } };
}

fn reject(status: u16, comptime message: []const u8) Outcome(File) {
    return .{ .rejected = .{ .status = status, .message = message } };
}

/// The rejection of a file that no processor of the route accepts.
/// `accepted`: the files that the route accepts, for example
/// `a JPEG, PNG, GIF or WebP image`.
pub fn unsupported(comptime accepted: []const u8) Rejection {
    return .{ .status = 415, .message = "This type of file cannot be uploaded. Upload " ++ accepted ++ "." };
}

/// The rejection of a `noun` (for example `image`) larger than `max_size`.
pub fn tooLarge(arena: Allocator, noun: []const u8, max_size: usize) !Rejection {
    return .{ .status = 413, .message = try std.fmt.allocPrint(arena, "The {s} must have at most {s}.", .{ noun, try sizeText(arena, max_size) }) };
}

/// The rejection of a file that is damaged or not complete.
pub fn invalid(arena: Allocator, noun: []const u8) !Rejection {
    return .{ .status = 400, .message = try std.fmt.allocPrint(arena, "The {s} is damaged or not complete.", .{noun}) };
}

/// Reports whether the request asks for JSON (a `fetch`, for example a script
/// that uploads files).
pub fn wantsJson(req: *httpz.Request) bool {
    const accept = req.header("accept") orelse return false;
    return std.mem.indexOf(u8, accept, "application/json") != null;
}

/// Answers a rejected upload: `{"error": message}` with the status for a
/// request that wants JSON; else a flash message and a redirect to
/// `redirect_to` (the route must use `Session.Middleware`).
pub fn refuse(req: *httpz.Request, res: *httpz.Response, redirect_to: []const u8, rejection: Rejection) !void {
    if (wantsJson(req)) {
        res.status = rejection.status;
        return res.json(.{ .@"error" = rejection.message }, .{});
    }
    try flash.add(req, .@"error", rejection.message);
    res.status = 303;
    res.header("Location", redirect_to);
}

fn checkProcessor(comptime P: type) void {
    for ([_][]const u8{ "noun", "description", "Result", "detect", "process" }) |decl| {
        if (!@hasDecl(P, decl)) @compileError(@typeName(P) ++ " is not an upload processor: it has no `" ++ decl ++ "` (see upload.zig)");
    }
}

/// In characters, as the `upload.original_name` column of the library.
pub const max_original_name_len = 255;

/// The name of the file as the browser sent it, to show it: without a
/// directory and control characters, and at most `max_original_name_len`
/// characters. `file` when nothing is left, or when it is not valid UTF-8.
pub fn originalName(arena: Allocator, filename: []const u8) ![]const u8 {
    const base = filename[if (std.mem.lastIndexOfAny(u8, filename, "/\\")) |i| i + 1 else 0..];
    const view = std.unicode.Utf8View.init(base) catch return "file";
    var it = view.iterator();
    var out: std.ArrayList(u8) = .empty;
    var chars: usize = 0;
    while (it.nextCodepointSlice()) |char| {
        if (chars == max_original_name_len) break;
        if (char.len == 1 and (char[0] < 0x20 or char[0] == 0x7F)) continue;
        try out.appendSlice(arena, char);
        chars += 1;
    }
    const name = std.mem.trim(u8, out.items, " ");
    return if (name.len == 0) "file" else name;
}

/// A file size for people, for example `830 bytes`, `45 KiB` or `2.4 MiB`.
pub fn sizeText(arena: Allocator, n: u64) ![]const u8 {
    if (n < 1024) return std.fmt.allocPrint(arena, "{d} bytes", .{n});
    if (n < 1024 * 1024) return std.fmt.allocPrint(arena, "{d} KiB", .{(n + 512) / 1024});
    const mib = @as(f64, @floatFromInt(n)) / (1024 * 1024);
    return std.fmt.allocPrint(arena, "{d:.1} MiB", .{mib});
}

/// A processor for the tests, as a route that uses the file and discards
/// it: plain text, as its number of lines.
const LineCounter = struct {
    pub const noun = "text file";
    pub const description = "a UTF-8 text file";
    pub const Result = struct { lines: usize };

    pub fn detect(data: []const u8) bool {
        return std.unicode.utf8ValidateSlice(data) and std.mem.indexOfScalar(u8, data, 0) == null;
    }

    pub fn process(_: Allocator, data: []const u8) error{ InvalidFile, OutOfMemory }!Result {
        if (!std.mem.endsWith(u8, data, "\n")) return error.InvalidFile;
        return .{ .lines = std.mem.count(u8, data, "\n") };
    }
};

fn multipart(ht: *httpz.testing.Testing, comptime field: []const u8, comptime filename: []const u8, comptime data: []const u8) void {
    ht.header("content-type", "multipart/form-data; boundary=XyZ");
    ht.body("--XyZ\r\nContent-Disposition: form-data; name=\"" ++ field ++ "\"; filename=\"" ++ filename ++ "\"\r\n\r\n" ++ data ++ "\r\n--XyZ--\r\n");
}

test "receive: a route that uses the file and discards it" {
    const Case = struct { field: []const u8, data: []const u8, lines: ?usize, status: u16 = 0 };
    inline for ([_]Case{
        .{ .field = "file", .data = "a\nb\n", .lines = 2 },
        .{ .field = "other", .data = "a\n", .lines = null, .status = 400 }, // no `file` field
        .{ .field = "file", .data = "a\x00b\n", .lines = null, .status = 415 }, // not text
        .{ .field = "file", .data = "no newline", .lines = null, .status = 400 }, // InvalidFile
        .{ .field = "file", .data = "0123456789\n", .lines = null, .status = 413 }, // more than 8 bytes
    }) |case| {
        var ht = httpz.testing.init(.{ .request = .{ .max_multiform_count = 4 } });
        defer ht.deinit();
        multipart(&ht, case.field, "C:\\notes\\list.txt", case.data);
        const max_size: usize = if (case.status == 413) 8 else 1024;
        switch (try receive(LineCounter, ht.req, ht.arena, .{ .max_size = max_size })) {
            .ok => |file| {
                try std.testing.expectEqual(case.lines.?, file.result.lines);
                try std.testing.expectEqualStrings("list.txt", file.original_name);
            },
            .rejected => |rejection| {
                try std.testing.expect(case.lines == null);
                try std.testing.expectEqual(case.status, rejection.status);
            },
        }
    }
}

test "rejection messages" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("This type of file cannot be uploaded. Upload a UTF-8 text file.", unsupported(LineCounter.description).message);
    try std.testing.expectEqualStrings("The image must have at most 10.0 MiB.", (try tooLarge(arena, "image", 10 * 1024 * 1024)).message);
    try std.testing.expectEqualStrings("The text file is damaged or not complete.", (try invalid(arena, "text file")).message);
}

test refuse {
    const rejection: Rejection = .{ .status = 415, .message = "No." };
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.header("accept", "application/json");
        try refuse(ht.req, ht.res, "/back", rejection);
        try ht.expectStatus(415);
        try ht.expectJson(.{ .@"error" = "No." });
    }
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        _ = try @import("middleware/session.zig").attachForTest(ht.req, null);
        try refuse(ht.req, ht.res, "/back", rejection);
        try ht.expectStatus(303);
        try ht.expectHeader("Location", "/back");
        try std.testing.expectEqualStrings("No.", (try flash.take(ht.req))[0].text);
    }
}

test originalName {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("photo.jpg", try originalName(arena, "photo.jpg"));
    try std.testing.expectEqualStrings("café.png", try originalName(arena, "C:\\Users\\ann\\café.png"));
    try std.testing.expectEqualStrings("ab.gif", try originalName(arena, "/tmp/a\x00\nb.gif"));
    try std.testing.expectEqualStrings("file", try originalName(arena, "dir/"));
    try std.testing.expectEqualStrings("file", try originalName(arena, "\xff.jpg"));
    var accents: [300 * 2]u8 = undefined;
    for (0..300) |i| @memcpy(accents[i * 2 ..][0..2], "é");
    const long = try originalName(arena, &accents);
    try std.testing.expectEqual(max_original_name_len, try std.unicode.utf8CountCodepoints(long));
}

test sizeText {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("830 bytes", try sizeText(arena, 830));
    try std.testing.expectEqualStrings("45 KiB", try sizeText(arena, 45 * 1024 + 100));
    try std.testing.expectEqualStrings("2.4 MiB", try sizeText(arena, 2_500_000));
    try std.testing.expectEqualStrings("10.0 MiB", try sizeText(arena, 10 * 1024 * 1024));
}
