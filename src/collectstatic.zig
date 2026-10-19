//! Copies the static files to `STATIC_ROOT`, where nginx sends them. Run
//! with `zig build collectstatic [-- DIR]`; DIR replaces `STATIC_ROOT`.
//!
//! Each file in the static directory (`STATIC_DIR`, default `static`) is
//! copied two times: with its own name, and with the hashed name that
//! `{{#static}}` gives in release builds (see `Static.hashedName`), for
//! example `css/style.css` and `css/style.3f2a9c1b7d4e.css`. Hashed copies
//! from earlier runs stay, so pages that a browser or Cloudflare keeps can
//! still load their files. Remove old copies by hand if necessary.
//!
//! The server hashes the static directory at startup. Thus run collectstatic
//! after each change to the static files, and then restart the server.
//!
//! Configuration comes from `.env` and the environment, like the server.

const std = @import("std");
const config = @import("config.zig");
const Static = @import("static.zig");

const Settings = struct {
    static_dir: []const u8 = "static",
    static_root: ?[]const u8 = null,
};

const usage =
    \\Usage: zig build collectstatic [-- DIR]
    \\
    \\Copies the files in STATIC_DIR (default: static) to DIR, or to
    \\STATIC_ROOT when DIR is not given, with and without a content hash in
    \\the name.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buf: [4096]u8 = undefined;
    var out_file: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 2) {
        try out.writeAll(usage);
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
    const root = if (args.len == 2) args[1] else settings.static_root orelse {
        std.log.err("STATIC_ROOT is not set", .{});
        try out.writeAll(usage);
        return 2;
    };

    var src = std.Io.Dir.cwd().openDir(io, settings.static_dir, .{ .iterate = true }) catch |err| {
        std.log.err("cannot open {s}/: {t}", .{ settings.static_dir, err });
        return 1;
    };
    defer src.close(io);
    var dest = std.Io.Dir.cwd().createDirPathOpen(io, root, .{}) catch |err| {
        std.log.err("cannot open {s}/: {t}", .{ root, err });
        return 1;
    };
    defer dest.close(io);

    const stats = collect(io, gpa, src, dest, out) catch |err| {
        std.log.err("cannot copy static files to {s}/: {t}", .{ root, err });
        return 1;
    };
    try out.print("{d} files copied to {s}/, {d} new hashed names\n", .{ stats.files, root, stats.new });
    return 0;
}

const Stats = struct {
    files: usize = 0,
    /// Hashed names that were not in `dest` before.
    new: usize = 0,
};

/// Copies each file in `src` to `dest`, with its own name and with its hashed
/// name, and prints each new hashed name to `out`. A hashed name that is
/// already in `dest` has the same content, so it is not copied again. The
/// copies replace the destination atomically, so nginx never sends a part of
/// a file.
fn collect(io: std.Io, gpa: std.mem.Allocator, src: std.Io.Dir, dest: std.Io.Dir, out: *std.Io.Writer) !Stats {
    var stats: Stats = .{};
    var walker = try src.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const sub_path = try gpa.dupe(u8, entry.path);
        defer gpa.free(sub_path);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, sub_path, std.fs.path.sep, '/');

        const body = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(Static.max_file_size));
        defer gpa.free(body);
        const name = try Static.hashedName(gpa, sub_path, body);
        defer gpa.free(name);

        try src.copyFile(entry.path, dest, sub_path, io, .{ .make_path = true, .replace = true });
        if (dest.access(io, name, .{})) {} else |err| switch (err) {
            error.FileNotFound => {
                try src.copyFile(entry.path, dest, name, io, .{ .make_path = true, .replace = true });
                try out.print("  {s}\n", .{name});
                stats.new += 1;
            },
            else => return err,
        }
        stats.files += 1;
    }
    return stats;
}

test collect {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/css");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/css/style.css", .data = "hello" });
    var src = try tmp.dir.openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var dest = try tmp.dir.createDirPathOpen(io, "dest", .{});
    defer dest.close(io);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    const first = try collect(io, gpa, src, dest, &discard.writer);
    try std.testing.expectEqual(Stats{ .files = 1, .new = 1 }, first);
    const second = try collect(io, gpa, src, dest, &discard.writer);
    try std.testing.expectEqual(Stats{ .files = 1, .new = 0 }, second);

    // A change gives a new hashed name, and the old one stays.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/css/style.css", .data = "hello, world" });
    const third = try collect(io, gpa, src, dest, &discard.writer);
    try std.testing.expectEqual(Stats{ .files = 1, .new = 1 }, third);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try dest.readFile(io, "css/style.2cf24dba5fb0.css", &buf));
    try std.testing.expectEqualStrings("hello, world", try dest.readFile(io, "css/style.css", &buf));
}
