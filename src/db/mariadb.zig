//! MariaDB connection pool and typed queries on top of MariaDB Connector/C.
//!
//! Thread safety: the library is initialized one time (`libraryInit`) before
//! other threads start, and each connection is used by one thread at a time
//! (the pool gives a connection to one caller until it is released).
//!
//! Each connection keeps its prepared statements, by SQL text, and uses them
//! again: a statement from the cache needs one round trip (execute), not two
//! (prepare and execute). The cache is cleared when the connection closes.
//! The number of statements is limited, because all SQL is comptime.
//!
//! In a request with a trace (see `trace.zig`), `Pool.acquire`, `exec` and
//! `query` make spans.

const std = @import("std");
const c = @import("mariadb");
const common = @import("common.zig");
const trace = @import("../trace.zig");

const Allocator = std.mem.Allocator;
const Error = common.Error;
const ExecResult = common.ExecResult;

const log = std.log.scoped(.db);

/// A connection that was idle for longer than this is checked with
/// `mysql_ping` before it is used again.
const ping_after_idle_s = 30;

/// Seconds for connecting, and for each read and write on a connection. A
/// database that stops answering cannot block a request for longer.
const connect_timeout_s: c_uint = 5;
const io_timeout_s: c_uint = 30;

/// Sent by the client library after each connect. TIMESTAMP values and
/// `NOW()` are shown in UTC, not in the time zone of the server, so dates do
/// not change when the server changes. The server stops a statement after
/// `max_statement_time` seconds. This is less than `io_timeout_s`, so the
/// server stops the statement before the client closes the connection (the
/// server does not stop a statement when the client goes away).
const init_command = std.fmt.comptimePrint(
    \\SET time_zone = '+00:00', max_statement_time = {d}
, .{io_timeout_s - 5});

pub fn libraryInit() !void {
    if (c.mysql_server_init(0, null, null) != 0) return error.DbLibraryInit;
}

pub fn libraryEnd() void {
    c.mysql_server_end();
}

pub const Pool = struct {
    gpa: Allocator,
    io: std.Io,
    options: common.Options,
    mutex: std.Io.Mutex = .init,
    /// Signaled when a connection is released.
    available: std.Io.Condition = .init,
    conns: []Conn,
    /// Stack of free connections; `free[0..free_len]` are free.
    free: []*Conn,
    free_len: usize,

    /// Creates a pool. No connection is opened until it is first needed, so
    /// this works when the database is not reachable. Each `acquire` connects
    /// again as necessary, so requests work again when the database is back.
    pub fn create(gpa: Allocator, io: std.Io, options: common.Options) !*Pool {
        std.debug.assert(options.pool_size > 0);
        const pool = try gpa.create(Pool);
        errdefer gpa.destroy(pool);
        const conns = try gpa.alloc(Conn, options.pool_size);
        errdefer gpa.free(conns);
        const free = try gpa.alloc(*Conn, options.pool_size);

        pool.* = .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .conns = conns,
            .free = free,
            .free_len = conns.len,
        };
        for (conns, free) |*conn, *slot| {
            conn.* = .{ .pool = pool };
            slot.* = conn;
        }
        return pool;
    }

    /// Closes all connections. All connections must be released.
    pub fn destroy(pool: *Pool) void {
        std.debug.assert(pool.free_len == pool.conns.len);
        for (pool.conns) |*conn| conn.deinit();
        pool.gpa.free(pool.free);
        pool.gpa.free(pool.conns);
        pool.gpa.destroy(pool);
    }

    /// Takes a connection from the pool, and connects it if necessary. Waits
    /// up to `acquire_timeout_ms` if all connections are in use. Call
    /// `Conn.release` when done.
    pub fn acquire(pool: *Pool) Error!*Conn {
        var span = trace.start("db.pool.acquire", .internal);
        defer span.end();
        return pool.acquireConn() catch |err| {
            span.fail(@errorName(err));
            return err;
        };
    }

    fn acquireConn(pool: *Pool) Error!*Conn {
        const io = pool.io;
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(pool.options.acquire_timeout_ms),
            .clock = .awake,
        } };
        const deadline = timeout.toDeadline(io);

        pool.mutex.lockUncancelable(io);
        while (pool.free_len == 0) {
            pool.available.waitTimeout(io, &pool.mutex, deadline) catch |err| {
                // A connection released at the deadline can be used.
                if (pool.free_len > 0) break;
                pool.mutex.unlock(io);
                switch (err) {
                    error.Timeout => {
                        log.warn("no free connection after {d}ms", .{pool.options.acquire_timeout_ms});
                        return error.PoolTimeout;
                    },
                    error.Canceled => return error.Canceled,
                }
            };
        }
        pool.free_len -= 1;
        const conn = pool.free[pool.free_len];
        pool.mutex.unlock(io);

        // A different request must not continue an open transaction.
        // `release` rolls back, so this occurs only after a bug.
        if (conn.inTransaction()) {
            log.err("connection from the pool has an open transaction; rolling back", .{});
            conn.rollback();
        }
        conn.ensureConnected() catch |err| {
            conn.release();
            return err;
        };
        return conn;
    }
};

