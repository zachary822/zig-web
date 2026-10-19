//! Form validation from a model. A model is a struct with one `Field` for
//! each form field, as the default value:
//!
//!     const Login = struct {
//!         username: form.Field = .{ .type = []const u8, .required = true, .max_len = 64 },
//!         password: form.Field = .{ .type = []const u8, .required = true, .trim = false },
//!         remember: form.Field = .{ .type = bool },
//!     };
//!     const LoginForm = form.Validator(Login);
//!
//!     const result = try LoginForm.fromRequest(req);
//!     if (!result.ok()) ... // show result.errors
//!     result.values.username // []const u8
//!
//! `Validator` makes three structs with the field names of the model:
//! `Values` (the field types, for example `[]const u8` and `bool`), `Errors`
//! (a `?[]const u8` message for each field) and `Input` (the text as the
//! browser sent it, to show the form again). Templates can use them as
//! `{{values.title}}` and `{{errors.title}}`.
//!
//! For query parameters, use `fromQuery` in place of `fromRequest`.
//!
//! The values point into the form data, so they are valid until the end of
//! the request.

const std = @import("std");
const httpz = @import("httpz");

/// The rules for one form field. All rules are off by default.
pub const Field = struct {
    /// The type of the value:
    ///   - `[]const u8`: text. It must be valid UTF-8.
    ///   - `bool`: a check box. True when the field is in the form.
    ///   - an integer type: a number in decimal digits.
    ///   - an enum: the name of one of its values, for example from a
    ///     `<select>`.
    ///   - `?T` of these, except `bool`: null when the field is missing or
    ///     empty, with no `required` message.
    type: type,
    /// The name of the field in messages. Default: the field name, with `_`
    /// as a space.
    label: ?[]const u8 = null,
    /// Remove spaces, tabs and line breaks at the two ends of the text before
    /// the other rules. Not for passwords.
    trim: bool = true,
    /// The text must not be empty (after `trim`). Only for text that is not
    /// optional. Numbers and enum values that are not optional are always
    /// necessary.
    required: bool = false,
    /// Minimum and maximum number of characters (Unicode code points), for
    /// text.
    min_len: ?usize = null,
    max_len: ?usize = null,
    /// Maximum size in bytes, for text.
    max_bytes: ?usize = null,
    /// Minimum and maximum value, for integers.
    min: ?i128 = null,
    max: ?i128 = null,
};

/// Makes the validator for `Model`, a struct with a `Field` default value for
/// each field. See the top of this file.
pub fn Validator(comptime Model: type) type {
    const info = @typeInfo(Model).@"struct";
    const names = info.field_names;
    comptime var specs: [names.len]Field = undefined;
    comptime var value_types: [names.len]type = undefined;
    inline for (names, info.field_types, info.field_attrs, 0..) |name, T, attrs, i| {
        if (T != Field) @compileError(@typeName(Model) ++ "." ++ name ++ " must have the type form.Field");
        specs[i] = attrs.defaultValue(Field) orelse @compileError(@typeName(Model) ++ "." ++ name ++ " needs a form.Field value");
        checkSpec(name, specs[i]);
        value_types[i] = specs[i].type;
    }
    const final_specs = specs;
    const final_types = value_types;
    const no_error: ?[]const u8 = null;
    const empty: []const u8 = "";

    return struct {
        pub const Values = @Struct(.auto, null, names, &final_types, &@splat(.{}));
        pub const Errors = @Struct(.auto, null, names, &@splat(?[]const u8), &@splat(.{ .default_value_ptr = @as(*const anyopaque, @ptrCast(&no_error)) }));
        pub const Input = @Struct(.auto, null, names, &@splat([]const u8), &@splat(.{ .default_value_ptr = @as(*const anyopaque, @ptrCast(&empty)) }));

        pub const Result = struct {
            values: Values,
            errors: Errors = .{},
            input: Input = .{},

            /// Reports whether all fields obey their rules.
            pub fn ok(self: *const Result) bool {
                return self.firstError() == null;
            }

            /// The message for the first field (in the order of the model)
            /// with a problem, or null.
            pub fn firstError(self: *const Result) ?[]const u8 {
                inline for (names) |name| {
                    if (@field(self.errors, name)) |message| return message;
                }
                return null;
            }
        };

        /// Validates the form fields of `req` (`application/x-www-form-urlencoded`).
        pub fn fromRequest(req: *httpz.Request) !Result {
            return parse(try req.formData());
        }

        /// Validates the query parameters of `req`, for example `?page=2`.
        pub fn fromQuery(req: *httpz.Request) !Result {
            return parse(try req.query());
        }

        /// Validates `form`, a value with `get(name) ?[]const u8`, for
        /// example `req.formData()` or `req.query()`.
        pub fn parse(form: anytype) Result {
            var result: Result = .{ .values = undefined };
            inline for (names, final_specs) |name, spec| {
                const raw = form.get(name);
                @field(result.input, name) = raw orelse "";
                const parsed = parseField(spec, comptime label(name, spec), raw);
                @field(result.values, name) = parsed.value;
                @field(result.errors, name) = parsed.problem;
            }
            return result;
        }
    };
}

