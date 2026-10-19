//! OpenTelemetry traces, sent to a collector (Grafana Alloy) as OTLP/HTTP
//! JSON. Zig has no OpenTelemetry SDK; this is the small part of one that
//! the server uses.
//!
//! `Middleware` starts a server span for each request with `startRoot`.
//! Code below it starts child spans with `start`, without a request or an
//! exporter as an argument:
//!
//!     var span = trace.start("image.clean", .internal);
//!     defer span.end();
//!     span.set("image.bytes", data.len);
//!
//! The current span is a thread-local value: httpz runs each request from
//! start to end on one thread of its pool, so the spans of a request are on
//! one thread. Spans must end in the reverse order of their start (use
//! `defer`). Without a current span (no exporter, the command-line tools,
//! the tests), `start` returns a span that does nothing.
//!
//! `Span.end` encodes the span as JSON into the queue of the `Exporter`. A
//! thread of the exporter sends the queue in batches. If the collector is
//! not available, or the queue is full, spans are dropped: a request never
//! waits for the collector.

const std = @import("std");
const httpz = @import("httpz");

const log = std.log.scoped(.trace);

pub const TraceId = [16]u8;
pub const SpanId = [8]u8;

/// OTLP `SpanKind`.
pub const Kind = enum(u8) {
    internal = 1,
    server = 2,
    client = 3,
};

/// The trace and span ids of a span in a different process, from a
/// `traceparent` header.
pub const Parent = struct {
    trace_id: TraceId,
    span_id: SpanId,
};

/// The current span of a thread: the parent of the next `start`.
const Context = struct {
    exporter: *Exporter,
    trace_id: TraceId,
    span_id: SpanId,
};

threadlocal var current: ?Context = null;

/// The trace id of the current span of this thread, for log lines.
pub fn currentTraceId() ?TraceId {
    const ctx = current orelse return null;
    return ctx.trace_id;
}

/// Starts a span without a parent in this process, and makes it the current
/// span. `parent` is the span of the client, if it sent one. The caller
/// calls `end` on the same thread.
pub fn startRoot(exporter: *Exporter, name: []const u8, kind: Kind, parent: ?Parent) Span {
    const io = exporter.io;
    var trace_id: TraceId = undefined;
    if (parent) |p| trace_id = p.trace_id else randomId(io, &trace_id);
    return begin(.{ .exporter = exporter, .trace_id = trace_id, .span_id = undefined }, if (parent) |p| p.span_id else null, name, kind);
}

/// Starts a child span of the current span of this thread, and makes it the
/// current span. Without a current span, the span does nothing.
pub fn start(name: []const u8, kind: Kind) Span {
    const parent = current orelse return .{};
    return begin(parent, parent.span_id, name, kind);
}

fn begin(parent: Context, parent_span_id: ?SpanId, name: []const u8, kind: Kind) Span {
    var ctx = parent;
    randomId(ctx.exporter.io, &ctx.span_id);
    const prev = current;
    current = ctx;
    return .{
        .ctx = ctx,
        .prev = prev,
        .parent_span_id = parent_span_id,
        .name = name,
        .kind = kind,
        .start_ns = std.Io.Timestamp.now(ctx.exporter.io, .real).toNanoseconds(),
    };
}

/// Random bytes that are not all zero (all zero is not a valid id).
fn randomId(io: std.Io, id: []u8) void {
    while (true) {
        io.random(id);
        for (id) |b| if (b != 0) return;
    }
}

/// Longer strings in attributes are cut, so that a span has a maximum size
/// (see `max_span_size`).
pub const max_string_len = 1024;
pub const max_attributes = 16;

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,
};

pub const Attribute = struct {
    key: []const u8,
    value: Value,
};