pub const Conn = struct {
    pool: *Pool,
    mysql: ?*c.MYSQL = null,
    last_used: std.Io.Timestamp = .zero,
    /// When `connect` opened the connection, for `Options.conn_max_age_s`.
    connected_at: std.Io.Timestamp = .zero,
    /// Prepared statements by SQL text (see `prepare`). The keys are the
    /// comptime SQL strings, so they are not copied.
    stmts: std.StringHashMapUnmanaged(*c.MYSQL_STMT) = .empty,
    /// Set by `begin`, cleared by `commit` and `rollback`. Also set when the
    /// connection breaks in a transaction that SQL started. A disconnect does
    /// not clear it: the server undid the transaction, so the statements
    /// after it must fail, and not run with autocommit (see `handle`).
    in_transaction: bool = false,
    /// Set when a statement in the transaction from `begin` fails; cleared by
    /// `rollback`. The server can undo the full transaction after an error
    /// (for example after a deadlock), and the statements after it would
    /// then run with autocommit. Thus, as in Django, all statements and
    /// `commit` fail until `rollback`.
    failed_in_transaction: bool = false,

    /// Closes the connection and its prepared statements, and frees the
    /// statement cache. Only for `Pool.destroy`: the connection cannot be
    /// used again.
    fn deinit(conn: *Conn) void {
        conn.disconnect();
        conn.stmts.deinit(conn.pool.gpa);
        conn.* = undefined;
    }

    /// Returns the connection to the pool.
    pub fn release(conn: *Conn) void {
        if (conn.inTransaction()) {
            log.err("connection released with an open transaction; rolling back", .{});
            conn.rollback();
        }
        const pool = conn.pool;
        const io = pool.io;
        conn.last_used = .now(io, .awake);
        pool.mutex.lockUncancelable(io);
        pool.free[pool.free_len] = conn;
        pool.free_len += 1;
        pool.mutex.unlock(io);
        pool.available.signal(io);
    }

    /// Runs a statement that returns no rows (INSERT, UPDATE, DELETE, ...).
    /// `args` is a tuple with one value for each `?` in `sql`: integers,
    /// floats, `bool`, enums (as their names), strings (utf8mb4 text),
    /// `common.Binary` (bytes, see `common.binary`), `null`, and optionals.
    /// `sql` is comptime in `exec`, `query` and `one`, so values go only
    /// through `args`. By convention, `sql` is a multiline string literal.
    pub fn exec(conn: *Conn, comptime sql: []const u8, args: anytype) Error!ExecResult {
        var span = startSpan(sql);
        defer span.end();
        const stmt = conn.run(sql, args) catch |err| {
            span.fail(@errorName(err));
            return err;
        };
        const result: ExecResult = .{
            .affected_rows = c.mysql_stmt_affected_rows(stmt),
            .insert_id = c.mysql_stmt_insert_id(stmt),
        };
        span.set("db.response.affected_rows", result.affected_rows);
        return result;
    }

    /// Runs a query and returns all rows as `T`, a struct with one field for
    /// each column, in order. Field types: integers, floats, `bool`, enums
    /// (from strings), `[]const u8` (text, or the bytes of a binary column),
    /// `common.Binary`, `[N]u8` (a binary value of exactly N bytes, for
    /// example a hash), and optionals of these for NULL columns. The rows and
    /// their strings are allocated with `arena`.
    pub fn query(conn: *Conn, comptime T: type, arena: Allocator, comptime sql: []const u8, args: anytype) Error![]T {
        var span = startSpan(sql);
        defer span.end();
        const rows = conn.queryRows(T, arena, sql, args) catch |err| {
            span.fail(@errorName(err));
            return err;
        };
        span.set("db.response.returned_rows", rows.len);
        return rows;
    }

    fn queryRows(conn: *Conn, comptime T: type, arena: Allocator, comptime sql: []const u8, args: anytype) Error![]T {
        const stmt = try conn.run(sql, args);
        errdefer conn.dropStmt(sql);

        const info = @typeInfo(T).@"struct";
        const n = info.field_names.len;
        if (c.mysql_stmt_field_count(stmt) != n) {
            log.err("query returns {d} columns, {s} has {d} fields: {s}", .{ c.mysql_stmt_field_count(stmt), @typeName(T), n, sql });
            return error.QueryFailed;
        }

        var columns: [n]Column = @splat(.{});
        var binds: [n]c.MYSQL_BIND = @splat(std.mem.zeroes(c.MYSQL_BIND));
        inline for (info.field_types, &columns, &binds) |Field, *column, *bind| {
            column.bind(Base(Field), bind);
        }
        if (c.mysql_stmt_bind_result(stmt, &binds) != 0) return conn.stmtError(stmt, sql);
        if (c.mysql_stmt_store_result(stmt) != 0) return conn.stmtError(stmt, sql);

        var rows: std.ArrayList(T) = .empty;
        while (true) {
            switch (c.mysql_stmt_fetch(stmt)) {
                0, c.MYSQL_DATA_TRUNCATED => {},
                c.MYSQL_NO_DATA => break,
                else => return conn.stmtError(stmt, sql),
            }
            var row: T = undefined;
            inline for (info.field_names, info.field_types, &columns, 0..) |name, Field, *column, i| {
                @field(row, name) = column.read(Field, arena, stmt, i) catch |err| {
                    if (err == error.QueryFailed) log.err("column {d} ({s}.{s}) cannot be read as {s}: {s}", .{ i, @typeName(T), name, @typeName(Field), sql });
                    return err;
                };
            }
            try rows.append(arena, row);
        }
        // The statement stays in the cache; only its rows are freed.
        _ = c.mysql_stmt_free_result(stmt);
        return rows.items;
    }

    /// Like `query`, but returns only the first row, or null if there is none.
    pub fn one(conn: *Conn, comptime T: type, arena: Allocator, comptime sql: []const u8, args: anytype) Error!?T {
        const rows = try conn.query(T, arena, sql, args);
        return if (rows.len == 0) null else rows[0];
    }

    /// Runs SQL text with one or more statements separated by `;`, without
    /// parameters, for example a migration file. Needs a pool with
    /// `multi_statements`. Stops at the first statement that fails; the
    /// earlier ones stay applied, because MariaDB commits schema changes
    /// immediately.
    pub fn execScript(conn: *Conn, sql: []const u8) Error!void {
        const mysql = try conn.handle();
        if (c.mysql_real_query(mysql, sql.ptr, @intCast(sql.len)) != 0) return conn.connError();
        while (true) {
            // Read and free the result of each statement (for example of a
            // SELECT), so the connection can be used again.
            const result = c.mysql_store_result(mysql);
            if (result != null) {
                c.mysql_free_result(result);
            } else if (c.mysql_field_count(mysql) != 0) {
                return conn.connError();
            }
            switch (c.mysql_next_result(mysql)) {
                0 => {},
                -1 => return,
                else => return conn.connError(),
            }
        }
    }

    /// Starts a transaction. Changes on this connection are not visible to
    /// other connections until `commit`. Call `commit` or `rollback` before
    /// `release`. MariaDB commits CREATE, ALTER and DROP immediately, also in
    /// a transaction. Transactions cannot be nested: MariaDB would commit the
    /// open one.
    pub fn begin(conn: *Conn) Error!void {
        if (conn.inTransaction()) {
            log.err("begin: a transaction is already open", .{});
            return error.QueryFailed;
        }
        const sql =
            \\START TRANSACTION
        ;
        const mysql = try conn.handle();
        if (c.mysql_real_query(mysql, sql, sql.len) != 0) {
            // As in `prepare`: no statement ran, and no transaction is open,
            // so it is safe to connect again and try one more time.
            if (!isConnectionError(c.mysql_errno(mysql))) return conn.connError();
            log.warn("connection lost ({s}), connecting again", .{std.mem.span(c.mysql_error(mysql))});
            conn.disconnect();
            try conn.connect();
            if (c.mysql_real_query(conn.mysql.?, sql, sql.len) != 0) return conn.connError();
        }
        conn.in_transaction = true;
    }

    /// Makes the changes of the transaction permanent. If this returns an
    /// error, call `rollback`.
    pub fn commit(conn: *Conn) Error!void {
        if (c.mysql_commit(try conn.handle()) != 0) return conn.connError();
        conn.in_transaction = false;
    }

    /// Undoes the changes of the transaction, and lets the connection run
    /// statements again after an error in it. If that is not possible, the
    /// connection is closed: the server then undoes the changes, and the pool
    /// does not give a connection with an open transaction to a different
    /// request.
    pub fn rollback(conn: *Conn) void {
        conn.in_transaction = false;
        conn.failed_in_transaction = false;
        const mysql = conn.mysql orelse return;
        if (c.mysql_rollback(mysql) != 0) {
            log.err("rollback: {s} ({d}); closing the connection", .{ std.mem.span(c.mysql_error(mysql)), c.mysql_errno(mysql) });
            conn.disconnect();
        }
    }

    /// A client span for the statement `sql`, named by its first word (the
    /// operation, for example `SELECT`).
    fn startSpan(comptime sql: []const u8) trace.Span {
        var span = trace.start(comptime operationName(sql), .client);
        span.set("db.system.name", "mariadb");
        span.set("db.operation.name", comptime operationName(sql));
        span.set("db.query.text", sql);
        return span;
    }

    /// Logs the error of the last non-prepared command. If the connection is
    /// broken, it is closed, so the next `acquire` connects again.
    fn connError(conn: *Conn) Error {
        const mysql = conn.mysql.?;
        const errno = c.mysql_errno(mysql);
        log.err("{s} ({d})", .{ std.mem.span(c.mysql_error(mysql)), errno });
        return conn.failed(errno);
    }

    /// The error for `errno`, after a command failed. Closes a broken
    /// connection, and marks a transaction as failed (see
    /// `failed_in_transaction`).
    fn failed(conn: *Conn, errno: c_uint) Error {
        if (isConnectionError(errno)) {
            // The server undid the transaction. For a transaction that SQL
            // started, this makes the statements after it fail too (see
            // `handle`). The server status is from the last reply, which
            // came before the error.
            if (conn.inTransaction()) conn.in_transaction = true;
            conn.disconnect();
            return error.DbUnavailable;
        }
        if (conn.in_transaction) conn.failed_in_transaction = true;
        return error.QueryFailed;
    }

    /// Prepares `sql` (or takes it from the cache), binds `args` and executes
    /// it. The statement stays in the cache. If the caller gets an error
    /// after this, it calls `dropStmt`.
    fn run(conn: *Conn, sql: []const u8, args: anytype) Error!*c.MYSQL_STMT {
        // For the checks in `handle`: a statement from the cache does not
        // call it.
        _ = try conn.handle();
        const stmt = try conn.prepare(sql);
        errdefer conn.dropStmt(sql);

        const n = @typeInfo(@TypeOf(args)).@"struct".field_names.len;
        if (c.mysql_stmt_param_count(stmt) != n) {
            log.err("query has {d} parameters, {d} given: {s}", .{ c.mysql_stmt_param_count(stmt), n, sql });
            return error.QueryFailed;
        }
        var values: [n]ParamValue = @splat(.{});
        var binds: [n]c.MYSQL_BIND = @splat(std.mem.zeroes(c.MYSQL_BIND));
        inline for (0..n) |i| bindParam(&binds[i], &values[i], args[i]);
        if (n > 0 and c.mysql_stmt_bind_param(stmt, &binds) != 0) return conn.stmtError(stmt, sql);

        if (c.mysql_stmt_execute(stmt) != 0) return conn.stmtError(stmt, sql);
        return stmt;
    }

    /// Returns the prepared statement for `sql` from the cache, or prepares
    /// it and adds it to the cache. `sql` is the key, so it must stay valid
    /// as long as the connection (all callers give comptime strings).
    ///
    /// When `sql` is not in the cache, prepare is the first command, so a
    /// connection error here means that the connection broke while it was
    /// idle, for example because the database restarted. No statement ran,
    /// so it is safe to connect again and try one more time, but not in a
    /// transaction: the server undid it when the connection broke. A
    /// statement from the cache gets no second try: its first command is
    /// execute, and the server can run it before the connection breaks.
    /// `ensureConnected` finds most broken connections first, with
    /// `mysql_ping` after `ping_after_idle_s`.
    fn prepare(conn: *Conn, sql: []const u8) Error!*c.MYSQL_STMT {
        if (conn.stmts.get(sql)) |stmt| return stmt;
        // Before prepare, so that adding the statement cannot fail. A
        // disconnect keeps the capacity.
        try conn.stmts.ensureUnusedCapacity(conn.pool.gpa, 1);
        var retried = false;
        while (true) {
            const stmt: *c.MYSQL_STMT = c.mysql_stmt_init(try conn.handle()) orelse return error.OutOfMemory;
            if (c.mysql_stmt_prepare(stmt, sql.ptr, @intCast(sql.len)) == 0) {
                conn.stmts.putAssumeCapacityNoClobber(sql, stmt);
                return stmt;
            }

            if (!retried and !conn.inTransaction() and isConnectionError(c.mysql_stmt_errno(stmt))) {
                log.warn("connection lost ({s}), connecting again", .{std.mem.span(c.mysql_stmt_error(stmt))});
                _ = c.mysql_stmt_close(stmt);
                conn.disconnect();
                try conn.connect();
                retried = true;
                continue;
            }
            defer _ = c.mysql_stmt_close(stmt);
            return conn.stmtError(stmt, sql);
        }
    }

    /// Closes the statement for `sql` and removes it from the cache, after an
    /// error: the state of the statement is then not known. Does nothing if
    /// it is not in the cache (a disconnect closed it).
    fn dropStmt(conn: *Conn, sql: []const u8) void {
        const kv = conn.stmts.fetchRemove(sql) orelse return;
        _ = c.mysql_stmt_close(kv.value);
    }

    /// Logs the statement error. If the connection is broken, it is closed,
    /// so the next `acquire` connects again.
    fn stmtError(conn: *Conn, stmt: *c.MYSQL_STMT, sql: []const u8) Error {
        const errno = c.mysql_stmt_errno(stmt);
        log.err("{s} ({d}): {s}", .{ std.mem.span(c.mysql_stmt_error(stmt)), errno, sql });
        return conn.failed(errno);
    }

    /// Reports whether a transaction is open: from `begin`, or one that the
    /// server reports (for example after a `START TRANSACTION` in SQL). The
    /// server status comes with the reply to each command, so this needs no
    /// round trip.
    fn inTransaction(conn: *Conn) bool {
        if (conn.in_transaction) return true;
        const mysql = conn.mysql orelse return false;
        var status: c_uint = 0;
        if (c.mariadb_get_infov(mysql, c.MARIADB_CONNECTION_SERVER_STATUS, &status) != 0) return false;
        return status & c.SERVER_STATUS_IN_TRANS != 0;
    }

    /// Returns the connection. After a disconnect (an error earlier in this
    /// request), it connects again, but not in a transaction: there it
    /// returns `error.DbUnavailable` until `rollback`. After a failed
    /// statement in a transaction, it returns `error.QueryFailed` until
    /// `rollback`.
    fn handle(conn: *Conn) Error!*c.MYSQL {
        if (conn.failed_in_transaction) {
            log.err("a statement in this transaction failed; call rollback first", .{});
            return error.QueryFailed;
        }
        if (conn.mysql) |mysql| return mysql;
        if (conn.in_transaction) return error.DbUnavailable;
        try conn.connect();
        return conn.mysql.?;
    }

    /// Connects if necessary. A connection older than `conn_max_age_s` is
    /// closed and opened again (this also clears the statement cache).
    fn ensureConnected(conn: *Conn) Error!void {
        const io = conn.pool.io;
        const max_age_s = conn.pool.options.conn_max_age_s;
        if (conn.mysql) |mysql| {
            if (max_age_s != 0 and conn.connected_at.untilNow(io, .awake).toSeconds() >= max_age_s) {
                log.debug("connection is older than {d}s, connecting again", .{max_age_s});
                conn.disconnect();
            } else if (conn.last_used.untilNow(io, .awake).toSeconds() >= ping_after_idle_s and c.mysql_ping(mysql) != 0) {
                log.warn("connection lost ({s}), connecting again", .{std.mem.span(c.mysql_error(mysql))});
                conn.disconnect();
            }
        }
        if (conn.mysql == null) try conn.connect();
    }

    fn connect(conn: *Conn) Error!void {
        const opts = conn.pool.options.connection;
        const mysql: *c.MYSQL = c.mysql_init(null) orelse return error.OutOfMemory;
        errdefer c.mysql_close(mysql);

        _ = c.mysql_options(mysql, c.MYSQL_OPT_CONNECT_TIMEOUT, &connect_timeout_s);
        _ = c.mysql_options(mysql, c.MYSQL_OPT_READ_TIMEOUT, &io_timeout_s);
        _ = c.mysql_options(mysql, c.MYSQL_OPT_WRITE_TIMEOUT, &io_timeout_s);
        _ = c.mysql_options(mysql, c.MYSQL_SET_CHARSET_NAME, "utf8mb4");
        _ = c.mysql_options(mysql, c.MYSQL_INIT_COMMAND, init_command);
        if (opts.socket == null and opts.tls == .required) {
            const yes: c.my_bool = 1;
            _ = c.mysql_options(mysql, c.MYSQL_OPT_SSL_ENFORCE, &yes);
            _ = c.mysql_options(mysql, c.MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &yes);
            if (opts.tls_ca) |ca| _ = c.mysql_options(mysql, c.MYSQL_OPT_SSL_CA, ca.ptr);
        }

        const host: ?[*:0]const u8 = if (opts.socket == null) opts.host.ptr else null;
        const socket: ?[*:0]const u8 = if (opts.socket) |s| s.ptr else null;
        const flags: c_ulong = if (conn.pool.options.multi_statements) c.CLIENT_MULTI_STATEMENTS else 0;
        if (c.mysql_real_connect(mysql, host, opts.user.ptr, opts.password.ptr, opts.database.ptr, opts.port, socket, flags) == null) {
            log.err("cannot connect: {s}", .{std.mem.span(c.mysql_error(mysql))});
            return error.DbUnavailable;
        }
        conn.mysql = mysql;
        conn.connected_at = .now(conn.pool.io, .awake);
    }

    /// Closes the connection and its prepared statements.
    fn disconnect(conn: *Conn) void {
        if (conn.mysql) |mysql| c.mysql_close(mysql);
        conn.mysql = null;
        // `mysql_close` invalidates the statements (`ma_invalidate_stmts`),
        // so this only frees them, without network traffic.
        var it = conn.stmts.valueIterator();
        while (it.next()) |stmt| _ = c.mysql_stmt_close(stmt.*);
        conn.stmts.clearRetainingCapacity();
    }
};

