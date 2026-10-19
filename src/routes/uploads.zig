//! The pages of the uploads library (see `library.zig`), for logged-in
//! users: the list of the user's uploads, uploads and deletes. Each user
//! sees and deletes only their own uploads. Also `serve`, which sends the
//! files in development (`SERVE_STATIC`); nginx sends them in production.
//!
//! An upload is a `multipart/form-data` POST with the file in the `file`
//! field. A script that uploads with `fetch` and `Accept: application/json`
//! gets JSON; the form on the uploads page gets a redirect.

const std = @import("std");
const httpz = @import("httpz");
const App = @import("../App.zig");
const flash = @import("../flash.zig");
const library = @import("../library.zig");
const media = @import("../media.zig");
const upload = @import("../upload.zig");

const log = std.log.scoped(.uploads);

/// `GET /uploads`, with an optional `?kind=NAME`: the uploads of the user,
/// the newest first.
pub fn list(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = app.currentUser(req) orelse return app.redirect(res, "/login");
    const query = try req.query();
    const kind: ?*const library.Kind = if (query.get("kind")) |name| library.kindNamed(name) orelse return app.notFound(req, res) else null;

    const Row = struct { id: u64, kind: []const u8, name: []const u8, original_name: []const u8, size: u64, metadata: []const u8, date: []const u8 };
    const select =
        \\SELECT u.id, u.kind, u.name, u.original_name, u.size, u.metadata,
        \\    DATE_FORMAT(u.created_at, '%M %e, %Y')
        \\FROM upload u
        \\WHERE u.user_id = ?
    ;
    const order =
        \\
        \\ORDER BY u.created_at DESC, u.id DESC
    ;
    const rows = blk: {
        const conn = try app.dbConn();
        defer conn.release();
        if (kind) |k| break :blk try conn.query(Row, res.arena, select ++ " AND u.kind = ?" ++ order, .{ user.id, k.name });
        break :blk try conn.query(Row, res.arena, select ++ order, .{user.id});
    };

    const views = try res.arena.alloc(struct {
        url: []const u8,
        original_name: []const u8,
        show_inline: bool,
        extension: []const u8,
        details: ?[]const u8,
        size: []const u8,
        date: []const u8,
        delete_action: []const u8,
    }, rows.len);
    for (rows, views) |row, *view| {
        const url = try app.media.url(res.arena, row.name);
        // A kind that the code no longer has: the file is only a link.
        const row_kind = library.kindNamed(row.kind);
        view.* = .{
            .url = url,
            .original_name = row.original_name,
            .show_inline = if (row_kind) |k| k.show_inline else false,
            .extension = if (std.mem.lastIndexOfScalar(u8, row.name, '.')) |i| row.name[i + 1 ..] else "",
            .details = if (row_kind) |k| try k.describe(res.arena, row.metadata) else null,
            .size = try upload.sizeText(res.arena, row.size),
            .date = row.date,
            .delete_action = try std.fmt.allocPrint(res.arena, "/uploads/{d}/delete", .{row.id}),
        };
    }

    // The filter shows only when there is more than one kind.
    const filters = try res.arena.alloc(struct { label: []const u8, href: []const u8, current: bool }, if (library.kinds.len > 1) library.kinds.len + 1 else 0);
    if (filters.len > 0) {
        filters[0] = .{ .label = "All", .href = "/uploads", .current = kind == null };
        for (&library.kinds, filters[1..]) |*k, *f| f.* = .{
            .label = k.plural,
            .href = try std.fmt.allocPrint(res.arena, "/uploads?kind={s}", .{k.name}),
            .current = kind == k,
        };
    }

    // The size limit of each kind.
    const limits = try res.arena.alloc(struct { plural: []const u8, size: []const u8 }, library.kinds.len);
    for (&library.kinds, limits) |*k, *l| l.* = .{ .plural = k.plural, .size = try upload.sizeText(res.arena, k.max_size) };

    res.header("Cache-Control", "no-store");
    try app.render(req, res, "uploads", .{
        .uploads = views,
        .has_uploads = rows.len > 0,
        .filters = filters,
        .has_filters = filters.len > 0,
        .limits = limits,
        .accept = library.accept,
        .accepted = library.accepted,
        .plural = library.plural,
    });
}

