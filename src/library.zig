//! The uploads library: files that users upload to keep. It is one
//! workflow on the two layers below it: `upload.zig` receives and processes
//! a file, and `media.Storage` keeps it on disk. This file adds the kinds of
//! files that the library accepts and the database records: the `upload`
//! table (migrations/0004_create_upload.sql), with the owner, the kind and
//! the metadata of each file. The pages are in `uploads.zig`.
//!
//! A `Kind` is one kind of file in the library. `kindFor` makes it from an
//! upload processor (for example `image.Processor`) and the rules of the
//! library for its files. To add a kind:
//!
//! 1. Write a processor (see upload.zig), or use one that exists.
//! 2. Add `kindFor(Processor, .{ ... })` to `kinds`.
//! 3. Add its content types to the `/media/` location in
//!    deploy/nginx/zig_web.conf. A test below fails until they are there.
//!
//! A route that only processes a file and discards it does not use this
//! file: it calls `upload.receive` with its own processor.

const std = @import("std");
const media = @import("media.zig");
const image = @import("image.zig");

const Allocator = std.mem.Allocator;

/// A type of file that a kind keeps.
pub const FileType = struct {
    /// Without the dot, in lower case.
    extension: []const u8,
    content_type: []const u8,
};

/// A file as the library keeps it.
pub const Kept = struct {
    data: []const u8,
    type: FileType,
    /// What the kind knows about the file, as a JSON object, for the
    /// `metadata` column.
    metadata: []const u8,
};

pub const Kind = struct {
    /// The value of `upload.kind`: 1 to 32 characters from a-z.
    name: []const u8,
    /// For the pages, for example `image` and `images`.
    noun: []const u8,
    plural: []const u8,
    /// The files of the kind, for messages, for example `a JPEG, PNG, GIF or
    /// WebP image`.
    description: []const u8,
    /// The largest file, before the processing.
    max_size: usize,
    /// The types that `keep` gives. Only these extensions are sent to
    /// browsers.
    types: []const FileType,
    /// Browsers show the file in the page (`<img>`). Files of other kinds
    /// are sent as downloads (`Content-Disposition: attachment`).
    show_inline: bool,
    /// The processor's `detect`.
    detect: *const fn (data: []const u8) bool,
    /// The processor's `process`, then the file and the metadata to keep.
    keep: *const fn (arena: Allocator, data: []const u8) error{ InvalidFile, OutOfMemory }!Kept,
    /// A short text about the file, from its metadata, for example
    /// `640 × 480`. null when there is nothing to show.
    describe: *const fn (arena: Allocator, metadata: []const u8) Allocator.Error!?[]const u8,
};

/// The rules of the library for the files of the processor `Processor`.
pub fn KindOptions(comptime Processor: type) type {
    return struct {
        name: []const u8,
        plural: []const u8,
        max_size: usize,
        types: []const FileType,
        show_inline: bool,
        /// The file and the metadata to keep, from the result of the
        /// processor.
        keep: fn (arena: Allocator, result: Processor.Result) Allocator.Error!Kept,
        describe: fn (arena: Allocator, metadata: []const u8) Allocator.Error!?[]const u8,
    };
}

/// A kind of the library for the files of the upload processor `Processor`.
pub fn kindFor(comptime Processor: type, comptime options: KindOptions(Processor)) Kind {
    const keep = struct {
        fn keep(arena: Allocator, data: []const u8) error{ InvalidFile, OutOfMemory }!Kept {
            return options.keep(arena, try Processor.process(arena, data));
        }
    }.keep;
    return .{
        .name = options.name,
        .noun = Processor.noun,
        .plural = options.plural,
        .description = Processor.description,
        .max_size = options.max_size,
        .types = options.types,
        .show_inline = options.show_inline,
        .detect = Processor.detect,
        .keep = keep,
        .describe = options.describe,
    };
}