/// Error codes that mean the connection is broken: from the client
/// (errmsg.h), and from the server before it closes the connection.
fn isConnectionError(errno: c_uint) bool {
    return switch (errno) {
        1053, // ER_SERVER_SHUTDOWN
        1927, // ER_CONNECTION_KILLED
        2006, // CR_SERVER_GONE_ERROR
        2013, // CR_SERVER_LOST
        // The client and the server do not agree on the state of the
        // connection (for example, after unread results).
        2014, // CR_COMMANDS_OUT_OF_SYNC
        2055, // CR_SERVER_LOST_EXTENDED
        => true,
        else => false,
    };
}

/// Storage for one parameter value. `MYSQL_BIND` points into it.
const ParamValue = struct {
    int: i64 = 0,
    uint: u64 = 0,
    float: f64 = 0,
};

fn bindParam(bind: *c.MYSQL_BIND, value_store: *ParamValue, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .null => bind.buffer_type = c.MYSQL_TYPE_NULL,
        .optional => if (value) |v| bindParam(bind, value_store, v) else {
            bind.buffer_type = c.MYSQL_TYPE_NULL;
        },
        .comptime_int => bindParam(bind, value_store, @as(i64, value)),
        .comptime_float => bindParam(bind, value_store, @as(f64, value)),
        .int => |int| {
            bind.buffer_type = c.MYSQL_TYPE_LONGLONG;
            if (int.signedness == .signed) {
                value_store.int = value;
                bind.buffer = &value_store.int;
            } else {
                value_store.uint = value;
                bind.buffer = &value_store.uint;
                bind.is_unsigned = 1;
            }
        },
        .float => {
            value_store.float = value;
            bind.buffer = &value_store.float;
            bind.buffer_type = c.MYSQL_TYPE_DOUBLE;
        },
        .bool => bindParam(bind, value_store, @as(i64, @intFromBool(value))),
        .@"enum" => bindParam(bind, value_store, @as([]const u8, @tagName(value))),
        .@"struct" => {
            if (T != common.Binary) @compileError("unsupported query parameter type: " ++ @typeName(T));
            bind.buffer = @constCast(value.bytes.ptr);
            bind.buffer_length = value.bytes.len;
            bind.buffer_type = c.MYSQL_TYPE_BLOB;
        },
        .pointer => {
            const bytes: []const u8 = value;
            bind.buffer = @constCast(bytes.ptr);
            bind.buffer_length = bytes.len;
            bind.buffer_type = c.MYSQL_TYPE_STRING;
        },
        else => @compileError("unsupported query parameter type: " ++ @typeName(T)),
    }
}

