//! Database migrations, run with `zig build migrate [-- COMMAND]`.
//!
//! Migrations are SQL files in `migrations/` (or `MIGRATIONS_DIR`), named
//! `NNNN_description.sql`, and are applied in order of NNNN. They are read at
//! runtime, so a deployment only needs the files next to the binary.
//!
//! The table `schema_migrations` records each applied migration with a
//! SHA-256 checksum of its file. If an applied file changes later, `up`
//! stops: write a new migration instead of editing an applied one.
//!
//! MariaDB commits CREATE, ALTER and DROP immediately, so a migration that
//! fails in its second statement keeps its first one. Keep one schema change
//! in each file.
//!
//! Configuration comes from `.env` and the environment, like the server:
//! `DATABASE_URL` (required) and `MIGRATIONS_DIR` (default `migrations`).

const std = @import("std");
const config = @import("config.zig");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Settings = struct {
    database_url: ?[]const u8 = null,
    migrations_dir: []const u8 = "migrations",
};

const usage =
    \\Usage: zig build migrate [-- COMMAND]
    \\
    \\Commands:
    \\  up          Apply all pending migrations (default).
    \\  status      Show applied, pending and changed migrations.
    \\  new NAME    Create migrations/NNNN_NAME.sql (NAME: a-z, 0-9, _).
    \\
;

/// Name of the advisory lock that keeps two runs from applying the same
/// migration at the same time.
const lock_name = "zig_web_migrate";

const create_table =
    \\CREATE TABLE IF NOT EXISTS schema_migrations (
    \\    version BIGINT UNSIGNED NOT NULL PRIMARY KEY,
    \\    name VARCHAR(255) NOT NULL,
    \\    checksum CHAR(64) NOT NULL,
    \\    applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    \\)
;

const table_exists =
    \\SELECT COUNT(*) FROM information_schema.tables
    \\WHERE table_schema = DATABASE() AND table_name = 'schema_migrations'
;

/// A migration file on disk.
const Migration = struct {
    version: u64,
    /// File name, for example `0001_create_posts.sql`.
    name: []const u8,
    content: []const u8,
    /// SHA-256 of `content`, as lowercase hex.
    checksum: [64]u8,
};