/// A value, and the message for its problem, if any. When there is a
/// problem, the value is what is useful to show the form again: the text,
/// or zero or null for a number that is not valid.
fn Parsed(comptime T: type) type {
    return struct { value: T, problem: ?[]const u8 = null };
}

fn parseField(comptime spec: Field, comptime name: []const u8, raw: ?[]const u8) Parsed(spec.type) {
    const T = spec.type;
    if (T == bool) return .{ .value = raw != null };

    const Base, const optional = switch (@typeInfo(T)) {
        .optional => |o| .{ o.child, true },
        else => .{ T, false },
    };
    const missing = comptime std.fmt.comptimePrint("Enter the {s}.", .{name});
    const text = if (spec.trim) std.mem.trim(u8, raw orelse "", " \t\r\n") else raw orelse "";

    if (text.len == 0) {
        if (optional) return .{ .value = null };
        if (Base == []const u8) return .{ .value = text, .problem = if (spec.required) missing else null };
        return .{ .value = zero(Base), .problem = missing };
    }

    if (Base == []const u8) return .{ .value = text, .problem = checkText(spec, name, text) };
    switch (@typeInfo(Base)) {
        .int => {
            const not_valid = comptime std.fmt.comptimePrint("The {s} must be a whole number{s}.", .{ name, rangeText(spec) });
            const n = std.fmt.parseInt(Base, text, 10) catch return .{ .value = zero(T), .problem = not_valid };
            if ((spec.min != null and n < spec.min.?) or (spec.max != null and n > spec.max.?)) {
                return .{ .value = n, .problem = not_valid };
            }
            return .{ .value = n };
        },
        .@"enum" => {
            const not_valid = comptime std.fmt.comptimePrint("Choose a {s} from the list.", .{name});
            const v = std.meta.stringToEnum(Base, text) orelse return .{ .value = zero(T), .problem = not_valid };
            return .{ .value = v };
        },
        else => comptime unreachable,
    }
}

fn checkText(comptime spec: Field, comptime name: []const u8, text: []const u8) ?[]const u8 {
    if (spec.max_bytes) |max| {
        const too_big = comptime std.fmt.comptimePrint("The {s} must have at most {f}.", .{ name, Bytes{ .n = max } });
        if (text.len > max) return too_big;
    }
    const chars = std.unicode.utf8CountCodepoints(text) catch
        return comptime std.fmt.comptimePrint("The {s} is not valid UTF-8 text.", .{name});
    if (spec.min_len) |min| {
        const too_short = comptime std.fmt.comptimePrint("The {s} must have at least {d} characters.", .{ name, min });
        if (chars < min) return too_short;
    }
    if (spec.max_len) |max| {
        const too_long = comptime std.fmt.comptimePrint("The {s} must have at most {d} characters.", .{ name, max });
        if (chars > max) return too_long;
    }
    return null;
}

/// A size for messages, for example `256 KiB` or `100 bytes`.
const Bytes = struct {
    n: usize,

    pub fn format(self: Bytes, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.n >= 1024 * 1024 and self.n % (1024 * 1024) == 0) return w.print("{d} MiB", .{self.n / (1024 * 1024)});
        if (self.n >= 1024 and self.n % 1024 == 0) return w.print("{d} KiB", .{self.n / 1024});
        return w.print("{d} bytes", .{self.n});
    }
};

fn rangeText(comptime spec: Field) []const u8 {
    if (spec.min != null and spec.max != null) return std.fmt.comptimePrint(" from {d} to {d}", .{ spec.min.?, spec.max.? });
    if (spec.min) |min| return std.fmt.comptimePrint(" of at least {d}", .{min});
    if (spec.max) |max| return std.fmt.comptimePrint(" of at most {d}", .{max});
    return "";
}

fn zero(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .optional => null,
        .int => 0,
        .@"enum" => |e| @fromBackingInt(@intCast(e.field_values[0])),
        else => comptime unreachable,
    };
}

fn label(comptime name: []const u8, comptime spec: Field) []const u8 {
    if (spec.label) |l| return l;
    comptime var buf: [name.len]u8 = undefined;
    for (name, 0..) |c, i| buf[i] = if (c == '_') ' ' else c;
    const final = buf;
    return &final;
}

