//! Image files for uploads: the format from the first bytes, the size in
//! pixels, and a copy without metadata (`clean`).
//!
//! `clean` copies only the parts of the file that a browser needs to show
//! the image, and drops the others: EXIF and XMP (the camera, the time and
//! the GPS position), IPTC, comments, text chunks, thumbnails, and data after
//! the end of the image (for example the video of a "motion photo"). It
//! keeps color profiles. For JPEG it keeps the EXIF orientation, in a new
//! EXIF segment with only that tag, so phone photos do not show on their
//! side.
//!
//! The pixel data is copied as it is: the image is not decoded. Thus a file
//! that `clean` accepts has a valid structure and no metadata, but a browser
//! cannot necessarily show it.
//!
//! SVG is not supported: an SVG file can contain scripts.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Format = enum {
    jpeg,
    png,
    gif,
    webp,

    /// The file name extension, without the dot.
    pub fn extension(format: Format) []const u8 {
        return switch (format) {
            .jpeg => "jpg",
            .png => "png",
            .gif => "gif",
            .webp => "webp",
        };
    }

    pub fn contentType(format: Format) []const u8 {
        return switch (format) {
            .jpeg => "image/jpeg",
            .png => "image/png",
            .gif => "image/gif",
            .webp => "image/webp",
        };
    }
};

/// The processor of images for `upload.receive` (see upload.zig): detects
/// JPEG, PNG, GIF and WebP, and gives the file without metadata (`clean`).
pub const Processor = struct {
    pub const noun = "image";
    pub const description = "a JPEG, PNG, GIF or WebP image";
    pub const Result = Cleaned;

    pub fn detect(data: []const u8) bool {
        return image.detect(data) != null;
    }

    pub fn process(arena: Allocator, data: []const u8) error{ InvalidFile, OutOfMemory }!Cleaned {
        return clean(arena, data) catch |err| switch (err) {
            error.UnknownFormat, error.InvalidImage => error.InvalidFile,
            error.OutOfMemory => error.OutOfMemory,
        };
    }
};

const image = @This();

pub const Info = struct {
    format: Format,
    width: u32,
    height: u32,
};

pub const Cleaned = struct {
    info: Info,
    /// The file without metadata.
    data: []u8,
};

pub const Error = error{
    /// Not JPEG, PNG, GIF or WebP.
    UnknownFormat,
    /// The structure of the file is not valid, or the file is not complete.
    InvalidImage,
    OutOfMemory,
};

const png_signature = "\x89PNG\r\n\x1a\n";

/// The format of `data`, from its first bytes. The file name and the
/// content type that the browser sends are not used: they can be incorrect.
pub fn detect(data: []const u8) ?Format {
    if (std.mem.startsWith(u8, data, "\xFF\xD8\xFF")) return .jpeg;
    if (std.mem.startsWith(u8, data, png_signature)) return .png;
    if (std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a")) return .gif;
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return .webp;
    return null;
}

/// Returns a copy of `data` without metadata, allocated with `gpa`, and the
/// format and size of the image.
pub fn clean(gpa: Allocator, data: []const u8) Error!Cleaned {
    const format = detect(data) orelse return error.UnknownFormat;
    var out: Out = .{ .gpa = gpa };
    errdefer out.list.deinit(gpa);
    const size = switch (format) {
        .jpeg => try cleanJpeg(&out, data),
        .png => try cleanPng(&out, data),
        .gif => try cleanGif(&out, data),
        .webp => try cleanWebp(&out, data),
    };
    if (size.width == 0 or size.height == 0) return error.InvalidImage;
    return .{
        .info = .{ .format = format, .width = size.width, .height = size.height },
        .data = try out.list.toOwnedSlice(gpa),
    };
}

const Size = struct { width: u32, height: u32 };

const Out = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    fn add(out: *Out, bytes: []const u8) error{OutOfMemory}!void {
        try out.list.appendSlice(out.gpa, bytes);
    }
};

fn int(comptime T: type, endian: std.builtin.Endian, data: []const u8, pos: usize) error{InvalidImage}!T {
    const n = @divExact(@typeInfo(T).int.bits, 8);
    if (pos > data.len or data.len - pos < n) return error.InvalidImage;
    return std.mem.readInt(T, data[pos..][0..n], endian);
}

