//! Password hashing with Argon2id.
//!
//! Hashes are PHC strings, for example
//! `$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>`, which contain the
//! algorithm, the parameters and a random salt. Store them as they are (the
//! `password_hash` column); `verify` reads the parameters from the string, so
//! old hashes stay valid when the parameters change. Use `needsRehash` after
//! a successful login to upgrade them.
//!
//! Each hash uses `params.m` KiB of memory for a short time. `Hasher` limits
//! how many hashes run at the same time, so many logins at once cannot use
//! all the memory of a small server.

const std = @import("std");
const argon2 = std.crypto.pwhash.argon2;

const Hasher = @This();

/// The OWASP recommendation for Argon2id: 19 MiB of memory, 2 iterations,
/// 1 lane. About 16 ms on a modern laptop, and some times more on a
/// Raspberry Pi.
pub const default_params = argon2.Params.owasp_2id;

/// Longer passwords are rejected, so a request cannot make the server hash
/// megabytes of input.
pub const max_password_len = 1024;

/// Longest PHC string that `hash` returns (with room for larger parameters).
pub const max_hash_len = 128;

pub const Error = error{
    PasswordTooLong,
    /// All hashing slots stayed in use for `wait_timeout_ms`.
    HasherBusy,
    /// The stored hash is not a valid Argon2 PHC string.
    InvalidHash,
    OutOfMemory,
    Unexpected,
};

pub const Options = struct {
    params: argon2.Params = default_params,
    /// Maximum number of hashes that run at the same time.
    max_concurrent: u16 = 2,
    /// Time a request waits for a free hashing slot.
    wait_timeout_ms: u32 = 10_000,
};

io: std.Io,
/// Thread-safe allocator for the Argon2 memory; it is freed after each hash.
gpa: std.mem.Allocator,
params: argon2.Params,
wait_timeout_ms: u32,
slots: std.Io.Semaphore,

pub fn init(io: std.Io, gpa: std.mem.Allocator, options: Options) Hasher {
    std.debug.assert(options.max_concurrent > 0);
    return .{
        .io = io,
        .gpa = gpa,
        .params = options.params,
        .wait_timeout_ms = options.wait_timeout_ms,
        .slots = .{ .permits = options.max_concurrent },
    };
}

/// Hashes `password` with a new random salt. The result is allocated with
/// `allocator`.
pub fn hash(self: *Hasher, allocator: std.mem.Allocator, password: []const u8) Error![]u8 {
    if (password.len > max_password_len) return error.PasswordTooLong;
    try self.acquire();
    defer self.slots.post(self.io);

    var buf: [max_hash_len]u8 = undefined;
    const phc = argon2.strHash(password, .{
        .allocator = self.gpa,
        .params = self.params,
        .mode = .argon2id,
    }, &buf, self.io) catch |err| return mapError(err);
    return allocator.dupe(u8, phc);
}

/// Reports whether `password` matches the stored hash.
pub fn verify(self: *Hasher, stored_hash: []const u8, password: []const u8) Error!bool {
    if (password.len > max_password_len) {
        // A hash all the same, so the time does not show that the user exists.
        try self.verifyDummy(password);
        return false;
    }
    try self.acquire();
    defer self.slots.post(self.io);

    argon2.strVerify(stored_hash, password, .{ .allocator = self.gpa }, self.io) catch |err| switch (err) {
        error.PasswordVerificationFailed => return false,
        else => return mapError(err),
    };
    return true;
}

/// Uses the same time as `verify`, for a login with an unknown user name.
/// Without it, a fast answer shows that the user does not exist. Fails with
/// `error.HasherBusy` as `verify` does, so the answer under load is also the
/// same.
pub fn verifyDummy(self: *Hasher, password: []const u8) error{HasherBusy}!void {
    var buf: [max_hash_len]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    _ = self.hash(fba.allocator(), password[0..@min(password.len, max_password_len)]) catch |err| switch (err) {
        error.HasherBusy => return error.HasherBusy,
        else => {},
    };
}

/// Reports whether `stored_hash` was made with other parameters than the
/// current ones, so it must be replaced with `hash` after the next successful
/// login.
pub fn needsRehash(self: *const Hasher, stored_hash: []const u8) bool {
    const p = parseParams(stored_hash) orelse return true;
    return p.t != self.params.t or p.m != self.params.m or p.p != self.params.p;
}

fn acquire(self: *Hasher) Error!void {
    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(self.wait_timeout_ms),
        .clock = .awake,
    } };
    self.slots.waitTimeout(self.io, timeout) catch return error.HasherBusy;
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidEncoding, error.SignatureVerificationFailed, error.WeakParameters, error.OutputTooLong, error.NoSpaceLeft => error.InvalidHash,
        else => error.Unexpected,
    };
}