/// Compile errors for rules that do not fit the type.
fn checkSpec(comptime name: []const u8, comptime spec: Field) void {
    const T = spec.type;
    const Base = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    const is_text = Base == []const u8;
    const supported = T == bool or is_text or @typeInfo(Base) == .int or @typeInfo(Base) == .@"enum";
    if (!supported) @compileError(name ++ ": form.Field does not support the type " ++ @typeName(T));
    if (Base == bool and T != bool) @compileError(name ++ ": a check box is bool, not ?bool");
    if (spec.required and T != []const u8) @compileError(name ++ ": `required` is only for []const u8");
    if (!is_text and (spec.min_len != null or spec.max_len != null or spec.max_bytes != null)) @compileError(name ++ ": length rules are only for text");
    if (@typeInfo(Base) != .int and (spec.min != null or spec.max != null)) @compileError(name ++ ": `min` and `max` are only for integers");
}

/// A form for the tests: a list of name and value pairs.
const TestForm = struct {
    pairs: []const [2][]const u8,

    pub fn get(self: TestForm, name: []const u8) ?[]const u8 {
        for (self.pairs) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
        return null;
    }
};

test Validator {
    const Color = enum { red, green };
    const Model = struct {
        title: Field = .{ .type = []const u8, .required = true, .max_len = 5 },
        password: Field = .{ .type = []const u8, .required = true, .trim = false, .min_len = 3 },
        page_count: Field = .{ .type = u32, .min = 1, .max = 9 },
        color: Field = .{ .type = ?Color },
        note: Field = .{ .type = []const u8, .max_bytes = 2048 },
        published: Field = .{ .type = bool },
    };
    const F = Validator(Model);

    // The generated types.
    try std.testing.expectEqual([]const u8, @FieldType(F.Values, "title"));
    try std.testing.expectEqual(u32, @FieldType(F.Values, "page_count"));
    try std.testing.expectEqual(?Color, @FieldType(F.Values, "color"));
    try std.testing.expectEqual(bool, @FieldType(F.Values, "published"));

    const good = F.parse(TestForm{ .pairs = &.{
        .{ "title", "  Héllo " },
        .{ "password", " pw " },
        .{ "page_count", "3" },
        .{ "color", "green" },
        .{ "published", "1" },
    } });
    try std.testing.expect(good.ok());
    try std.testing.expectEqualStrings("Héllo", good.values.title);
    try std.testing.expectEqualStrings(" pw ", good.values.password);
    try std.testing.expectEqual(3, good.values.page_count);
    try std.testing.expectEqual(.green, good.values.color.?);
    try std.testing.expectEqualStrings("", good.values.note);
    try std.testing.expect(good.values.published);
    try std.testing.expectEqualStrings("  Héllo ", good.input.title);

    const bad = F.parse(TestForm{ .pairs = &.{
        .{ "title", "Too long" },
        .{ "password", "ab" },
        .{ "page_count", "10" },
        .{ "color", "blue" },
        .{ "note", "\xff" },
    } });
    try std.testing.expect(!bad.ok());
    try std.testing.expectEqualStrings("The title must have at most 5 characters.", bad.errors.title.?);
    try std.testing.expectEqualStrings("Too long", bad.values.title);
    try std.testing.expectEqualStrings("The password must have at least 3 characters.", bad.errors.password.?);
    try std.testing.expectEqualStrings("The page count must be a whole number from 1 to 9.", bad.errors.page_count.?);
    try std.testing.expectEqualStrings("10", bad.input.page_count);
    try std.testing.expectEqualStrings("Choose a color from the list.", bad.errors.color.?);
    try std.testing.expectEqualStrings("The note is not valid UTF-8 text.", bad.errors.note.?);
    try std.testing.expect(!bad.values.published);
    try std.testing.expectEqualStrings(bad.errors.title.?, bad.firstError().?);

    const empty = F.parse(TestForm{ .pairs = &.{.{ "title", "   " }} });
    try std.testing.expectEqualStrings("Enter the title.", empty.errors.title.?);
    try std.testing.expectEqualStrings("Enter the password.", empty.errors.password.?);
    try std.testing.expectEqualStrings("Enter the page count.", empty.errors.page_count.?);
    try std.testing.expectEqual(null, empty.errors.color);
    try std.testing.expectEqual(null, empty.values.color);
    try std.testing.expectEqual(null, empty.errors.note);
}

test "max_bytes and labels" {
    const F = Validator(struct {
        body: Field = .{ .type = []const u8, .label = "text", .max_bytes = 4 * 1024 },
    });
    var long: [4 * 1024 + 1]u8 = @splat('a');
    const r = F.parse(TestForm{ .pairs = &.{.{ "body", &long }} });
    try std.testing.expectEqualStrings("The text must have at most 4 KiB.", r.errors.body.?);
    try std.testing.expect(F.parse(TestForm{ .pairs = &.{.{ "body", long[1..] }} }).ok());
}