pub const Span = struct {
    /// null for a span that does nothing.
    ctx: ?Context = null,
    /// The current span before this one, which `end` restores.
    prev: ?Context = null,
    parent_span_id: ?SpanId = null,
    name: []const u8 = "",
    kind: Kind = .internal,
    start_ns: i96 = 0,
    attributes: [max_attributes]Attribute = undefined,
    attribute_count: usize = 0,
    /// OTLP `Status`: an error, with a message, or unset.
    error_message: ?[]const u8 = null,

    /// Adds an attribute. `value` is a string, an integer or a bool. Strings
    /// must stay valid until `end`. Attributes after `max_attributes` are
    /// ignored.
    pub fn set(span: *Span, key: []const u8, value: anytype) void {
        if (span.ctx == null or span.attribute_count == max_attributes) return;
        const T = @TypeOf(value);
        const v: Value = switch (@typeInfo(T)) {
            .bool => .{ .bool = value },
            .int, .comptime_int => .{ .int = std.math.cast(i64, value) orelse std.math.maxInt(i64) },
            else => .{ .string = truncate(value) },
        };
        span.attributes[span.attribute_count] = .{ .key = key, .value = v };
        span.attribute_count += 1;
    }

    /// Changes the name, for example when the route is known only after the
    /// span started. `name` must stay valid until `end`.
    pub fn rename(span: *Span, name: []const u8) void {
        span.name = name;
    }

    /// Marks the span as failed. `message` must stay valid until `end`.
    pub fn fail(span: *Span, message: []const u8) void {
        span.error_message = truncate(message);
    }

    /// Ends the span, sends it to the queue of the exporter and makes the
    /// span before it current again.
    pub fn end(span: *Span) void {
        const ctx = span.ctx orelse return;
        current = span.prev;
        const end_ns = std.Io.Timestamp.now(ctx.exporter.io, .real).toNanoseconds();
        ctx.exporter.record(span, end_ns);
        span.ctx = null;
    }

    /// The span as an OTLP/JSON `Span` object.
    fn write(span: *const Span, w: *std.Io.Writer, end_ns: i96) std.Io.Writer.Error!void {
        const ctx = span.ctx.?;
        try w.print("{{\"traceId\":\"{x}\",\"spanId\":\"{x}\"", .{ &ctx.trace_id, &ctx.span_id });
        if (span.parent_span_id) |id| try w.print(",\"parentSpanId\":\"{x}\"", .{&id});
        try w.writeAll(",\"name\":");
        try writeString(w, span.name);
        try w.print(",\"kind\":{d},\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\",\"attributes\":[", .{ @backingInt(span.kind), span.start_ns, end_ns });
        try writeAttributes(w, span.attributes[0..span.attribute_count]);
        try w.writeByte(']');
        if (span.error_message) |message| {
            try w.writeAll(",\"status\":{\"code\":2,\"message\":");
            try writeString(w, message);
            try w.writeByte('}');
        }
        try w.writeByte('}');
    }
};

fn writeAttributes(w: *std.Io.Writer, attributes: []const Attribute) std.Io.Writer.Error!void {
    for (attributes, 0..) |a, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"key\":");
        try writeString(w, a.key);
        try w.writeAll(",\"value\":{");
        switch (a.value) {
            .string => |s| {
                try w.writeAll("\"stringValue\":");
                try writeString(w, s);
            },
            // OTLP/JSON encodes 64-bit integers as strings.
            .int => |n| try w.print("\"intValue\":\"{d}\"", .{n}),
            .bool => |b| try w.print("\"boolValue\":{}", .{b}),
        }
        try w.writeAll("}}");
    }
}

/// `s` without the bytes after `max_string_len`, cut at the start of a
/// UTF-8 sequence.
fn truncate(s: []const u8) []const u8 {
    if (s.len <= max_string_len) return s;
    var n: usize = max_string_len;
    while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
    return s[0..n];
}

/// `s` as a JSON string. JSON must be UTF-8, and text from a client can be
/// other bytes: then each byte above 0x7f becomes U+FFFD.
fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (std.unicode.utf8ValidateSlice(s)) return std.json.Stringify.encodeJsonString(s, .{}, w);
    try w.writeByte('"');
    for (s) |c| {
        if (c < 0x80) {
            try std.json.Stringify.encodeJsonStringChars(&.{c}, .{}, w);
        } else {
            try w.writeAll("\\ufffd");
        }
    }
    try w.writeByte('"');
}