// JPEG: segments, each a marker (0xFF and a code) and, for most markers, a
// 16-bit length and the content. After SOS (start of scan) comes the
// compressed data, until the next marker that is not a restart marker.

fn cleanJpeg(out: *Out, data: []const u8) Error!Size {
    try out.add(data[0..2]); // SOI
    var size: ?Size = null;
    var pos: usize = 2;
    while (true) {
        // 0xFF, more 0xFF fill bytes if any, then the code.
        if (pos >= data.len or data[pos] != 0xFF) return error.InvalidImage;
        while (pos < data.len and data[pos] == 0xFF) pos += 1;
        if (pos >= data.len) return error.InvalidImage;
        const marker = data[pos];
        pos += 1;
        switch (marker) {
            // EOI: the end. Data after it is not copied.
            0xD9 => {
                try out.add(&.{ 0xFF, 0xD9 });
                return size orelse error.InvalidImage;
            },
            // Markers without a length.
            0x01, 0xD0...0xD7 => {
                try out.add(&.{ 0xFF, marker });
                continue;
            },
            0x00, 0xD8 => return error.InvalidImage,
            else => {},
        }
        const len = try int(u16, .big, data, pos);
        if (len < 2 or data.len - pos < len) return error.InvalidImage;
        // From the last 0xFF before the code, without the fill bytes.
        const segment = data[pos - 2 .. pos + len];
        const payload = data[pos + 2 .. pos + len];
        pos += len;
        switch (marker) {
            // APP1: EXIF or XMP. Only the orientation stays.
            0xE1 => {
                if (std.mem.startsWith(u8, payload, "Exif\x00\x00")) {
                    if (exifOrientation(payload[6..])) |o| {
                        if (o != 1) try out.add(&orientationSegment(o));
                    }
                }
                continue;
            },
            // APP0 JFIF, APP2 ICC profile and APP14 Adobe (the color
            // transform) are necessary to show the image correctly. Other
            // APP2 segments (MPF) refer to images after EOI.
            0xE0 => if (!std.mem.startsWith(u8, payload, "JFIF\x00")) continue,
            0xE2 => if (!std.mem.startsWith(u8, payload, "ICC_PROFILE\x00")) continue,
            0xEE => if (!std.mem.startsWith(u8, payload, "Adobe")) continue,
            // Other APPn (for example APP13, IPTC) and COM (a comment).
            0xE3...0xED, 0xEF, 0xFE => continue,
            // SOFn (start of frame), but not DHT (C4), JPG (C8) and DAC (CC).
            0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => if (size == null) {
                size = .{ .height = try int(u16, .big, payload, 1), .width = try int(u16, .big, payload, 3) };
            },
            else => {},
        }
        try out.add(segment);
        if (marker == 0xDA) {
            // SOS: the compressed data. 0xFF 0x00 is a 0xFF in the data, and
            // 0xFF 0xD0 to 0xD7 are restart markers in the data.
            const start = pos;
            while (pos + 1 < data.len) : (pos += 1) {
                if (data[pos] != 0xFF) continue;
                const next = data[pos + 1];
                if (next != 0x00 and (next < 0xD0 or next > 0xD7)) break;
            }
            if (pos + 1 >= data.len) return error.InvalidImage;
            try out.add(data[start..pos]);
        }
    }
}

/// The orientation tag (0x0112) in IFD0 of the TIFF data of an EXIF
/// segment, or null when there is none or it is not valid.
fn exifOrientation(tiff: []const u8) ?u16 {
    if (tiff.len < 8) return null;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, tiff[0..2], "II"))
        .little
    else if (std.mem.eql(u8, tiff[0..2], "MM"))
        .big
    else
        return null;
    if (std.mem.readInt(u16, tiff[2..4], endian) != 42) return null;
    const ifd = std.mem.readInt(u32, tiff[4..8], endian);
    const count = int(u16, endian, tiff, ifd) catch return null;
    for (0..count) |i| {
        const entry = ifd + 2 + i * 12;
        if (entry + 12 > tiff.len) return null;
        if (std.mem.readInt(u16, tiff[entry..][0..2], endian) != 0x0112) continue;
        // One SHORT value, in the first two bytes of the value field.
        const value_type = std.mem.readInt(u16, tiff[entry + 2 ..][0..2], endian);
        const value_count = std.mem.readInt(u32, tiff[entry + 4 ..][0..4], endian);
        if (value_type != 3 or value_count != 1) return null;
        const value = std.mem.readInt(u16, tiff[entry + 8 ..][0..2], endian);
        return if (value >= 1 and value <= 8) value else null;
    }
    return null;
}

