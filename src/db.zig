//! The database of the app: the MariaDB backend of zig-db (../zig-db), a
//! connection pool and simple typed queries.
//!
//! Builds without MariaDB support (`-Ddb=false`, or libmariadb not found)
//! use a stub with the same API, so the rest of the code does not change.
//!
//!     const conn = try pool.acquire();
//!     defer conn.release();
//!     const users = try conn.query(User, arena,
//!         \\SELECT id, username FROM `user` WHERE id > ?
//!     , .{10});

const backend = @import("db").mariadb;

/// True when this build includes MariaDB support.
pub const enabled = backend.enabled;

pub const Connection = backend.Connection;
pub const Options = backend.Options;
pub const Error = backend.Error;
pub const ExecResult = backend.ExecResult;
pub const Binary = backend.Binary;
pub const binary = backend.binary;
pub const UrlError = backend.UrlError;
pub const parseUrl = backend.parseUrl;
pub const Pool = backend.Pool;
pub const Conn = backend.Conn;

/// Call one time at startup, before other threads start.
pub const libraryInit = backend.libraryInit;
/// Call one time at shutdown, after all connections are closed.
pub const libraryEnd = backend.libraryEnd;

/// The kind of a span of zig-db, for `zig_db_tracer` in main.zig.
pub const SpanKind = @import("db").SpanKind;