/// Parses a W3C `traceparent` header (version 00):
/// `00-<32 hex trace id>-<16 hex span id>-<2 hex flags>`. Returns null for
/// a value that is not valid, as the specification requires. The sampled
/// flag is ignored: this server records all requests.
pub fn parseTraceparent(value: []const u8) ?Parent {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len < 55 or v[2] != '-' or v[35] != '-' or v[52] != '-') return null;
    // A later version can have more fields after the flags.
    if (std.mem.eql(u8, v[0..2], "00") and v.len != 55) return null;
    if (v.len > 55 and v[55] != '-') return null;
    var version: [1]u8 = undefined;
    _ = std.fmt.hexToBytes(&version, v[0..2]) catch return null;
    if (version[0] == 0xff) return null;
    var flags: [1]u8 = undefined;
    _ = std.fmt.hexToBytes(&flags, v[53..55]) catch return null;

    var parent: Parent = undefined;
    _ = std.fmt.hexToBytes(&parent.trace_id, v[3..35]) catch return null;
    _ = std.fmt.hexToBytes(&parent.span_id, v[36..52]) catch return null;
    // Upper-case hex is not valid.
    for (v[3..52]) |c| if (std.ascii.isUpper(c)) return null;
    if (std.mem.allEqual(u8, &parent.trace_id, 0) or std.mem.allEqual(u8, &parent.span_id, 0)) return null;
    return parent;
}

pub const Options = struct {
    /// The base URL of the collector, as in `OTEL_EXPORTER_OTLP_ENDPOINT`,
    /// for example `http://127.0.0.1:4319`. The spans go to `/v1/traces`.
    endpoint: []const u8,
    /// The `service.name` resource attribute.
    service_name: []const u8,
    /// Seconds between two sends, if the queue does not get full first.
    flush_interval_s: u32 = 5,
    /// Seconds for one send. A collector that does not answer in this time
    /// gets its send canceled, and the spans are dropped.
    send_timeout_s: u32 = 5,
};