/// The type of a result field without its optional.
fn Base(comptime Field: type) type {
    return switch (@typeInfo(Field)) {
        .optional => |opt| opt.child,
        else => Field,
    };
}

/// Fetch buffer for one result column.
const Column = struct {
    int: i64 = 0,
    float: f64 = 0,
    length: c_ulong = 0,
    is_null: c.my_bool = 0,
    @"error": c.my_bool = 0,

    fn bind(column: *Column, comptime T: type, b: *c.MYSQL_BIND) void {
        b.length = &column.length;
        b.is_null = &column.is_null;
        b.@"error" = &column.@"error";
        switch (@typeInfo(T)) {
            .int, .bool => {
                b.buffer_type = c.MYSQL_TYPE_LONGLONG;
                b.buffer = &column.int;
                b.is_unsigned = @intFromBool(@typeInfo(T) == .int and @typeInfo(T).int.signedness == .unsigned);
            },
            .float => {
                b.buffer_type = c.MYSQL_TYPE_DOUBLE;
                b.buffer = &column.float;
            },
            // Strings are fetched with `mysql_stmt_fetch_column` after the
            // length is known.
            .pointer, .@"enum", .array, .@"struct" => {
                if (@typeInfo(T) == .array and @typeInfo(T).array.child != u8) @compileError("unsupported result field type: " ++ @typeName(T));
                if (@typeInfo(T) == .@"struct" and T != common.Binary) @compileError("unsupported result field type: " ++ @typeName(T));
                b.buffer_type = c.MYSQL_TYPE_STRING;
                b.buffer = null;
                b.buffer_length = 0;
            },
            else => @compileError("unsupported result field type: " ++ @typeName(T)),
        }
    }

    fn read(column: *Column, comptime Field: type, arena: Allocator, stmt: *c.MYSQL_STMT, index: usize) Error!Field {
        if (column.is_null != 0) {
            if (@typeInfo(Field) == .optional) return null;
            return error.QueryFailed;
        }
        return try column.readValue(Base(Field), arena, stmt, index);
    }

    fn readValue(column: *Column, comptime T: type, arena: Allocator, stmt: *c.MYSQL_STMT, index: usize) Error!T {
        switch (@typeInfo(T)) {
            .int => |int| {
                if (column.@"error" != 0) return error.QueryFailed;
                if (int.signedness == .unsigned) {
                    return std.math.cast(T, @as(u64, @bitCast(column.int))) orelse error.QueryFailed;
                }
                return std.math.cast(T, column.int) orelse error.QueryFailed;
            },
            .bool => {
                if (column.@"error" != 0) return error.QueryFailed;
                return column.int != 0;
            },
            .float => {
                if (column.@"error" != 0) return error.QueryFailed;
                return @floatCast(column.float);
            },
            .pointer => return fetchString(arena, stmt, index, column.length, c.MYSQL_TYPE_STRING),
            .@"struct" => return .{ .bytes = try fetchString(arena, stmt, index, column.length, c.MYSQL_TYPE_BLOB) },
            .array => |array| {
                if (column.length != array.len) return error.QueryFailed;
                var value: T = undefined;
                @memcpy(&value, try fetchString(arena, stmt, index, column.length, c.MYSQL_TYPE_BLOB));
                return value;
            },
            .@"enum" => {
                const text = try fetchString(arena, stmt, index, column.length, c.MYSQL_TYPE_STRING);
                return std.meta.stringToEnum(T, text) orelse error.QueryFailed;
            },
            else => comptime unreachable,
        }
    }
};

