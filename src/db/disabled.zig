//! Stub for builds without MariaDB support. A pool cannot be created, so the
//! server runs without a database.

const std = @import("std");
const common = @import("common.zig");

const Error = common.Error;

pub fn libraryInit() !void {}

pub fn libraryEnd() void {}

pub const Pool = struct {
    pub fn create(_: std.mem.Allocator, _: std.Io, _: common.Options) error{DbNotSupported}!*Pool {
        return error.DbNotSupported;
    }

    pub fn destroy(_: *Pool) void {}

    pub fn acquire(_: *Pool) Error!*Conn {
        return error.DbNotConfigured;
    }
};

pub const Conn = struct {
    pub fn release(_: *Conn) void {}

    pub fn exec(_: *Conn, comptime _: []const u8, _: anytype) Error!common.ExecResult {
        return error.DbNotConfigured;
    }

    pub fn query(_: *Conn, comptime T: type, _: std.mem.Allocator, comptime _: []const u8, _: anytype) Error![]T {
        return error.DbNotConfigured;
    }

    pub fn one(_: *Conn, comptime T: type, _: std.mem.Allocator, comptime _: []const u8, _: anytype) Error!?T {
        return error.DbNotConfigured;
    }

    pub fn execScript(_: *Conn, _: []const u8) Error!void {
        return error.DbNotConfigured;
    }

    pub fn begin(_: *Conn) Error!void {
        return error.DbNotConfigured;
    }

    pub fn commit(_: *Conn) Error!void {
        return error.DbNotConfigured;
    }

    pub fn rollback(_: *Conn) void {}
};
