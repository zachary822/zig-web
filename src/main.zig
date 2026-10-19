const std = @import("std");
const httpz = @import("httpz");
const mustache = @import("mustache");
const App = @import("App.zig");
const RequestLogger = @import("middleware/RequestLogger.zig");
const Head = @import("middleware/Head.zig");
const SecurityHeaders = @import("middleware/SecurityHeaders.zig");
const Htmx = @import("middleware/Htmx.zig");
const current_user = @import("middleware/current_user.zig");
const Static = @import("static.zig");
const config = @import("config.zig");
const db = @import("db.zig");
const Csrf = @import("middleware/csrf.zig");
const PasswordHasher = @import("password.zig");
const Session = @import("middleware/session.zig");
const auth = @import("routes/auth.zig");
const home = @import("routes/home.zig");
const health = @import("routes/health.zig");
const library = @import("library.zig");
const media = @import("media.zig");
const upload = @import("upload.zig");
const uploads = @import("routes/uploads.zig");
const trace = @import("trace.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
};

/// True when stderr goes to the systemd journal (systemd sets
/// `JOURNAL_STREAM`). Set at the start of `main`, before other threads start.
var log_to_journal = false;

/// Same as `std.log.defaultLog`, but prefixes each line with an ISO 8601 UTC
/// timestamp, for example `2026-10-16T19:48:21Z`. In a request with a trace,
/// the line ends with ` trace_id=<32 hex digits>`, so Grafana can link the
/// line in Loki to the trace in Tempo.
///
/// To the journal, each line also starts with its priority, in the format of
/// sd-daemon(3), for example `<4>` for `warn`. journald removes it and
/// stores the priority (`SyslogLevelPrefix=` is on by default); without it,
/// all lines from stderr have the priority `info`.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);

    const now: std.time.epoch.EpochSeconds = .{
        .secs = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
    };
    const year_day = now.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = now.getDaySeconds();

    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    if (log_to_journal) {
        const priority: u8 = switch (level) {
            .err => 3,
            .warn => 4,
            .info => 6,
            .debug => 7,
        };
        stderr.writer.print("<{d}>", .{priority}) catch return;
    }
    stderr.writer.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z ", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch return;
    if (trace.currentTraceId()) |id| {
        // `defaultLogFileTerminal` ends the line with "\n": put the trace
        // id before it.
        std.log.defaultLogFileTerminal(level, scope, format ++ " trace_id={x}", args ++ .{&id}, stderr) catch {};
    } else {
        std.log.defaultLogFileTerminal(level, scope, format, args, stderr) catch {};
    }
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    // Before any thread starts, so that all threads inherit the mask.
    const shutdown_signals = blockShutdownSignals();
    log_to_journal = init.environ_map.contains("JOURNAL_STREAM");

    var diag: config.Diagnostic = .{};
    config.loadDotEnv(init.io, allocator, init.environ_map, ".env", &diag) catch |err| {
        std.log.err(".env line {d}: {t}", .{ diag.line, err });
        return 1;
    };
    const cfg = config.fromEnv(config.Config, init.environ_map, &diag) catch |err| {
        std.log.err("{s}=\"{s}\": {t}", .{ diag.key, diag.value, err });
        return 1;
    };
    const ip = std.Io.net.IpAddress.parse(cfg.host, cfg.port) catch |err| {
        std.log.err("HOST=\"{s}\" is not an IP address: {t}", .{ cfg.host, err });
        return 1;
    };

    var templates: mustache.Library = .init(allocator, init.io);
    defer templates.deinit();
    if (cfg.reload_templates) {
        std.log.info("reloading templates from {s}/ for each request", .{cfg.template_dir});
    } else {
        App.loadTemplates(init.io, &templates, cfg.template_dir) catch |err| {
            std.log.err("cannot load templates from {s}/: {t}", .{ cfg.template_dir, err });
            return 1;
        };
    }

    // Also without `serve_static`: the `{{#static}}` lambda needs the hashed
    // names of the files.
    var static = Static.init(init.io, allocator, cfg.static_dir, .{
        .reload = cfg.reload_static,
        .serve = cfg.serve_static,
        .url_prefix = cfg.static_url,
    }) catch |err| switch (err) {
        error.InvalidUrlPrefix => {
            std.log.err("STATIC_URL must start and end with / and cannot be only /: {s}", .{cfg.static_url});
            return 1;
        },
        else => {
            std.log.err("cannot load static files from {s}/: {t}", .{ cfg.static_dir, err });
            return 1;
        },
    };
    defer static.deinit();
    if (cfg.reload_static) {
        if (cfg.serve_static) std.log.info("serving {s} from {s}/, reloading for each request", .{ static.url_prefix, cfg.static_dir });
    } else if (cfg.serve_static) {
        std.log.info("serving {s} from {s}/, {d} files in memory", .{ static.url_prefix, cfg.static_dir, static.count() });
    } else {
        std.log.info("{d} hashed static files from {s}/ (run collectstatic for nginx)", .{ static.count(), cfg.static_dir });
    }

    // Uploaded files. With `serve_static`, `uploads.serve` reads them from
    // disk for each request.
    var media_storage = media.Storage.init(init.io, allocator, cfg.media_dir, cfg.media_url) catch |err| switch (err) {
        error.InvalidUrlPrefix => {
            std.log.err("MEDIA_URL must start and end with / and cannot be only /: {s}", .{cfg.media_url});
            return 1;
        },
        else => {
            std.log.err("cannot open {s}/ (MEDIA_DIR): {t}", .{ cfg.media_dir, err });
            return 1;
        },
    };
    defer media_storage.deinit(allocator);
    if (cfg.serve_static) std.log.info("serving {s} from {s}/", .{ media_storage.url_prefix, cfg.media_dir });

    var db_pool: ?*db.Pool = null;
    defer if (db_pool) |pool| {
        pool.destroy();
        db.libraryEnd();
    };
    if (cfg.database_url) |url| {
        db_pool = createDbPool(init, cfg, url) orelse return 1;
    } else {
        std.log.info("no database configured (DATABASE_URL is not set)", .{});
    }

    const csrf = Csrf.init(init.io, cfg.secret_key, cfg.cookie_secure) catch |err| {
        std.log.err("SECRET_KEY: {t}", .{err});
        return 1;
    };
    const session: Session = .init(init.io, cfg.cookie_secure);
    if (cfg.secret_key == null) {
        std.log.warn("SECRET_KEY is not set: using a random key, so CSRF tokens become invalid at each restart", .{});
    }

    if (cfg.password_hash_concurrency == 0) {
        std.log.err("PASSWORD_HASH_CONCURRENCY must be at least 1", .{});
        return 1;
    }
    var passwords: PasswordHasher = .init(init.io, init.gpa, .{ .max_concurrent = cfg.password_hash_concurrency });

    // Before `server`, so that `destroy` runs after `server.deinit`: no
    // request ends a span after the exporter is gone.
    var exporter: ?*trace.Exporter = null;
    defer if (exporter) |e| e.destroy();
    if (cfg.otel_exporter_otlp_endpoint) |endpoint| {
        exporter = trace.Exporter.create(allocator, init.io, .{
            .endpoint = endpoint,
            .service_name = cfg.otel_service_name,
        }) catch |err| blk: {
            // Traces are optional: the server starts without them.
            std.log.err("OTEL_EXPORTER_OTLP_ENDPOINT=\"{s}\": {t}; no traces", .{ endpoint, err });
            break :blk null;
        };
        if (exporter) |e| std.log.info("sending traces to {s} as {s}", .{ e.url, cfg.otel_service_name });
    }

    var app: App = .{
        .io = init.io,
        .template_dir = cfg.template_dir,
        .templates = if (cfg.reload_templates) null else &templates,
        .db = db_pool,
        .csrf = &csrf,
        .passwords = &passwords,
        .session = &session,
        .static = &static,
        .media = &media_storage,
    };
    var server = try httpz.Server(*App).init(init.io, allocator, .{
        .address = .{ .ip = ip },
        .request = .{
            // Request line and headers. The default of 4 KB is small for
            // browsers with cookies; this matches nginx's default.
            .buffer_size = 8 * 1024,
            // Form fields to parse, for the CSRF token in form posts.
            .max_form_count = 32,
            // Uploads: the file and the CSRF token.
            .max_multiform_count = 4,
            // For all requests: the largest upload of all upload routes
            // (see upload.zig); now only the library. nginx limits requests
            // to 1 MiB, except uploads (deploy/nginx/zig_web.conf).
            .max_body_size = upload.requestSize(library.max_size),
        },
        .timeout = .{
            // Seconds to send a complete request (protects against slow clients).
            .request = 10,
            // Seconds an idle keepalive connection stays open. Longer than
            // nginx's upstream keepalive_timeout (60s), so nginx closes first.
            .keepalive = 75,
            .request_count = 1000,
        },
    }, &app);
    defer server.deinit();

    // Middlewares given to the router config apply to all routes, and to
    // requests that do not match a route (404).
    // The first middleware is the outermost one. `Head` runs last on the
    // response, so the logger records the size of the body before `Head`
    // removes it, and `Head` also sees the 500 response that the logger makes
    // from an error. `trace.Middleware` is outside the logger, so that the
    // logger's lines have the trace id, and the span has the status of that
    // 500.
    const head = try server.middleware(Head, .{});
    const tracing = try server.middleware(trace.Middleware, .{ .exporter = exporter });
    const request_logger = try server.middleware(RequestLogger, .{ .io = init.io });
    const security_headers = try server.middleware(SecurityHeaders, .{});
    const csrf_check = try server.middleware(Csrf.Middleware, .{ .csrf = &csrf });
    // Last, so that it sees the responses of all actions as they made them.
    const htmx = try server.middleware(Htmx, .{});
    const router = try server.router(.{ .middlewares = &.{ head, tracing, request_logger, security_headers, csrf_check, htmx } });
    // Pages: `Session.Middleware` loads the session (the user id and the
    // data), then `current_user.Middleware` loads the user, for
    // `App.currentUser` and the page header. They run after the middlewares
    // above. Static files and the health check do not need them.
    const sessions = try server.middleware(Session.Middleware, .{ .session = &session, .pool = db_pool });
    const users = try server.middleware(current_user.Middleware(App.User), .{ .pool = db_pool });
    var pages = router.group("", .{ .middlewares = &.{ sessions, users } });
    pages.get("/", home.index, .{});
    pages.get("/login", auth.loginForm, .{});
    pages.post("/login", auth.login, .{});
    pages.post("/logout", auth.logout, .{});
    pages.get("/uploads", uploads.list, .{});
    pages.post("/uploads", uploads.create, .{});
    pages.post("/uploads/:id/delete", uploads.delete, .{});
    router.get("/healthz", health.healthz, .{});
    if (cfg.serve_static) {
        static.register(*App, router);
        router.get(media_storage.route, uploads.serve, .{});
        router.head(media_storage.route, uploads.serve, .{});
    }

    const signal_thread = try std.Thread.spawn(.{}, stopOnSignal, .{ shutdown_signals, &server });
    signal_thread.detach();

    std.log.info("listening http://{f}/", .{ip});

    // Blocks until the signal thread calls `server.stop()`, which finishes
    // the requests in progress.
    try server.listen();
    std.log.info("stopped", .{});
    return 0;
}