/// Fetches column `index` (`length` bytes) as `buffer_type`: STRING for
/// text, BLOB for binary data.
fn fetchString(arena: Allocator, stmt: *c.MYSQL_STMT, index: usize, length: c_ulong, buffer_type: c.enum_enum_field_types) Error![]const u8 {
    const buf = try arena.alloc(u8, length);
    if (length == 0) return buf;
    var b = std.mem.zeroes(c.MYSQL_BIND);
    var got: c_ulong = 0;
    b.buffer_type = buffer_type;
    b.buffer = buf.ptr;
    b.buffer_length = length;
    b.length = &got;
    if (c.mysql_stmt_fetch_column(stmt, &b, @intCast(index), 0) != 0) return error.QueryFailed;
    return buf[0..@min(got, length)];
}

// Needs a database: set TEST_DATABASE_URL (as DATABASE_URL) to run it. It uses
// a temporary table only, which the server deletes when the connection
// closes, so it does not change data.
test "transactions" {
    const gpa = std.testing.allocator;
    const url = std.testing.environ.getAlloc(gpa, "TEST_DATABASE_URL") catch return error.SkipZigTest;
    defer gpa.free(url);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try libraryInit();
    defer libraryEnd();
    const pool = try Pool.create(gpa, std.testing.io, .{
        .connection = try common.parseUrl(arena, url),
        .pool_size = 1,
        .acquire_timeout_ms = 1000,
    });
    defer pool.destroy();
    const conn = try pool.acquire();
    defer conn.release();

    _ = try conn.exec(
        \\CREATE TEMPORARY TABLE tx_test (n INT NOT NULL) ENGINE = InnoDB
    , .{});
    const Count = struct { n: i64 };
    const count_sql =
        \\SELECT COUNT(*) FROM tx_test
    ;

    try conn.begin();
    _ = try conn.exec(
        \\INSERT INTO tx_test (n) VALUES (1), (2)
    , .{});
    try std.testing.expectEqual(2, (try conn.one(Count, arena, count_sql, .{})).?.n);
    conn.rollback();
    try std.testing.expectEqual(0, (try conn.one(Count, arena, count_sql, .{})).?.n);

    try conn.begin();
    try std.testing.expect(conn.in_transaction);
    try std.testing.expect(conn.inTransaction());
    _ = try conn.exec(
        \\INSERT INTO tx_test (n) VALUES (3)
    , .{});
    try conn.commit();
    try std.testing.expect(!conn.in_transaction);
    conn.rollback(); // no effect after the commit
    try std.testing.expectEqual(1, (try conn.one(Count, arena, count_sql, .{})).?.n);

    // A transaction from SQL, without `begin`: the server status shows it.
    try std.testing.expect(!conn.inTransaction());
    try conn.execScript("START TRANSACTION");
    try std.testing.expect(!conn.in_transaction);
    try std.testing.expect(conn.inTransaction());
    conn.rollback();
    try std.testing.expect(!conn.inTransaction());

    // A lost connection in a transaction: the statements after it fail, and
    // do not run with autocommit on a new connection, until `rollback`.
    const one_sql =
        \\SELECT 1
    ;
    try conn.begin();
    conn.disconnect();
    try std.testing.expectError(error.DbUnavailable, conn.one(Count, arena, one_sql, .{}));
    try std.testing.expectError(error.DbUnavailable, conn.commit());
    try std.testing.expectEqual(null, conn.mysql);
    conn.rollback();
    try std.testing.expectEqual(1, (try conn.one(Count, arena, one_sql, .{})).?.n);
}