/// An APP1 EXIF segment with only the orientation tag.
fn orientationSegment(orientation: u16) [36]u8 {
    std.debug.assert(orientation >= 1 and orientation <= 8);
    return .{
        0xFF, 0xE1, 0x00, 34, // marker and length
        'E', 'x', 'i', 'f', 0, 0, // EXIF header
        'M', 'M', 0, 42, 0, 0, 0, 8, // TIFF header, big-endian, IFD0 at 8
        0, 1, // one entry
        0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, @intCast(orientation), 0, 0, // orientation, SHORT, 1 value
        0, 0, 0, 0, // no next IFD
    };
}

// PNG: the signature, then chunks, each a 32-bit length, a 4-letter type,
// the data and a CRC. A type that starts with an upper-case letter is
// critical: a decoder that does not know it cannot show the image.

/// The chunks that are copied. The other ancillary chunks (tEXt, zTXt,
/// iTXt, eXIf, tIME and chunks of applications) are dropped.
const png_chunks = [_]*const [4]u8{
    "IHDR", "PLTE", "IDAT", "IEND", // critical
    "tRNS", "cHRM", "gAMA", "iCCP", "sBIT", "sRGB", "cICP", "mDCV", "cLLI", "bKGD", "pHYs", // color and transparency
    "acTL", "fcTL", "fdAT", // animation (APNG)
};

fn cleanPng(out: *Out, data: []const u8) Error!Size {
    try out.add(png_signature);
    var size: ?Size = null;
    var pos: usize = png_signature.len;
    while (true) {
        if (data.len - pos < 12) return error.InvalidImage;
        const len = try int(u32, .big, data, pos);
        if (len > data.len - pos - 12) return error.InvalidImage;
        const chunk_type = data[pos + 4 ..][0..4];
        const body = data[pos + 8 .. pos + 8 + len];
        const chunk = data[pos .. pos + 12 + len];
        pos += 12 + len;
        if (size == null) {
            if (!std.mem.eql(u8, chunk_type, "IHDR") or len != 13) return error.InvalidImage;
            size = .{ .width = try int(u32, .big, body, 0), .height = try int(u32, .big, body, 4) };
        }
        const known = for (png_chunks) |name| {
            if (std.mem.eql(u8, chunk_type, name)) break true;
        } else false;
        if (known) {
            try out.add(chunk);
        } else if (chunk_type[0] & 0x20 == 0) {
            return error.InvalidImage;
        }
        if (std.mem.eql(u8, chunk_type, "IEND")) return size.?;
    }
}

// GIF: a header, the logical screen descriptor and an optional color table,
// then blocks: images (0x2C), extensions (0x21) and the trailer (0x3B).
// Images and extensions end with data sub-blocks: a length byte and the
// data, until a length of 0.