/// Keeps ended spans in a queue, and sends them from its own thread.
pub const Exporter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// `endpoint` + `/v1/traces`.
    url: []const u8,
    /// The `resource` of each request, as JSON.
    resource: []const u8,
    flush_interval_s: u32,
    send_timeout_s: u32,

    mutex: std.Io.Mutex = .init,
    /// Signaled when the queue has `batch_size` spans, and by `destroy`.
    wake: std.Io.Condition = .init,
    /// The JSON of the queued spans, separated by commas.
    queue: std.ArrayList(u8) = .empty,
    queued: usize = 0,
    /// Spans dropped because the queue was full, since the last log line.
    dropped: usize = 0,
    stopping: bool = false,
    thread: ?std.Thread = null,
    /// The last send did not succeed: log the next result only when it
    /// changes, so a collector that is down does not fill the log.
    failing: bool = false,

    /// The thread sends when it has this number of spans.
    const batch_size = 256;
    /// The queue drops spans when it has this number of bytes (the collector
    /// is not available).
    const max_queue_size = 4 * 1024 * 1024;
    /// A span that is larger is dropped. With `max_attributes` strings of
    /// `max_string_len` characters, the JSON is smaller than this.
    const max_span_size = 32 * 1024;

    /// Makes an exporter and starts its thread.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Exporter {
        const self = try init(gpa, io, options);
        errdefer self.destroy();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Makes an exporter without a thread (for the tests).
    fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Exporter {
        const endpoint = std.mem.trimEnd(u8, options.endpoint, "/");
        const url = try std.fmt.allocPrint(gpa, "{s}/v1/traces", .{endpoint});
        errdefer gpa.free(url);
        _ = std.Uri.parse(url) catch return error.InvalidEndpoint;

        var resource: std.Io.Writer.Allocating = .init(gpa);
        errdefer resource.deinit();
        resource.writer.writeAll("{\"attributes\":[") catch return error.OutOfMemory;
        writeAttributes(&resource.writer, &.{
            .{ .key = "service.name", .value = .{ .string = options.service_name } },
        }) catch return error.OutOfMemory;
        resource.writer.writeAll("]}") catch return error.OutOfMemory;

        const self = try gpa.create(Exporter);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .url = url,
            .resource = try resource.toOwnedSlice(),
            .flush_interval_s = options.flush_interval_s,
            .send_timeout_s = options.send_timeout_s,
        };
        return self;
    }

    /// Sends the spans in the queue, stops the thread and frees the
    /// exporter. Call it after the last span ended. It waits a maximum of
    /// one send (`send_timeout_s`).
    pub fn destroy(self: *Exporter) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        self.mutex.unlock(io);
        self.wake.signal(io);
        if (self.thread) |t| t.join();

        self.queue.deinit(self.gpa);
        self.gpa.free(self.resource);
        self.gpa.free(self.url);
        self.gpa.destroy(self);
    }

    /// Adds the JSON of `span` to the queue, or drops it.
    fn record(self: *Exporter, span: *const Span, end_ns: i96) void {
        var buffer: [max_span_size]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        span.write(&w, end_ns) catch {
            self.drop();
            return;
        };
        const json = w.buffered();

        const io = self.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.queue.items.len + json.len + 1 > max_queue_size) {
            self.dropped += 1;
            return;
        }
        self.queue.ensureUnusedCapacity(self.gpa, json.len + 1) catch {
            self.dropped += 1;
            return;
        };
        if (self.queued > 0) self.queue.appendAssumeCapacity(',');
        self.queue.appendSliceAssumeCapacity(json);
        self.queued += 1;
        if (self.queued == batch_size) self.wake.signal(io);
    }

    fn drop(self: *Exporter) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.dropped += 1;
    }

    /// The thread: waits for a full batch or `flush_interval_s`, then sends
    /// the queue. After `destroy`, sends the rest and stops.
    fn run(self: *Exporter) void {
        const io = self.io;
        var client: std.http.Client = .{ .allocator = self.gpa, .io = io };
        defer client.deinit();
        // The spans in the request that is sent. The queue gets new spans in
        // the meantime.
        var batch: std.ArrayList(u8) = .empty;
        defer batch.deinit(self.gpa);
        var body: std.Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();

        while (true) {
            self.mutex.lockUncancelable(io);
            if (!self.stopping and self.queued < batch_size) {
                self.wake.waitTimeout(io, &self.mutex, .{ .duration = .{
                    .raw = .fromSeconds(self.flush_interval_s),
                    .clock = .awake,
                } }) catch {};
            }
            std.mem.swap(std.ArrayList(u8), &batch, &self.queue);
            const count = self.queued;
            self.queued = 0;
            const dropped = self.dropped;
            self.dropped = 0;
            const stopping = self.stopping;
            self.mutex.unlock(io);

            if (dropped > 0) log.warn("dropped {d} spans (the queue was full)", .{dropped});
            if (count > 0) self.send(&client, &body, batch.items, count);
            batch.clearRetainingCapacity();
            if (stopping) return;
        }
    }

    /// Sends `spans` (JSON objects separated by commas) in one request.
    fn send(self: *Exporter, client: *std.http.Client, body: *std.Io.Writer.Allocating, spans: []const u8, count: usize) void {
        body.clearRetainingCapacity();
        body.writer.print(
            \\{{"resourceSpans":[{{"resource":{s},"scopeSpans":[{{"scope":{{"name":"zig-web"}},"spans":[{s}]}}]}}]}}
        , .{ self.resource, spans }) catch {
            log.warn("dropped {d} spans (out of memory)", .{count});
            return;
        };

        const status = self.fetch(client, body.written()) catch |err| {
            if (!self.failing) log.warn("cannot send spans to {s}: {t}; dropping spans until it works again", .{ self.url, err });
            self.failing = true;
            return;
        };
        if (status.class() != .success) {
            if (!self.failing) log.warn("{s} answered {d} {s}; dropping spans until it works again", .{ self.url, @backingInt(status), status.phrase() orelse "" });
            self.failing = true;
            return;
        }
        if (self.failing) log.info("sending spans to {s} again", .{self.url});
        self.failing = false;
    }

    /// POSTs `body` to the collector, and stops after `send_timeout_s`.
    /// `std.http.Client` has no timeout, so the request runs as a separate
    /// task, which is canceled if it does not finish in time. The cancel
    /// interrupts a blocked connect, read or write.
    fn fetch(self: *Exporter, client: *std.http.Client, body: []const u8) !std.http.Status {
        const io = self.io;
        var done: std.Io.Event = .unset;
        var task = try io.concurrent(fetchTask, .{ io, client, self.url, body, &done });
        done.waitTimeout(io, .{ .duration = .{
            .raw = .fromSeconds(self.send_timeout_s),
            .clock = .awake,
        } }) catch {};
        if (!done.isSet()) {
            _ = task.cancel(io) catch {};
            return error.Timeout;
        }
        const result = try task.await(io);
        return result.status;
    }

    fn fetchTask(io: std.Io, client: *std.http.Client, url: []const u8, body: []const u8, done: *std.Io.Event) std.http.Client.FetchError!std.http.Client.FetchResult {
        defer done.set(io);
        return client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" } },
        });
    }
};