// Needs a database, like the test above.
test "statement cache" {
    const gpa = std.testing.allocator;
    const url = std.testing.environ.getAlloc(gpa, "TEST_DATABASE_URL") catch return error.SkipZigTest;
    defer gpa.free(url);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try libraryInit();
    defer libraryEnd();
    const pool = try Pool.create(gpa, std.testing.io, .{
        .connection = try common.parseUrl(arena, url),
        .pool_size = 1,
        .acquire_timeout_ms = 1000,
    });
    defer pool.destroy();
    const conn = try pool.acquire();
    defer conn.release();

    const sql =
        \\SELECT CAST(? AS SIGNED) + 1
    ;
    const N = struct { n: i64 };
    try std.testing.expectEqual(2, (try conn.one(N, arena, sql, .{1})).?.n);
    const stmt = conn.stmts.get(sql).?;
    try std.testing.expectEqual(3, (try conn.one(N, arena, sql, .{2})).?.n);
    try std.testing.expectEqual(stmt, conn.stmts.get(sql).?);

    // After an error, `dropStmt` removes the statement (the error itself
    // logs, which fails a test); the next call prepares it again.
    conn.dropStmt(sql);
    try std.testing.expectEqual(null, conn.stmts.get(sql));
    try std.testing.expectEqual(2, (try conn.one(N, arena, sql, .{1})).?.n);

    // A disconnect closes the statements.
    conn.disconnect();
    try std.testing.expectEqual(0, conn.stmts.count());
    try conn.connect();
    try std.testing.expectEqual(4, (try conn.one(N, arena, sql, .{3})).?.n);
}

