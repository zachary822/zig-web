//! Optional MariaDB support: a connection pool and simple typed queries.
//!
//! Builds without MariaDB support (`-Ddb=false`, or libmariadb not found)
//! use a stub with the same API, so the rest of the code does not change.
//!
//!     const conn = try pool.acquire();
//!     defer conn.release();
//!     const posts = try conn.query(Post, arena,
//!         \\SELECT id, title FROM post WHERE id > ?
//!     , .{10});

const build_options = @import("build_options");
const common = @import("db/common.zig");
const impl = if (build_options.db) @import("db/mariadb.zig") else @import("db/disabled.zig");

/// True when this build includes MariaDB support.
pub const enabled = build_options.db;

pub const Connection = common.Connection;
pub const Options = common.Options;
pub const Error = common.Error;
pub const ExecResult = common.ExecResult;
pub const Binary = common.Binary;
pub const binary = common.binary;
pub const UrlError = common.UrlError;
pub const parseUrl = common.parseUrl;
pub const Pool = impl.Pool;
pub const Conn = impl.Conn;

/// Call one time at startup, before other threads start.
pub const libraryInit = impl.libraryInit;
/// Call one time at shutdown, after all connections are closed.
pub const libraryEnd = impl.libraryEnd;

test {
    _ = common;
    _ = impl;
}
