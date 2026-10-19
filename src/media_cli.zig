//! The consistency of the uploads library (see `library.zig`), with
//! `zig build media -- COMMAND`: files in `MEDIA_DIR` without a row in the
//! `upload` table, and rows without a file.
//!
//! A file without a row occurs when the server stops between the write and
//! the insert of an upload, or when a delete cannot remove the file. A row
//! without a file occurs when someone removes a file by hand; restore the
//! file from a backup, or delete the row.
//!
//! Configuration comes from `.env` and the environment, like the server:
//! `DATABASE_URL` (required) and `MEDIA_DIR`.

const std = @import("std");
const config = @import("config.zig");
const db = @import("db.zig");
const media = @import("media.zig");

const Allocator = std.mem.Allocator;

const Settings = struct {
    database_url: ?[]const u8 = null,
    media_dir: []const u8 = "media",
};

const usage =
    \\Usage: zig build media -- COMMAND
    \\
    \\Commands:
    \\  check   Show the files without rows and the rows without files.
    \\  prune   Delete the files without rows that are older than one hour.
    \\          Newer files can be uploads in progress. Files with names that
    \\          the server does not make, and rows without files, are only
    \\          shown.
    \\
;

const Command = enum { check, prune };

/// Files without rows that are newer stay: the server writes the file
/// before the row.
const min_orphan_age_s = 60 * 60;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buf: [4096]u8 = undefined;
    var out_file: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const command = (if (args.len == 2) std.meta.stringToEnum(Command, args[1]) else null) orelse {
        try out.writeAll(usage);
        return 2;
    };

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
    const connection = db.parseUrl(arena, url) catch |err| {
        std.log.err("DATABASE_URL is not valid: {t}", .{err});
        return 1;
    };
    var dir = std.Io.Dir.cwd().openDir(io, settings.media_dir, .{ .iterate = true }) catch |err| {
        std.log.err("cannot open {s}/ (MEDIA_DIR): {t}", .{ settings.media_dir, err });
        return 1;
    };
    defer dir.close(io);

    db.libraryInit() catch |err| {
        std.log.err("cannot initialize the MariaDB library: {t}", .{err});
        return 1;
    };
    defer db.libraryEnd();
    const pool = db.Pool.create(gpa, io, .{
        .connection = connection,
        .pool_size = 1,
        .acquire_timeout_ms = 1000,
    }) catch |err| {
        std.log.err("cannot create the database pool: {t}", .{err});
        return 1;
    };
    defer pool.destroy();
    const conn = pool.acquire() catch |err| {
        std.log.err("cannot connect to database {s}@{s}/{s}: {t}", .{ connection.user, connection.socket orelse connection.host, connection.database, err });
        return 1;
    };
    defer conn.release();

    const rows = try conn.query(struct { name: []const u8 }, arena,
        \\SELECT name FROM upload
    , .{});
    const report = try examine(io, arena, dir, rows, std.Io.Timestamp.now(io, .real).toSeconds());
    try printReport(out, settings.media_dir, report);

    if (command == .prune) {
        var deleted: usize = 0;
        for (report.orphans) |orphan| {
            if (!orphan.deletable) continue;
            dir.deleteFile(io, orphan.name) catch |err| {
                std.log.err("cannot delete {s}: {t}", .{ orphan.name, err });
                continue;
            };
            deleted += 1;
        }
        try out.print("\nDeleted {d} file(s).\n", .{deleted});
    }
    return 0;
}

const Orphan = struct {
    name: []const u8,
    size: u64,
    age_s: i64,
    /// A name that the server makes (an upload, or the temporary file of a
    /// write that did not finish), and older than `min_orphan_age_s`.
    deletable: bool,
};

const Report = struct {
    /// The files without rows.
    orphans: []const Orphan,
    /// The rows without files.
    missing: []const []const u8,
    files: usize,
};

/// Compares the files in `dir` with the rows (the `name` column of
/// `upload`). `now_s` is the time in seconds, for the age of the files.
fn examine(io: std.Io, arena: Allocator, dir: std.Io.Dir, rows: anytype, now_s: i64) !Report {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (rows) |row| try names.put(arena, row.name, {});

    var orphans: std.ArrayList(Orphan) = .empty;
    var files: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        files += 1;
        if (names.contains(entry.name)) continue;
        const stat = try dir.statFile(io, entry.name, .{});
        const age_s = now_s - stat.mtime.toSeconds();
        const known = media.isStoredName(entry.name) or isTemporaryName(entry.name);
        try orphans.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .size = stat.size,
            .age_s = age_s,
            .deletable = known and age_s >= min_orphan_age_s,
        });
    }

    var missing: std.ArrayList([]const u8) = .empty;
    for (rows) |row| {
        dir.access(io, row.name, .{}) catch |err| switch (err) {
            error.FileNotFound => try missing.append(arena, row.name),
            else => return err,
        };
    }
    return .{ .orphans = orphans.items, .missing = missing.items, .files = files };
}

/// The name of the temporary file of `std.Io.Dir.createFileAtomic` when
/// the system has no unnamed temporary files: 16 hex digits.
fn isTemporaryName(name: []const u8) bool {
    if (name.len != 16) return false;
    for (name) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn printReport(out: *std.Io.Writer, media_dir: []const u8, report: Report) !void {
    try out.print("{d} file(s) in {s}/, {d} without a row, {d} row(s) without a file.\n", .{ report.files, media_dir, report.orphans.len, report.missing.len });
    if (report.orphans.len > 0) {
        try out.writeAll("\nFiles without rows:\n");
        for (report.orphans) |orphan| {
            const note = if (orphan.deletable) "" else if (orphan.age_s < min_orphan_age_s) "  (newer than one hour)" else "  (not a name of the server: delete it by hand)";
            try out.print("  {s}  {d} bytes, {d} min old{s}\n", .{ orphan.name, orphan.size, @divTrunc(orphan.age_s, 60), note });
        }
    }
    if (report.missing.len > 0) {
        try out.writeAll("\nRows without files (restore the file, or delete the row):\n");
        for (report.missing) |name| try out.print("  {s}\n", .{name});
    }
}

test examine {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const kept = "0123456789abcdef01234567.png";
    const orphan = "fedcba9876543210fedcba98.jpg";
    try tmp.dir.writeFile(io, .{ .sub_path = kept, .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = orphan, .data = "bb" });
    try tmp.dir.writeFile(io, .{ .sub_path = "0123456789abcdef", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "" });
    const rows = [_]struct { name: []const u8 }{ .{ .name = kept }, .{ .name = "aaaaaaaaaaaaaaaaaaaaaaaa.gif" } };

    // Now: the new orphans stay.
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const fresh = try examine(io, arena_state.allocator(), tmp.dir, &rows, now);
    try std.testing.expectEqual(4, fresh.files);
    try std.testing.expectEqual(3, fresh.orphans.len);
    for (fresh.orphans) |o| try std.testing.expect(!o.deletable);
    try std.testing.expectEqual(1, fresh.missing.len);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaa.gif", fresh.missing[0]);

    // Two hours later: the server's names can go, `notes.txt` stays.
    const later = try examine(io, arena_state.allocator(), tmp.dir, &rows, now + 2 * 60 * 60);
    for (later.orphans) |o| {
        try std.testing.expectEqual(!std.mem.eql(u8, o.name, "notes.txt"), o.deletable);
    }
}