// Needs a database, like the test above.
test "binary values" {
    const gpa = std.testing.allocator;
    const url = std.testing.environ.getAlloc(gpa, "TEST_DATABASE_URL") catch return error.SkipZigTest;
    defer gpa.free(url);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try libraryInit();
    defer libraryEnd();
    const pool = try Pool.create(gpa, std.testing.io, .{
        .connection = try common.parseUrl(arena, url),
        .pool_size = 1,
        .acquire_timeout_ms = 1000,
    });
    defer pool.destroy();
    const conn = try pool.acquire();
    defer conn.release();

    _ = try conn.exec(
        \\CREATE TEMPORARY TABLE bin_test (id INT NOT NULL, b VARBINARY(256) NULL)
    , .{});
    var all: [256]u8 = undefined;
    for (&all, 0..) |*x, i| x.* = @intCast(i);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("x", &hash, .{});
    _ = try conn.exec(
        \\INSERT INTO bin_test (id, b) VALUES (1, ?), (2, ?), (3, ?), (4, NULL)
    , .{
        common.binary(&all),
        common.binary(&hash),
        common.binary(""),
    });

    const Row = struct { bin: common.Binary, bytes: []const u8 };
    const row = (try conn.one(Row, arena,
        \\SELECT b, b FROM bin_test WHERE b = ?
    , .{common.binary(&all)})).?;
    try std.testing.expectEqualSlices(u8, &all, row.bin.bytes);
    try std.testing.expectEqualSlices(u8, &all, row.bytes);

    // A fixed length, and the same bytes as the SQL functions make.
    const Hash = struct { h: [32]u8 };
    try std.testing.expectEqual(hash, (try conn.one(Hash, arena,
        \\SELECT b FROM bin_test WHERE id = 2
    , .{})).?.h);
    try std.testing.expectEqual(hash, (try conn.one(Hash, arena,
        \\SELECT UNHEX(SHA2('x', 256))
    , .{})).?.h);
    const same = try conn.one(struct { eq: bool }, arena,
        \\SELECT UNHEX(SHA2('x', 256)) = ?
    , .{common.binary(&hash)});
    try std.testing.expect(same.?.eq);
    // A different length is `error.QueryFailed`. It is not tested here,
    // because the error is logged, and the test runner counts logged errors
    // as failures.

    const Optional = struct { b: ?common.Binary, fixed: ?[32]u8 };
    const empty = (try conn.one(Optional, arena,
        \\SELECT b, NULL FROM bin_test WHERE id = 3
    , .{})).?;
    try std.testing.expectEqual(0, empty.b.?.bytes.len);
    try std.testing.expectEqual(null, empty.fixed);
    const null_row = (try conn.one(Optional, arena,
        \\SELECT b, b FROM bin_test WHERE id = 4
    , .{})).?;
    try std.testing.expectEqual(null, null_row.b);
    try std.testing.expectEqual(null, null_row.fixed);
}