/// The kinds of the library, in the order that `kindOf` tries them.
pub const kinds = [_]Kind{
    kindFor(image.Processor, .{
        .name = "image",
        .plural = "images",
        .max_size = 10 * 1024 * 1024,
        .types = &image_types,
        .show_inline = true,
        .keep = keepImage,
        .describe = describeImage,
    }),
};

comptime {
    for (kinds, 0..) |kind, i| {
        if (kind.name.len == 0 or kind.name.len > 32) @compileError("library kind name must have 1 to 32 characters: " ++ kind.name);
        for (kind.name) |c| if (c < 'a' or c > 'z') @compileError("library kind name must use only a-z: " ++ kind.name);
        if (kind.types.len == 0) @compileError("library kind needs at least one file type: " ++ kind.name);
        for (kinds[0..i]) |other| {
            if (std.mem.eql(u8, kind.name, other.name)) @compileError("two library kinds have the name " ++ kind.name);
            for (kind.types) |a| for (other.types) |b| {
                if (std.mem.eql(u8, a.extension, b.extension)) @compileError("two library kinds use the extension " ++ a.extension);
            };
        }
    }
}

/// The largest file of all kinds.
pub const max_size = blk: {
    var max: usize = 0;
    for (kinds) |kind| max = @max(max, kind.max_size);
    break :blk max;
};

/// The content types of all kinds, for `<input type="file" accept>`.
pub const accept = blk: {
    var out: []const u8 = "";
    for (kinds) |kind| for (kind.types) |t| {
        out = out ++ (if (out.len == 0) "" else ",") ++ t.content_type;
    };
    break :blk out;
};

/// The files that the library accepts, for the pages, for example `a JPEG,
/// PNG, GIF or WebP image`.
pub const accepted = blk: {
    var out: []const u8 = "";
    for (kinds, 0..) |kind, i| {
        out = out ++ (if (i == 0) "" else " or ") ++ kind.description;
    }
    break :blk out;
};

/// For the upload controls: `image` and `images` when there is one kind,
/// else `file` and `files`.
pub const noun = if (kinds.len == 1) kinds[0].noun else "file";
pub const plural = if (kinds.len == 1) kinds[0].plural else "files";

/// The first kind that accepts `data`, or null.
pub fn kindOf(data: []const u8) ?*const Kind {
    for (&kinds) |*kind| {
        if (kind.detect(data)) return kind;
    }
    return null;
}

/// The kind with the name `name` (`upload.kind`), or null when there is no
/// such kind (any more).
pub fn kindNamed(name: []const u8) ?*const Kind {
    for (&kinds) |*kind| {
        if (std.mem.eql(u8, kind.name, name)) return kind;
    }
    return null;
}

pub const NameType = struct { kind: *const Kind, type: *const FileType };

/// The kind and the type of the library file `name`, or null when `name` is
/// not a stored name (`media.isStoredName`) with an extension of a kind.
/// Thus other files in `MEDIA_DIR` are never sent.
pub fn typeOfName(name: []const u8) ?NameType {
    if (!media.isStoredName(name)) return null;
    const extension = media.extensionOf(name);
    for (&kinds) |*kind| {
        for (kind.types) |*t| {
            if (std.mem.eql(u8, t.extension, extension)) return .{ .kind = kind, .type = t };
        }
    }
    return null;
}

// The image kind: files without metadata (`image.clean`), with the metadata
// `{"width": W, "height": H}`.

/// In the order of `image.Format`.
const image_types = blk: {
    const formats = std.enums.values(image.Format);
    var types: [formats.len]FileType = undefined;
    for (formats, &types) |format, *t| t.* = .{ .extension = format.extension(), .content_type = format.contentType() };
    break :blk types;
};