fn cleanGif(out: *Out, data: []const u8) Error!Size {
    if (data.len < 13) return error.InvalidImage;
    const size: Size = .{ .width = try int(u16, .little, data, 6), .height = try int(u16, .little, data, 8) };
    var pos: usize = 13;
    if (data[10] & 0x80 != 0) pos += colorTableLen(data[10]);
    if (pos > data.len) return error.InvalidImage;
    try out.add(data[0..pos]);
    while (true) {
        if (pos >= data.len) return error.InvalidImage;
        const start = pos;
        switch (data[pos]) {
            0x3B => {
                try out.add(data[pos .. pos + 1]);
                return size;
            },
            0x2C => {
                if (data.len - pos < 10) return error.InvalidImage;
                const flags = data[pos + 9];
                pos += 10;
                if (flags & 0x80 != 0) pos += colorTableLen(flags);
                // The LZW minimum code size, then the image data.
                pos = try skipSubBlocks(data, pos + 1);
                try out.add(data[start..pos]);
            },
            0x21 => {
                if (data.len - pos < 2) return error.InvalidImage;
                const label = data[pos + 1];
                const first = pos + 2;
                pos = try skipSubBlocks(data, first);
                const keep = switch (label) {
                    // Graphic control (frame delay, transparency) and plain text.
                    0xF9, 0x01 => true,
                    // Application: only the loop count of animations. XMP
                    // and the data of other applications are dropped.
                    0xFF => data[first] == 11 and
                        (std.mem.eql(u8, data[first + 1 .. first + 12], "NETSCAPE2.0") or
                            std.mem.eql(u8, data[first + 1 .. first + 12], "ANIMEXTS1.0")),
                    // Comments, and extensions that are not known.
                    else => false,
                };
                if (keep) try out.add(data[start..pos]);
            },
            else => return error.InvalidImage,
        }
    }
}

/// The size in bytes of a color table, from the flags byte that has its size.
fn colorTableLen(flags: u8) usize {
    return 3 * (@as(usize, 2) << @intCast(flags & 7));
}

/// Returns the position after the sub-blocks that start at `start`.
fn skipSubBlocks(data: []const u8, start: usize) error{InvalidImage}!usize {
    var pos = start;
    while (true) {
        if (pos >= data.len) return error.InvalidImage;
        const len = data[pos];
        pos += 1;
        if (len == 0) return pos;
        pos += len;
    }
}

// WebP: a RIFF file, "RIFF", a 32-bit size, "WEBP", then chunks, each a
// 4-letter type, a 32-bit size, the data and a padding byte if the size is
// odd. The first chunk is VP8 (lossy), VP8L (lossless) or VP8X (extended:
// flags and the canvas size, then the other chunks).

/// The chunks that are copied. EXIF, XMP and unknown chunks are dropped.
const webp_chunks = [_]*const [4]u8{ "VP8 ", "VP8L", "VP8X", "ALPH", "ANIM", "ANMF", "ICCP" };

/// The flags in VP8X for EXIF and XMP chunks.
const vp8x_exif_xmp: u8 = 0x08 | 0x04;

fn cleanWebp(out: *Out, data: []const u8) Error!Size {
    const riff_len = try int(u32, .little, data, 4);
    if (riff_len < 4 or riff_len > data.len - 8) return error.InvalidImage;
    // Data after the RIFF size is not copied.
    const end = 8 + riff_len;
    try out.add(data[0..12]); // the size is set at the end
    var size: ?Size = null;
    var pos: usize = 12;
    while (pos < end) {
        if (end - pos < 8) return error.InvalidImage;
        const chunk_type = data[pos..][0..4];
        const len = try int(u32, .little, data, pos + 4);
        if (len > end - pos - 8) return error.InvalidImage;
        const body = data[pos + 8 .. pos + 8 + len];
        if (size == null) size = try webpSize(chunk_type, body);
        const known = for (webp_chunks) |name| {
            if (std.mem.eql(u8, chunk_type, name)) break true;
        } else false;
        if (known) {
            try out.add(data[pos .. pos + 8]);
            if (std.mem.eql(u8, chunk_type, "VP8X")) {
                try out.add(&.{body[0] & ~vp8x_exif_xmp});
                try out.add(body[1..]);
            } else {
                try out.add(body);
            }
            // Also when the file has no padding byte after the last chunk.
            if (len % 2 == 1) try out.add(&.{0});
        }
        pos += 8 + len + len % 2;
    }
    const total = out.list.items.len - 8;
    std.mem.writeInt(u32, out.list.items[4..8], @intCast(total), .little);
    return size orelse error.InvalidImage;
}