// Needs a database, like the test above.
test "maximum connection age" {
    const gpa = std.testing.allocator;
    const url = std.testing.environ.getAlloc(gpa, "TEST_DATABASE_URL") catch return error.SkipZigTest;
    defer gpa.free(url);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try libraryInit();
    defer libraryEnd();
    const pool = try Pool.create(gpa, std.testing.io, .{
        .connection = try common.parseUrl(arena, url),
        .pool_size = 1,
        .acquire_timeout_ms = 1000,
        .conn_max_age_s = 60,
    });
    defer pool.destroy();

    const N = struct { n: i64 };
    const sql =
        \\SELECT CONNECTION_ID()
    ;
    const conn = try pool.acquire();
    const first = (try conn.one(N, arena, sql, .{})).?.n;
    try std.testing.expectEqual(1, conn.stmts.count());
    conn.release();

    // A young connection is used again.
    _ = try pool.acquire();
    try std.testing.expectEqual(first, (try conn.one(N, arena, sql, .{})).?.n);
    conn.release();

    // An old connection is opened again, with an empty statement cache.
    conn.connected_at = conn.connected_at.subDuration(.fromSeconds(61));
    _ = try pool.acquire();
    defer conn.release();
    try std.testing.expectEqual(0, conn.stmts.count());
    try std.testing.expect((try conn.one(N, arena, sql, .{})).?.n != first);
}

/// The first word of `sql`, in upper case: `SELECT`, `INSERT`, ...
fn operationName(comptime sql: []const u8) []const u8 {
    comptime {
        const text = std.mem.trimStart(u8, sql, " \t\r\n(");
        const end = std.mem.indexOfAny(u8, text, " \t\r\n(;") orelse text.len;
        var buf: [end]u8 = undefined;
        _ = std.ascii.upperString(&buf, text[0..end]);
        const final = buf;
        return &final;
    }
}

test operationName {
    try std.testing.expectEqualStrings("SELECT", comptime operationName("SELECT 1"));
    try std.testing.expectEqualStrings("INSERT", comptime operationName("\n  insert INTO post (title) VALUES (?)"));
    try std.testing.expectEqualStrings("SELECT", comptime operationName("(SELECT 1) UNION (SELECT 2)"));
}