/// httpz middleware that makes a server span for each request. The spans
/// that the request starts below it (for example the database queries) are
/// its children. Without an exporter (`OTEL_EXPORTER_OTLP_ENDPOINT` is not
/// set), it does nothing.
///
/// A `traceparent` header from the client makes the span part of the
/// client's trace.
///
/// The span of a request that matched a route has the name of the route,
/// for example `POST /uploads/:id/delete`, and the `http.route` attribute, from
/// `req.route_path`. Other requests (404s) have only the method as the name.
pub const Middleware = struct {
    exporter: ?*Exporter,

    pub const Config = struct {
        exporter: ?*Exporter,
    };

    pub fn init(config: Config) !Middleware {
        return .{ .exporter = config.exporter };
    }

    pub fn execute(self: *const Middleware, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
        const exporter = self.exporter orelse return executor.next();
        const method = if (req.method == .OTHER) req.method_string else @tagName(req.method);
        const parent = if (req.header("traceparent")) |value| parseTraceparent(value) else null;

        var span = startRoot(exporter, method, .server, parent);
        defer span.end();
        span.set("http.request.method", method);
        span.set("url.path", req.url.path);
        if (req.header("user-agent")) |ua| span.set("user_agent.original", ua);
        // httpz finds the route before the middlewares run.
        if (req.route_path) |route| {
            span.set("http.route", route);
            if (std.fmt.allocPrint(req.arena, "{s} {s}", .{ method, route })) |name| span.rename(name) else |_| {}
        }

        executor.next() catch |err| {
            // `RequestLogger` turns errors into 500, so this occurs only for
            // an error in a middleware before it.
            span.fail(@errorName(err));
            return err;
        };

        span.set("http.response.status_code", res.status);
        // A 4xx is an error of the client, not of the server.
        if (res.status >= 500) span.fail(std.fmt.allocPrint(req.arena, "HTTP {d}", .{res.status}) catch "HTTP 5xx");
    }
};

const testing = std.testing;

test parseTraceparent {
    const p = parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").?;
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", &std.fmt.bytesToHex(p.trace_id, .lower));
    try testing.expectEqualStrings("00f067aa0ba902b7", &std.fmt.bytesToHex(p.span_id, .lower));
    // A later version can have more fields.
    try testing.expect(parseTraceparent("01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00-x") != null);

    const invalid = [_][]const u8{
        "",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-x",
        "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
        "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e473g-00f067aa0ba902b7-01",
        "00_4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
    };
    for (invalid) |v| try testing.expectEqual(null, parseTraceparent(v));
}

test writeString {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeString(&w, "a\"b\n\u{e9}");
    try testing.expectEqualStrings("\"a\\\"b\\n\u{e9}\"", w.buffered());

    w = .fixed(&buf);
    try writeString(&w, "/x\xff\"");
    try testing.expectEqualStrings("\"/x\\ufffd\\\"\"", w.buffered());
}

test truncate {
    const long = @as([max_string_len - 1]u8, @splat('a')) ++ "\u{e9}";
    // The 2-byte sequence does not fit: it is removed completely.
    try testing.expectEqual(max_string_len - 1, truncate(long).len);
    try testing.expectEqualStrings("short", truncate("short"));
}