fn keepImage(arena: Allocator, cleaned: image.Cleaned) Allocator.Error!Kept {
    return .{
        .data = cleaned.data,
        .type = image_types[@backingInt(cleaned.info.format)],
        .metadata = try std.fmt.allocPrint(arena, "{{\"width\":{d},\"height\":{d}}}", .{ cleaned.info.width, cleaned.info.height }),
    };
}

/// For example `640 × 480`.
fn describeImage(arena: Allocator, metadata: []const u8) Allocator.Error!?[]const u8 {
    const size = std.json.parseFromSliceLeaky(struct { width: u32, height: u32 }, arena, metadata, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return try std.fmt.allocPrint(arena, "{d} \u{00D7} {d}", .{ size.width, size.height });
}

test "kinds" {
    try std.testing.expectEqual(&kinds[0], kindOf("\xFF\xD8\xFF\xE0").?);
    try std.testing.expectEqual(null, kindOf("<svg>"));
    try std.testing.expectEqual(&kinds[0], kindNamed("image").?);
    try std.testing.expectEqual(null, kindNamed("video"));
    try std.testing.expectEqualStrings("image/jpeg,image/png,image/gif,image/webp", accept);
    try std.testing.expectEqualStrings("a JPEG, PNG, GIF or WebP image", accepted);
    try std.testing.expectEqual(10 * 1024 * 1024, max_size);
}

test "the image kind" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const kind = kindNamed("image").?;
    // A 5 x 7 PNG with a text chunk.
    const png = "\x89PNG\r\n\x1a\n" ++
        "\x00\x00\x00\x0DIHDR\x00\x00\x00\x05\x00\x00\x00\x07\x08\x06\x00\x00\x00CRC!" ++
        "\x00\x00\x00\x03tEXta\x00bCRC!" ++
        "\x00\x00\x00\x00IENDCRC!";
    const kept = try kind.keep(arena, png);
    try std.testing.expectEqualStrings("png", kept.type.extension);
    try std.testing.expectEqualStrings("image/png", kept.type.content_type);
    try std.testing.expectEqualStrings("{\"width\":5,\"height\":7}", kept.metadata);
    try std.testing.expect(std.mem.indexOf(u8, kept.data, "tEXt") == null);
    try std.testing.expectEqualStrings("5 \u{00D7} 7", (try kind.describe(arena, kept.metadata)).?);
    try std.testing.expectEqual(null, try kind.describe(arena, "{}"));
    try std.testing.expectError(error.InvalidFile, kind.keep(arena, "\x89PNG\r\n\x1a\nshort"));
}

test "the nginx configuration has the types and the size of the uploads" {
    const upload = @import("upload.zig");
    var buf: [16 * 1024]u8 = undefined;
    const conf = try std.Io.Dir.cwd().readFile(std.testing.io, "deploy/nginx/zig_web.conf", &buf);
    for (kinds) |kind| for (kind.types) |t| {
        var line_buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{s} {s};", .{ t.content_type, t.extension });
        if (std.mem.indexOf(u8, conf, line) == null) {
            std.debug.print("deploy/nginx/zig_web.conf: add `{s}` to `types` in `location /media/`\n", .{line});
            return error.TestExpectedEqual;
        }
    };
    var size_buf: [64]u8 = undefined;
    const size = try std.fmt.bufPrint(&size_buf, "client_max_body_size {d}m;", .{std.math.divCeil(usize, upload.requestSize(max_size), 1024 * 1024) catch unreachable});
    if (std.mem.indexOf(u8, conf, size) == null) {
        std.debug.print("deploy/nginx/zig_web.conf: `location = /uploads` needs `{s}`\n", .{size});
        return error.TestExpectedEqual;
    }
}

test typeOfName {
    try std.testing.expectEqualStrings("image/png", typeOfName("0123456789abcdef01234567.png").?.type.content_type);
    // A stored name, but no kind has the extension.
    try std.testing.expectEqual(null, typeOfName("0123456789abcdef01234567.html"));
    try std.testing.expectEqual(null, typeOfName(".htaccess"));
}