/// The size of the image, from the first chunk.
fn webpSize(chunk_type: *const [4]u8, body: []const u8) error{InvalidImage}!Size {
    if (std.mem.eql(u8, chunk_type, "VP8X")) {
        // 24-bit canvas width and height, minus 1.
        if (body.len < 10) return error.InvalidImage;
        return .{
            .width = std.mem.readInt(u24, body[4..7], .little) + @as(u32, 1),
            .height = std.mem.readInt(u24, body[7..10], .little) + @as(u32, 1),
        };
    }
    if (std.mem.eql(u8, chunk_type, "VP8L")) {
        // The signature 0x2F, then 14 bits for each size, minus 1.
        if (body.len < 5 or body[0] != 0x2F) return error.InvalidImage;
        const bits = std.mem.readInt(u32, body[1..5], .little);
        return .{ .width = (bits & 0x3FFF) + 1, .height = ((bits >> 14) & 0x3FFF) + 1 };
    }
    if (std.mem.eql(u8, chunk_type, "VP8 ")) {
        // A 3-byte frame tag, the start code, then 14 bits for each size.
        if (body.len < 10 or !std.mem.eql(u8, body[3..6], "\x9d\x01\x2a")) return error.InvalidImage;
        return .{
            .width = std.mem.readInt(u16, body[6..8], .little) & 0x3FFF,
            .height = std.mem.readInt(u16, body[8..10], .little) & 0x3FFF,
        };
    }
    return error.InvalidImage;
}

fn expectClean(input: []const u8, expected: []const u8, info: Info) !void {
    const result = try clean(std.testing.allocator, input);
    defer std.testing.allocator.free(result.data);
    try std.testing.expectEqual(info, result.info);
    try std.testing.expectEqualSlices(u8, expected, result.data);
}

test detect {
    try std.testing.expectEqual(.jpeg, detect("\xFF\xD8\xFF\xE0"));
    try std.testing.expectEqual(.png, detect(png_signature ++ "x"));
    try std.testing.expectEqual(.gif, detect("GIF89a..."));
    try std.testing.expectEqual(.webp, detect("RIFF\x00\x00\x00\x00WEBPVP8 "));
    try std.testing.expectEqual(null, detect("<svg xmlns=\"http://www.w3.org/2000/svg\">"));
    try std.testing.expectEqual(null, detect("RIFF\x00\x00\x00\x00WAVE"));
    try std.testing.expectEqual(null, detect(""));
    try std.testing.expectError(error.UnknownFormat, clean(std.testing.allocator, "<html>"));
}

const jpeg_app0 = "\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00";
const jpeg_dqt = "\xFF\xDB\x00\x05\x00\xAA\xBB";
/// SOF0: 8 bits, height 2, width 3, one component.
const jpeg_sof = "\xFF\xC0\x00\x0B\x08\x00\x02\x00\x03\x01\x01\x11\x00";
const jpeg_sos = "\xFF\xDA\x00\x08\x01\x01\x00\x00\x3F\x00";
/// Compressed data with a stuffed 0xFF and a restart marker.
const jpeg_scan = "\x12\xFF\x00\x34\xFF\xD0\x56";

/// A little-endian EXIF segment with the orientation `o` and a GPS IFD
/// pointer (tag 0x8825).
fn jpegExif(comptime o: u8) []const u8 {
    const tiff = "II\x2A\x00\x08\x00\x00\x00" ++ // header, IFD0 at 8
        "\x02\x00" ++ // two entries
        "\x25\x88\x04\x00\x01\x00\x00\x00\x26\x00\x00\x00" ++ // GPS IFD at 38
        "\x12\x01\x03\x00\x01\x00\x00\x00" ++ [_]u8{ o, 0, 0, 0 } ++
        "\x00\x00\x00\x00" ++
        "\x00\x00"; // an empty GPS IFD
    const payload = "Exif\x00\x00" ++ tiff;
    return "\xFF\xE1" ++ [_]u8{ 0, payload.len + 2 } ++ payload;
}