/// A row of `schema_migrations`.
const Applied = struct {
    version: u64,
    name: []const u8,
    checksum: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buf: [4096]u8 = undefined;
    var out_file: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const command = if (args.len > 1) args[1] else "up";

    var diag: config.Diagnostic = .{};
    config.loadDotEnv(io, gpa, init.environ_map, ".env", &diag) catch |err| {
        std.log.err(".env line {d}: {t}", .{ diag.line, err });
        return 1;
    };
    const settings = config.fromEnv(Settings, init.environ_map, &diag) catch |err| {
        std.log.err("{s}=\"{s}\": {t}", .{ diag.key, diag.value, err });
        return 1;
    };

    const migrations = readMigrations(io, arena, settings.migrations_dir) catch |err| {
        std.log.err("cannot read migrations from {s}/: {t}", .{ settings.migrations_dir, err });
        return 1;
    };

    if (std.mem.eql(u8, command, "new")) {
        if (args.len != 3) {
            try out.writeAll(usage);
            return 2;
        }
        return newMigration(io, out, settings.migrations_dir, migrations, args[2]);
    }
    const apply = if (std.mem.eql(u8, command, "up"))
        true
    else if (std.mem.eql(u8, command, "status"))
        false
    else {
        try out.writeAll(usage);
        return 2;
    };

    // Connect. Unlike the server, a migration run needs the database.
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
    db.libraryInit() catch |err| {
        std.log.err("cannot initialize the MariaDB library: {t}", .{err});
        return 1;
    };
    defer db.libraryEnd();
    const pool = db.Pool.create(gpa, io, .{
        .connection = connection,
        .pool_size = 1,
        .acquire_timeout_ms = 1000,
        .multi_statements = true,
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

    // `status` only reads: it does not create the table or take the lock.
    if (apply) {
        _ = try conn.exec(create_table, .{});
        const lock = try conn.one(struct { locked: ?i64 }, arena,
            \\SELECT GET_LOCK(?, 10)
        , .{lock_name});
        if (lock == null or lock.?.locked != 1) {
            std.log.err("another migration run holds the lock '{s}'", .{lock_name});
            return 1;
        }
    }
    defer if (apply) {
        _ = conn.query(struct { released: ?i64 }, arena,
            \\SELECT RELEASE_LOCK(?)
        , .{lock_name}) catch {};
    };

    const table = try conn.one(struct { count: i64 }, arena, table_exists, .{});
    const applied: []const Applied = if (table.?.count == 0)
        &.{}
    else
        try conn.query(Applied, arena,
            \\SELECT version, name, checksum FROM schema_migrations ORDER BY version
        , .{});

    const report = try check(arena, migrations, applied);
    try printReport(out, report, migrations, applied);
    if (!apply) return 0;

    if (report.changed.len > 0) {
        try out.writeAll("\nStopped: applied migrations changed on disk. Restore them, and put new changes in a new migration.\n");
        return 1;
    }
    if (report.pending.len == 0) {
        try out.writeAll("\nNothing to apply.\n");
        return 0;
    }

    try out.writeAll("\n");
    for (report.pending) |m| {
        try out.print("applying {s} ... ", .{m.name});
        try out.flush();
        const start = std.Io.Timestamp.now(io, .awake);
        conn.execScript(m.content) catch {
            try out.writeAll("FAILED\n");
            try out.print(
                \\
                \\{s} failed (the database error is logged above). Statements
                \\before the failing one stay applied. Fix the database or the
                \\file by hand, then run the migration again.
                \\
            , .{m.name});
            return 1;
        };
        _ = try conn.exec(
            \\INSERT INTO schema_migrations (version, name, checksum) VALUES (?, ?, ?)
        , .{ m.version, m.name, @as([]const u8, &m.checksum) });
        try out.print("ok ({f})\n", .{start.untilNow(io, .awake)});
    }
    try out.print("\nApplied {d} migration(s).\n", .{report.pending.len});
    return 0;
}

/// Reads all `*.sql` files in `path`, sorted by version. A missing directory
/// gives no migrations.
fn readMigrations(io: std.Io, arena: Allocator, path: []const u8) ![]Migration {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var list: std.ArrayList(Migration) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const version = parseVersion(entry.name) orelse {
            std.log.err("{s}: the name must be NNNN_description.sql", .{entry.name});
            return error.InvalidMigrationName;
        };
        const content = try dir.readFileAlloc(io, entry.name, arena, .limited(16 * 1024 * 1024));
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(content, &digest, .{});
        try list.append(arena, .{
            .version = version,
            .name = try arena.dupe(u8, entry.name),
            .content = content,
            .checksum = std.fmt.bytesToHex(digest, .lower),
        });
    }

    std.mem.sort(Migration, list.items, {}, struct {
        fn lessThan(_: void, a: Migration, b: Migration) bool {
            return a.version < b.version;
        }
    }.lessThan);
    for (list.items[1..], list.items[0..list.items.len -| 1]) |m, prev| {
        if (m.version == prev.version) {
            std.log.err("{s} and {s} have the same version", .{ prev.name, m.name });
            return error.DuplicateMigrationVersion;
        }
    }
    return list.items;
}

/// Returns NNNN from `NNNN_description.sql`, or null if the name does not
/// have that form. Version 0 is not allowed.
fn parseVersion(name: []const u8) ?u64 {
    if (!std.mem.endsWith(u8, name, ".sql")) return null;
    const underscore = std.mem.indexOfScalar(u8, name, '_') orelse return null;
    if (underscore == 0 or underscore + 1 >= name.len - ".sql".len) return null;
    const version = std.fmt.parseInt(u64, name[0..underscore], 10) catch return null;
    return if (version == 0) null else version;
}

const Report = struct {
    pending: []const Migration,
    /// Applied migrations whose file content changed.
    changed: []const Migration,
    /// Applied migrations whose file is missing.
    missing: []const Applied,
};

fn check(arena: Allocator, migrations: []const Migration, applied: []const Applied) !Report {
    var pending: std.ArrayList(Migration) = .empty;
    var changed: std.ArrayList(Migration) = .empty;
    var missing: std.ArrayList(Applied) = .empty;
    for (migrations) |m| {
        const row = findApplied(applied, m.version) orelse {
            try pending.append(arena, m);
            continue;
        };
        if (!std.mem.eql(u8, row.checksum, &m.checksum)) try changed.append(arena, m);
    }
    for (applied) |row| {
        if (findMigration(migrations, row.version) == null) try missing.append(arena, row);
    }
    return .{ .pending = pending.items, .changed = changed.items, .missing = missing.items };
}

fn findApplied(applied: []const Applied, version: u64) ?Applied {
    for (applied) |row| if (row.version == version) return row;
    return null;
}

fn findMigration(migrations: []const Migration, version: u64) ?Migration {
    for (migrations) |m| if (m.version == version) return m;
    return null;
}

fn printReport(out: *std.Io.Writer, report: Report, migrations: []const Migration, applied: []const Applied) !void {
    if (migrations.len == 0 and applied.len == 0) {
        try out.writeAll("No migrations.\n");
        return;
    }
    for (migrations) |m| {
        const state = if (findApplied(applied, m.version) == null)
            "pending"
        else if (findMigration(report.changed, m.version) != null)
            "CHANGED"
        else
            "applied";
        try out.print("  {s:<8} {s}\n", .{ state, m.name });
    }
    for (report.missing) |row| try out.print("  {s:<8} {s} (applied, but the file is missing)\n", .{ "missing", row.name });
}

fn newMigration(io: std.Io, out: *std.Io.Writer, dir_path: []const u8, migrations: []const Migration, name: []const u8) !u8 {
    if (!isValidName(name)) {
        std.log.err("NAME must use only a-z, 0-9 and _: {s}", .{name});
        return 2;
    }
    const version = if (migrations.len == 0) 1 else migrations[migrations.len - 1].version + 1;

    var name_buf: [256]u8 = undefined;
    const file_name = std.fmt.bufPrint(&name_buf, "{d:0>4}_{s}.sql", .{ version, name }) catch {
        std.log.err("NAME is too long", .{});
        return 2;
    };
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{
        .sub_path = file_name,
        .data = "-- One schema change in each migration: MariaDB commits CREATE, ALTER\n" ++
            "-- and DROP immediately, so a failure later in this file does not undo\n" ++
            "-- the statements before it.\n\n",
        .flags = .{ .exclusive = true },
    });
    try out.print("created {s}/{s}\n", .{ dir_path, file_name });
    return 0;
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

test parseVersion {
    try std.testing.expectEqual(1, parseVersion("0001_create_posts.sql"));
    try std.testing.expectEqual(42, parseVersion("42_add_slug.sql"));
    try std.testing.expectEqual(20261016120000, parseVersion("20261016120000_x.sql"));
    try std.testing.expectEqual(null, parseVersion("0000_zero.sql"));
    try std.testing.expectEqual(null, parseVersion("create_posts.sql"));
    try std.testing.expectEqual(null, parseVersion("0001.sql"));
    try std.testing.expectEqual(null, parseVersion("0001_.sql"));
    try std.testing.expectEqual(null, parseVersion("_0001.sql"));
    try std.testing.expectEqual(null, parseVersion("abc_x.sql"));
    try std.testing.expectEqual(null, parseVersion("0001_x.txt"));
}

test isValidName {
    try std.testing.expect(isValidName("create_posts"));
    try std.testing.expect(isValidName("add_index_2"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("Create-Posts"));
    try std.testing.expect(!isValidName("../x"));
}

test check {
    const m1: Migration = .{ .version = 1, .name = "0001_a.sql", .content = "", .checksum = @splat('a') };
    const m2: Migration = .{ .version = 2, .name = "0002_b.sql", .content = "", .checksum = @splat('b') };
    const m3: Migration = .{ .version = 3, .name = "0003_c.sql", .content = "", .checksum = @splat('c') };
    const applied = [_]Applied{
        .{ .version = 1, .name = "0001_a.sql", .checksum = &m1.checksum },
        .{ .version = 2, .name = "0002_b.sql", .checksum = &@as([64]u8, @splat('x')) },
        .{ .version = 9, .name = "0009_gone.sql", .checksum = &@as([64]u8, @splat('z')) },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const report = try check(arena.allocator(), &.{ m1, m2, m3 }, &applied);
    try std.testing.expectEqual(1, report.pending.len);
    try std.testing.expectEqual(3, report.pending[0].version);
    try std.testing.expectEqual(1, report.changed.len);
    try std.testing.expectEqual(2, report.changed[0].version);
    try std.testing.expectEqual(1, report.missing.len);
    try std.testing.expectEqual(9, report.missing[0].version);
}