/// `POST /uploads`: keeps the file in the `file` field in the library, as
/// the first kind that accepts it processes it. For a script
/// (`Accept: application/json`) the answer is JSON: `{"url"}`,
/// or `{"error"}` with a 4xx status. For the form on the uploads page it is
/// a redirect to the uploads page, with a message.
pub fn create(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = app.currentUser(req) orelse {
        if (upload.wantsJson(req)) return refuse(req, res, .{ .status = 401, .message = "Log in again to upload files." });
        return app.redirect(res, "/login");
    };
    // Layer 1: the file from the form, then the kind that processes it. The
    // library has several kinds, each with its own size limit, so it does
    // not use `upload.receive`, which takes one processor.
    const file = switch (try upload.read(req, res.arena, .{ .max_size = library.max_size })) {
        .ok => |file| file,
        .rejected => |rejection| return refuse(req, res, rejection),
    };
    const kind = library.kindOf(file.data) orelse return refuse(req, res, upload.unsupported(library.accepted));
    if (file.data.len > kind.max_size) return refuse(req, res, try upload.tooLarge(res.arena, kind.noun, kind.max_size));
    const kept = kind.keep(res.arena, file.data) catch |err| switch (err) {
        error.InvalidFile => return refuse(req, res, try upload.invalid(res.arena, kind.noun)),
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Layer 2, then the record. The file first: a row always has its file.
    // If the row cannot be added, the file goes again.
    const name = try media.newName(app.io, res.arena, kept.type.extension);
    try app.media.write(name, kept.data);
    errdefer app.media.delete(name);
    {
        const conn = try app.dbConn();
        defer conn.release();
        _ = try conn.exec(
            \\INSERT INTO upload (user_id, kind, name, original_name, content_type, size, metadata)
            \\VALUES (?, ?, ?, ?, ?, ?, ?)
        , .{ user.id, kind.name, name, file.original_name, kept.type.content_type, @as(u64, kept.data.len), kept.metadata });
    }
    log.info("user {d} uploaded {s} ({s}, {d} bytes)", .{ user.id, name, kind.name, kept.data.len });

    const url = try app.media.url(res.arena, name);
    if (upload.wantsJson(req)) {
        res.status = 201;
        return res.json(.{ .url = url }, .{});
    }
    try flash.add(req, .success, try std.fmt.allocPrint(res.arena, "The {s} \u{201C}{s}\u{201D} was uploaded.", .{ kind.noun, file.original_name }));
    app.redirect(res, "/uploads");
}

/// `POST /uploads/:id/delete`: deletes the upload and its file.
pub fn delete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const user = app.currentUser(req) orelse return app.redirect(res, "/login");
    const id = std.fmt.parseInt(u64, req.param("id").?, 10) catch return app.notFound(req, res);

    const conn = try app.dbConn();
    defer conn.release();
    // Uploads of other users look the same as uploads that do not exist.
    const row = try conn.one(struct { name: []const u8, original_name: []const u8 }, res.arena,
        \\SELECT name, original_name FROM upload WHERE id = ? AND user_id = ?
    , .{ id, user.id }) orelse return app.notFound(req, res);

    _ = try conn.exec(
        \\DELETE FROM upload WHERE id = ? AND user_id = ?
    , .{ id, user.id });
    app.media.delete(row.name);
    try flash.add(req, .success, try std.fmt.allocPrint(res.arena, "\u{201C}{s}\u{201D} was deleted.", .{row.original_name}));
    app.redirect(res, "/uploads");
}

/// `GET MEDIA_URL*` in development: the file, with the content type of its
/// kind. Only names that `library.typeOfName` knows are sent, so other files in
/// `MEDIA_DIR` stay private. As nginx in production
/// (deploy/nginx/zig_web.conf), files of kinds that do not show inline are
/// downloads.
pub fn serve(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.url.path[app.media.url_prefix.len..];
    const found = library.typeOfName(name) orelse return notFound(res);
    const body = app.media.read(res.arena, name, found.kind.max_size) catch |err| switch (err) {
        error.FileNotFound => return notFound(res),
        else => return err,
    };
    res.header("Content-Type", found.type.content_type);
    res.header("Cache-Control", "public, max-age=31536000, immutable");
    res.header("Content-Security-Policy", "default-src 'none'; sandbox");
    if (!found.kind.show_inline) res.header("Content-Disposition", "attachment");
    res.body = body;
}

fn notFound(res: *httpz.Response) void {
    res.status = 404;
    res.body = "Not Found";
}

fn refuse(req: *httpz.Request, res: *httpz.Response, rejection: upload.Rejection) !void {
    return upload.refuse(req, res, "/uploads", rejection);
}

test serve {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    var storage: media.Storage = try .init(io, gpa, path, "/media/");
    defer storage.deinit(gpa);
    const name = "0123456789abcdef01234567.png";
    try storage.write(name, "png data");
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "private" });
    var app: App = undefined;
    app.media = &storage;

    const Case = struct { path: []const u8, status: u16 };
    for ([_]Case{
        .{ .path = "/media/" ++ name, .status = 200 },
        .{ .path = "/media/secret.txt", .status = 404 },
        .{ .path = "/media/fedcba9876543210fedcba98.png", .status = 404 },
        .{ .path = "/media/../media/" ++ name, .status = 404 },
    }) |case| {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url(case.path);
        try serve(&app, ht.req, ht.res);
        try ht.expectStatus(case.status);
        if (case.status == 200) {
            try ht.expectHeader("Content-Type", "image/png");
            try ht.expectBody("png data");
        }
    }
}