/// Creates the database pool and connects one time to report problems early.
/// The server also starts when the database cannot be reached: requests that
/// need it get 500 until it is back. Returns null (after logging why) when
/// the configuration itself is not valid.
fn createDbPool(init: std.process.Init, cfg: config.Config, url: []const u8) ?*db.Pool {
    if (!db.enabled) {
        std.log.err("DATABASE_URL is set, but this build has no MariaDB support (install libmariadb and build with -Ddb=true)", .{});
        return null;
    }
    // The URL contains the password, so it is never logged.
    const connection = db.parseUrl(init.arena.allocator(), url) catch |err| {
        std.log.err("DATABASE_URL is not valid: {t}", .{err});
        return null;
    };
    if (cfg.db_pool_size == 0) {
        std.log.err("DB_POOL_SIZE must be at least 1", .{});
        return null;
    }

    db.libraryInit() catch |err| {
        std.log.err("cannot initialize the MariaDB library: {t}", .{err});
        return null;
    };
    const pool = db.Pool.create(init.gpa, init.io, .{
        .connection = connection,
        .pool_size = cfg.db_pool_size,
        .acquire_timeout_ms = cfg.db_pool_timeout_ms,
        .conn_max_age_s = cfg.db_conn_max_age_s,
    }) catch |err| {
        std.log.err("cannot create the database pool: {t}", .{err});
        db.libraryEnd();
        return null;
    };

    const target = connection.socket orelse connection.host;
    if (pool.acquire()) |conn| {
        conn.release();
        std.log.info("database {s}@{s}/{s}, pool size {d}", .{ connection.user, target, connection.database, cfg.db_pool_size });
    } else |err| {
        std.log.warn("database {s}@{s}/{s} not reachable ({t}); requests that need it get 500 until it is back", .{ connection.user, target, connection.database, err });
    }
    return pool;
}