test "clean JPEG" {
    const xmp = "\xFF\xE1\x00\x23http://ns.adobe.com/xap/1.0/\x00<x/>";
    const comment = "\xFF\xFE\x00\x07hello";
    const iptc = "\xFF\xED\x00\x06abcd";
    const icc = "\xFF\xE2\x00\x0FICC_PROFILE\x00\x01";
    const mpf = "\xFF\xE2\x00\x08MPF\x00II";
    const trailer = "\x00\x00\x00\x18ftypmp42 (a motion photo video)";
    const info: Info = .{ .format = .jpeg, .width = 3, .height = 2 };

    // EXIF with orientation 6 becomes an EXIF segment with only the
    // orientation. The other metadata, the fill bytes before the EOI and
    // the data after it are dropped.
    try expectClean(
        "\xFF\xD8" ++ jpeg_app0 ++ comptime jpegExif(6) ++ xmp ++ icc ++ mpf ++ iptc ++ comment ++ jpeg_dqt ++ jpeg_sof ++ jpeg_sos ++ jpeg_scan ++ "\xFF\xFF\xD9" ++ trailer,
        "\xFF\xD8" ++ jpeg_app0 ++ comptime orientationSegment(6) ++ icc ++ jpeg_dqt ++ jpeg_sof ++ jpeg_sos ++ jpeg_scan ++ "\xFF\xD9",
        info,
    );
    // Orientation 1 (normal) needs no segment.
    try expectClean(
        "\xFF\xD8" ++ comptime jpegExif(1) ++ jpeg_sof ++ jpeg_sos ++ jpeg_scan ++ "\xFF\xD9",
        "\xFF\xD8" ++ jpeg_sof ++ jpeg_sos ++ jpeg_scan ++ "\xFF\xD9",
        info,
    );
    // Not complete: no EOI, a segment longer than the file, no frame.
    try std.testing.expectError(error.InvalidImage, clean(std.testing.allocator, "\xFF\xD8" ++ jpeg_sof ++ jpeg_sos ++ jpeg_scan));
    try std.testing.expectError(error.InvalidImage, clean(std.testing.allocator, "\xFF\xD8\xFF\xE0\x00\x40JFIF"));
    try std.testing.expectError(error.InvalidImage, clean(std.testing.allocator, "\xFF\xD8" ++ jpeg_dqt ++ "\xFF\xD9"));
}

test exifOrientation {
    const exif = comptime jpegExif(8);
    try std.testing.expectEqual(8, exifOrientation(exif[10..]).?);
    // Big-endian, as `orientationSegment` writes it.
    try std.testing.expectEqual(3, exifOrientation(orientationSegment(3)[10..]).?);
    try std.testing.expectEqual(null, exifOrientation(comptime jpegExif(9)[10..]));
    try std.testing.expectEqual(null, exifOrientation("II\x2A\x00\xFF\xFF\xFF\xFF"));
    try std.testing.expectEqual(null, exifOrientation("XX\x2A\x00\x08\x00\x00\x00"));
}

fn pngChunk(comptime chunk_type: *const [4]u8, comptime body: []const u8) []const u8 {
    return std.mem.toBytes(std.mem.nativeToBig(u32, body.len)) ++ chunk_type ++ body ++ "CRC!";
}

test "clean PNG" {
    const ihdr = comptime pngChunk("IHDR", "\x00\x00\x00\x05\x00\x00\x00\x07\x08\x06\x00\x00\x00");
    const srgb = comptime pngChunk("sRGB", "\x00");
    const idat = comptime pngChunk("IDAT", "pixels");
    const iend = comptime pngChunk("IEND", "");
    const text = comptime pngChunk("tEXt", "Author\x00Ann");
    const exif = comptime pngChunk("eXIf", "MM\x00\x2A");
    const private = comptime pngChunk("prVt", "x");
    try expectClean(
        png_signature ++ ihdr ++ text ++ srgb ++ exif ++ idat ++ private ++ iend ++ "after",
        png_signature ++ ihdr ++ srgb ++ idat ++ iend,
        .{ .format = .png, .width = 5, .height = 7 },
    );
    // An unknown critical chunk, IHDR not first, no IEND.
    try std.testing.expectError(error.InvalidImage, clean(std.testing.allocator, png_signature ++ ihdr ++ comptime pngChunk("QQQQ", "") ++ iend));
    try std.testing.expectError(error.InvalidImage, clean(std.testing.allocator, png_signature ++ srgb ++ ihdr ++ iend));
    try std.testing.expectError(error.InvalidImage, clean(std.testing.allocator, png_signature ++ ihdr ++ idat));
}