test "spans: nesting, JSON and the queue" {
    const exporter = try Exporter.init(testing.allocator, testing.io, .{
        .endpoint = "http://127.0.0.1:4319/",
        .service_name = "test",
    });
    defer exporter.destroy();
    try testing.expectEqualStrings("http://127.0.0.1:4319/v1/traces", exporter.url);

    // Without a current span, spans do nothing.
    var none = start("none", .internal);
    none.set("ignored", 1);
    none.end();
    try testing.expectEqual(null, currentTraceId());

    const parent = parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").?;
    var root = startRoot(exporter, "GET", .server, parent);
    try testing.expectEqualSlices(u8, &parent.trace_id, &currentTraceId().?);
    {
        var child = start("SELECT", .client);
        defer child.end();
        child.set("db.query.text", "SELECT 1");
        child.set("rows", @as(usize, 3));
        child.set("cached", true);
        child.fail("QueryFailed");
        try testing.expectEqualSlices(u8, &root.ctx.?.span_id, &child.parent_span_id.?);
    }
    // `end` made the root current again.
    try testing.expectEqualSlices(u8, &root.ctx.?.span_id, &current.?.span_id);
    root.rename("GET /items/:id");
    root.end();
    try testing.expectEqual(null, currentTraceId());

    try testing.expectEqual(2, exporter.queued);
    const json = exporter.queue.items;
    // The child ended first.
    try testing.expect(std.mem.startsWith(u8, json, "{\"traceId\":\"4bf92f3577b34da6a3ce929d0e0e4736\",\"spanId\":\""));
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"SELECT\",\"kind\":3,") != null);
    try testing.expect(std.mem.indexOf(u8, json, "{\"key\":\"db.query.text\",\"value\":{\"stringValue\":\"SELECT 1\"}},{\"key\":\"rows\",\"value\":{\"intValue\":\"3\"}},{\"key\":\"cached\",\"value\":{\"boolValue\":true}}]") != null);
    try testing.expect(std.mem.indexOf(u8, json, ",\"status\":{\"code\":2,\"message\":\"QueryFailed\"}}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "},{\"traceId\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"parentSpanId\":\"00f067aa0ba902b7\",\"name\":\"GET /items/:id\",\"kind\":2,") != null);

    // The full queue drops spans.
    exporter.queue.items.len = 0;
    exporter.queued = 0;
    try exporter.queue.appendNTimes(testing.allocator, ' ', Exporter.max_queue_size);
    var dropped = startRoot(exporter, "GET", .server, null);
    dropped.end();
    try testing.expectEqual(1, exporter.dropped);
}

test Middleware {
    const exporter = try Exporter.init(testing.allocator, testing.io, .{
        .endpoint = "http://127.0.0.1:4319",
        .service_name = "test",
    });
    defer exporter.destroy();

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/items/42");
    // As httpz sets it for a request to the route `/items/:id`.
    ht.req.route_path = "/items/:id";
    const Executor = struct {
        res: *httpz.Response,
        fn next(self: *@This()) !void {
            // A child span, in the request.
            var span = start("SELECT", .client);
            defer span.end();
            self.res.status = 503;
        }
    };
    const mw = try Middleware.init(.{ .exporter = exporter });
    var executor: Executor = .{ .res = ht.res };
    try mw.execute(ht.req, ht.res, &executor);
    try testing.expectEqual(null, currentTraceId());

    try testing.expectEqual(2, exporter.queued);
    const json = exporter.queue.items;
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"SELECT\",\"kind\":3,") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"GET /items/:id\",\"kind\":2,") != null);
    try testing.expect(std.mem.indexOf(u8, json, "{\"key\":\"http.route\",\"value\":{\"stringValue\":\"/items/:id\"}}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "{\"key\":\"http.response.status_code\",\"value\":{\"intValue\":\"503\"}}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"status\":{\"code\":2,\"message\":\"HTTP 503\"}") != null);

    // A request that matched no route has only the method as the name.
    exporter.queue.clearRetainingCapacity();
    exporter.queued = 0;
    ht.req.route_path = null;
    try mw.execute(ht.req, ht.res, &executor);
    try testing.expect(std.mem.indexOf(u8, exporter.queue.items, "\"name\":\"GET\",\"kind\":2,") != null);
    try testing.expect(std.mem.indexOf(u8, exporter.queue.items, "http.route") == null);
}