/// Reads `m`, `t` and `p` from `$argon2id$v=19$m=...,t=...,p=...$...`.
/// Returns null for other algorithms or a malformed string.
fn parseParams(stored_hash: []const u8) ?struct { m: u32, t: u32, p: u24 } {
    var parts = std.mem.splitScalar(u8, stored_hash, '$');
    if (parts.next().?.len != 0) return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "argon2id")) return null;
    _ = parts.next() orelse return null; // v=19
    var m: ?u32 = null;
    var t: ?u32 = null;
    var p: ?u24 = null;
    var fields = std.mem.splitScalar(u8, parts.next() orelse return null, ',');
    while (fields.next()) |field| {
        if (field.len < 3 or field[1] != '=') return null;
        const value = field[2..];
        switch (field[0]) {
            'm' => m = std.fmt.parseInt(u32, value, 10) catch return null,
            't' => t = std.fmt.parseInt(u32, value, 10) catch return null,
            'p' => p = std.fmt.parseInt(u24, value, 10) catch return null,
            else => return null,
        }
    }
    return .{ .m = m orelse return null, .t = t orelse return null, .p = p orelse return null };
}

// Tests use small parameters, so they are fast in Debug builds.
const test_params: argon2.Params = .{ .t = 1, .m = 64, .p = 1 };

test "hash and verify" {
    var hasher: Hasher = .init(std.testing.io, std.testing.allocator, .{ .params = test_params });
    const a = try hasher.hash(std.testing.allocator, "correct horse battery staple");
    defer std.testing.allocator.free(a);
    const b = try hasher.hash(std.testing.allocator, "correct horse battery staple");
    defer std.testing.allocator.free(b);

    try std.testing.expect(std.mem.startsWith(u8, a, "$argon2id$v=19$m=64,t=1,p=1$"));
    try std.testing.expect(!std.mem.eql(u8, a, b)); // a new salt each time
    try std.testing.expect(try hasher.verify(a, "correct horse battery staple"));
    try std.testing.expect(try hasher.verify(b, "correct horse battery staple"));
    try std.testing.expect(!try hasher.verify(a, "correct horse battery stapl"));
    try std.testing.expect(!try hasher.verify(a, ""));

    // Unicode and an empty password are hashed like any other bytes.
    const unicode = try hasher.hash(std.testing.allocator, "pässwörd 🔑");
    defer std.testing.allocator.free(unicode);
    try std.testing.expect(try hasher.verify(unicode, "pässwörd 🔑"));
    const empty = try hasher.hash(std.testing.allocator, "");
    defer std.testing.allocator.free(empty);
    try std.testing.expect(try hasher.verify(empty, ""));
}

test "length limit and invalid hashes" {
    var hasher: Hasher = .init(std.testing.io, std.testing.allocator, .{ .params = test_params });
    const long: [max_password_len + 1]u8 = @splat('a');
    try std.testing.expectError(error.PasswordTooLong, hasher.hash(std.testing.allocator, &long));
    const stored = try hasher.hash(std.testing.allocator, "x");
    defer std.testing.allocator.free(stored);
    try std.testing.expect(!try hasher.verify(stored, &long));

    try std.testing.expectError(error.InvalidHash, hasher.verify("not a hash", "x"));
    try std.testing.expectError(error.InvalidHash, hasher.verify("$argon2id$v=19$m=64,t=1,p=1$bad$bad", "x"));

    try hasher.verifyDummy("anything");
    try hasher.verifyDummy(&long);
}

test needsRehash {
    var hasher: Hasher = .init(std.testing.io, std.testing.allocator, .{ .params = test_params });
    const stored = try hasher.hash(std.testing.allocator, "x");
    defer std.testing.allocator.free(stored);
    try std.testing.expect(!hasher.needsRehash(stored));

    var stronger: Hasher = .init(std.testing.io, std.testing.allocator, .{ .params = .{ .t = 2, .m = 64, .p = 1 } });
    try std.testing.expect(stronger.needsRehash(stored));
    // Old hashes still verify after the parameters change.
    try std.testing.expect(try stronger.verify(stored, "x"));

    try std.testing.expect(hasher.needsRehash("$2b$10$bcrypthashbcrypthashbcrypthashbcrypthashbcrypthashbc"));
    try std.testing.expect(hasher.needsRehash("garbage"));
}

test parseParams {
    const p = parseParams("$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA").?;
    try std.testing.expectEqual(19456, p.m);
    try std.testing.expectEqual(2, p.t);
    try std.testing.expectEqual(1, p.p);
    try std.testing.expectEqual(null, parseParams("$argon2i$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA"));
    try std.testing.expectEqual(null, parseParams("$argon2id$v=19$m=19456,t=2$c2FsdA$aGFzaA"));
    try std.testing.expectEqual(null, parseParams(""));
}