/// Blocks SIGINT and SIGTERM in the calling thread (and so in all threads it
/// starts later). `stopOnSignal` receives them with `sigwait`, so the
/// server is stopped by normal code and not by a signal handler.
fn blockShutdownSignals() std.posix.sigset_t {
    var set = std.posix.sigemptyset();
    std.posix.sigaddset(&set, .INT);
    std.posix.sigaddset(&set, .TERM);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &set, null);
    return set;
}

/// Waits for SIGINT (Ctrl+C) or SIGTERM (`systemctl stop` and `restart`) and
/// stops the server. This is the only call to `server.stop()`: a second call
/// would close the listening socket again.
///
/// A signal in the short time before `listen()` is ready has no effect. The
/// systemd unit limits this case with `TimeoutStopSec`.
fn stopOnSignal(signals: std.posix.sigset_t, server: *httpz.Server(*App)) void {
    var set = signals;
    var sig: c_int = 0;
    while (std.c.sigwait(&set, &sig) != 0) {}
    std.log.info("received signal {d}, shutting down", .{sig});
    server.stop();
}

test {
    _ = Static;
    _ = config;
    _ = RequestLogger;
    _ = trace;
    _ = Head;
    _ = SecurityHeaders;
    _ = Htmx;
    _ = db;
    _ = Csrf;
    _ = PasswordHasher;
    _ = Session;
    _ = home;
    _ = library;
    _ = media;
    _ = upload;
    _ = uploads;
    _ = @import("image.zig");
    _ = @import("flash.zig");
    _ = current_user;
    _ = @import("form.zig");
    _ = health;
    _ = auth;
}
