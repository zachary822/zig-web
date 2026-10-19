//! Files on disk with generated names, in `MEDIA_DIR`, and their URLs under
//! `MEDIA_URL`. This layer knows nothing about the database, the users or
//! the kinds of files: the uploads library (`library.zig`) records which
//! files exist and who owns them.
//!
//! A name is 24 random hex digits, a dot and an extension (`newName`).
//! Names cannot be guessed, so a file stays private until a page links to
//! it. A name is never used again, so caches can keep a file for a long
//! time.

const std = @import("std");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.media);

/// Random bytes in a file name. 24 hex digits: names cannot be guessed.
const name_random_len = 12;
const name_hex_len = name_random_len * 2;
/// The longest extension in a name.
const max_extension_len = 10;

/// A new random file name with `extension` (a-z and 0-9, without the dot),
/// for example `3f2a9c1b7d4e8f0a1b2c3d4e.jpg`.
pub fn newName(io: std.Io, arena: Allocator, extension: []const u8) ![]const u8 {
    std.debug.assert(isExtension(extension));
    var random: [name_random_len]u8 = undefined;
    try io.randomSecure(&random);
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ &std.fmt.bytesToHex(random, .lower), extension });
}

/// Reports whether `name` is a name that `newName` can make. Thus it has no
/// `/` and does not start with a dot.
pub fn isStoredName(name: []const u8) bool {
    if (name.len < name_hex_len + 2 or name[name_hex_len] != '.') return false;
    for (name[0..name_hex_len]) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return isExtension(name[name_hex_len + 1 ..]);
}

/// The extension of a stored name, without the dot.
pub fn extensionOf(name: []const u8) []const u8 {
    std.debug.assert(isStoredName(name));
    return name[name_hex_len + 1 ..];
}

fn isExtension(text: []const u8) bool {
    if (text.len == 0 or text.len > max_extension_len) return false;
    for (text) |c| switch (c) {
        'a'...'z', '0'...'9' => {},
        else => return false,
    };
    return true;
}

/// The files on disk, and their URL.
pub const Storage = struct {
    io: std.Io,
    /// `MEDIA_DIR`.
    dir: std.Io.Dir,
    /// `MEDIA_URL`, for example `/media/`.
    url_prefix: []const u8,
    /// `url_prefix` with `*` at the end, for the router (`uploads.serve`).
    route: []const u8,

    /// Opens the directory `path` (`MEDIA_DIR`), and makes it when it does
    /// not exist. `url_prefix` (`MEDIA_URL`) must start and end with `/`.
    pub fn init(io: std.Io, gpa: Allocator, path: []const u8, url_prefix: []const u8) !Storage {
        if (!config.isValidUrlPrefix(url_prefix)) return error.InvalidUrlPrefix;
        const route = try std.mem.concat(gpa, u8, &.{ url_prefix, "*" });
        errdefer gpa.free(route);
        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .open_options = .{ .iterate = true } });
        return .{ .io = io, .dir = dir, .url_prefix = route[0 .. route.len - 1], .route = route };
    }

    pub fn deinit(self: *Storage, gpa: Allocator) void {
        self.dir.close(self.io);
        gpa.free(self.route);
    }

    /// The URL of the file `name`.
    pub fn url(self: *const Storage, arena: Allocator, name: []const u8) ![]const u8 {
        return std.mem.concat(arena, u8, &.{ self.url_prefix, name });
    }

    /// Writes the new file `name`. The file appears complete or not at all,
    /// so nginx never sends a part of it. Fails if the file exists.
    pub fn write(self: *const Storage, name: []const u8, data: []const u8) !void {
        std.debug.assert(isStoredName(name));
        var file = try self.dir.createFileAtomic(self.io, name, .{});
        defer file.deinit(self.io);
        try file.file.writeStreamingAll(self.io, data);
        try file.link(self.io);
    }

    /// Reads the file `name`, at most `max` bytes.
    pub fn read(self: *const Storage, arena: Allocator, name: []const u8, max: usize) ![]u8 {
        std.debug.assert(isStoredName(name));
        return self.dir.readFileAlloc(self.io, name, arena, .limited(max));
    }

    /// Deletes the file `name`. A file that cannot be deleted stays on disk:
    /// the error goes to the log, and `media_cli.zig` finds the file later.
    pub fn delete(self: *const Storage, name: []const u8) void {
        std.debug.assert(isStoredName(name));
        self.dir.deleteFile(self.io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("cannot delete {s} from the media directory: {t}", .{ name, err }),
        };
    }
};

test newName {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try newName(std.testing.io, arena_state.allocator(), "webp");
    const b = try newName(std.testing.io, arena_state.allocator(), "webp");
    try std.testing.expectEqual(name_hex_len + ".webp".len, a.len);
    try std.testing.expect(!std.mem.eql(u8, a, b));
    try std.testing.expect(isStoredName(a));
    try std.testing.expectEqualStrings("webp", extensionOf(a));
}

test isStoredName {
    try std.testing.expect(isStoredName("0123456789abcdef01234567.png"));
    try std.testing.expect(isStoredName("0123456789abcdef01234567.mp3"));
    try std.testing.expect(!isStoredName("0123456789ABCDEF01234567.png"));
    try std.testing.expect(!isStoredName("0123456789abcdef0123456.png"));
    try std.testing.expect(!isStoredName("../3456789abcdef01234567.png"));
    try std.testing.expect(!isStoredName("0123456789abcdef01234567."));
    try std.testing.expect(!isStoredName("0123456789abcdef01234567.PNG"));
    try std.testing.expect(!isStoredName("0123456789abcdef01234567.tar.gz"));
    try std.testing.expect(!isStoredName("0123456789abcdef01234567.verylongext"));
    try std.testing.expect(!isStoredName(".htaccess"));
}

test "Storage write, read and delete" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    var storage: Storage = try .init(io, gpa, path, "/media/");
    defer storage.deinit(gpa);
    try std.testing.expectEqualStrings("/media/*", storage.route);
    try std.testing.expectError(error.InvalidUrlPrefix, Storage.init(io, gpa, path, "media"));

    const name = "0123456789abcdef01234567.png";
    try storage.write(name, "data");
    try std.testing.expectError(error.PathAlreadyExists, storage.write(name, "other"));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("data", try storage.read(arena_state.allocator(), name, 16));
    try std.testing.expectEqualStrings("/media/" ++ name, try storage.url(arena_state.allocator(), name));
    storage.delete(name);
    storage.delete(name); // a missing file is no error
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, name, .{}));
}