test "clean GIF" {
    // 4 x 3, a global color table of 2 colors.
    const head = "GIF89a\x04\x00\x03\x00\x80\x00\x00" ++ "\x00\x00\x00\xFF\xFF\xFF";
    const loop = "\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00";
    const xmp = "\x21\xFF\x0BXMP DataXMP\x03<x>\x00";
    const comment = "\x21\xFE\x05hello\x00";
    const control = "\x21\xF9\x04\x01\x00\x00\x00\x00";
    const frame = "\x2C\x00\x00\x00\x00\x04\x00\x03\x00\x00\x02\x02\x44\x01\x00";
    try expectClean(
        head ++ loop ++ xmp ++ comment ++ control ++ frame ++ "\x3B" ++ "after",
        head ++ loop ++ control ++ frame ++ "\x3B",
        .{ .format = .gif, .width = 4, .height = 3 },
    );
    try std.testing.expectError(error.InvalidImage, clean(std.testing.allocator, head ++ frame));
    try std.testing.expectError(error.InvalidImage, clean(std.testing.allocator, head ++ "\x2C\x00\x00"));
}

fn riff(comptime chunks: []const u8) []const u8 {
    return "RIFF" ++ std.mem.toBytes(std.mem.nativeToLittle(u32, chunks.len + 4)) ++ "WEBP" ++ chunks;
}

fn webpChunk(comptime chunk_type: *const [4]u8, comptime body: []const u8) []const u8 {
    const pad = if (body.len % 2 == 1) "\x00" else "";
    return chunk_type ++ std.mem.toBytes(std.mem.nativeToLittle(u32, body.len)) ++ body ++ pad;
}

test "clean WebP" {
    // VP8X with the ICC, EXIF and XMP flags, canvas 640 x 480.
    const vp8x = comptime webpChunk("VP8X", "\x2C\x00\x00\x00\x7F\x02\x00\xDF\x01\x00");
    const vp8x_clean = comptime webpChunk("VP8X", "\x20\x00\x00\x00\x7F\x02\x00\xDF\x01\x00");
    const icc = comptime webpChunk("ICCP", "profile");
    const vp8 = comptime webpChunk("VP8 ", "\x00\x00\x00\x9d\x01\x2a\x80\x02\xe0\x01pixels");
    const exif = comptime webpChunk("EXIF", "MM\x00\x2A");
    const xmp = comptime webpChunk("XMP ", "<x/>");
    try expectClean(
        comptime riff(vp8x ++ icc ++ vp8 ++ exif ++ xmp) ++ "after",
        comptime riff(vp8x_clean ++ icc ++ vp8),
        .{ .format = .webp, .width = 640, .height = 480 },
    );
    // Simple lossy and lossless files: the size from VP8 and VP8L.
    try expectClean(comptime riff(vp8), comptime riff(vp8), .{ .format = .webp, .width = 640, .height = 480 });
    // VP8L: 14 bits of width - 1 (99), then 14 bits of height - 1 (49).
    const vp8l = comptime webpChunk("VP8L", "\x2F" ++ std.mem.toBytes(std.mem.nativeToLittle(u32, 99 | (49 << 14))) ++ "px");
    try expectClean(comptime riff(vp8l ++ exif), comptime riff(vp8l), .{ .format = .webp, .width = 100, .height = 50 });
    // A RIFF size larger than the file, a first chunk that is not an image.
    try std.testing.expectError(error.InvalidImage, clean(std.testing.allocator, "RIFF\xFF\x00\x00\x00WEBP" ++ vp8));
    try std.testing.expectError(error.InvalidImage, clean(std.testing.allocator, comptime riff(icc ++ vp8)));
}

test Processor {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const png = comptime png_signature ++ pngChunk("IHDR", "\x00\x00\x00\x05\x00\x00\x00\x07\x08\x06\x00\x00\x00") ++ pngChunk("tEXt", "a\x00b") ++ pngChunk("IEND", "");
    try std.testing.expect(Processor.detect(png));
    try std.testing.expect(!Processor.detect("GIF87"));
    const cleaned = try Processor.process(arena, png);
    try std.testing.expectEqual(Info{ .format = .png, .width = 5, .height = 7 }, cleaned.info);
    try std.testing.expectEqualStrings("image/png", cleaned.info.format.contentType());
    try std.testing.expectError(error.InvalidFile, Processor.process(arena, png_signature ++ "short"));
}
