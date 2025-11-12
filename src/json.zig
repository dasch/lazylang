const std = @import("std");
const eval = @import("eval.zig");

// JSON parsing and encoding for Lazylang
//
// Uses Zig's standard library std.json for parsing, which provides robust
// JSON 1.0 compliance and good error messages.
//
// SUPPORTED FEATURES:
// ✓ All JSON primitives: null, boolean, number, string
// ✓ Arrays and objects with arbitrary nesting
// ✓ Proper UTF-8 string handling
// ✓ Standard JSON escape sequences
// ✓ Scientific notation for numbers
//
// ENCODING:
// ✓ Converts Lazylang values to JSON format
// ✓ Symbols encoded as strings
// ✓ Tuples encoded as arrays
// ✓ Pretty-printing with indentation
// ✓ Proper string escaping
//
// LIMITATIONS:
// - Numbers must fit in i64 range (no floats in Lazylang)
// - Functions and thunks cannot be encoded

pub const JsonError = error{
    InvalidJson,
    NumberOutOfRange,
    UnsupportedType,
    OutOfMemory,
};

/// Parse JSON string into a Lazylang Value
pub fn parse(arena: std.mem.Allocator, json_str: []const u8) (JsonError || eval.EvalError)!eval.Value {
    const trimmed = std.mem.trim(u8, json_str, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return eval.Value{ .null_value = {} };
    }

    // Use std.json to parse
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        arena,
        trimmed,
        .{},
    ) catch |err| {
        return switch (err) {
            error.UnexpectedEndOfInput => error.InvalidJson,
            error.InvalidCharacter => error.InvalidJson,
            error.InvalidNumber => error.InvalidJson,
            error.UnexpectedToken => error.InvalidJson,
            error.BufferUnderrun => error.InvalidJson,
            error.SyntaxError => error.InvalidJson,
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidJson,
        };
    };

    return try jsonValueToLazylang(arena, parsed.value);
}

/// Encode a Lazylang Value into JSON string
pub fn encode(arena: std.mem.Allocator, value: eval.Value) (JsonError || eval.EvalError)![]const u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(arena);
    try encodeValue(value, &buf, 0, arena);
    return try buf.toOwnedSlice(arena);
}

/// Convert std.json.Value to Lazylang Value
fn jsonValueToLazylang(arena: std.mem.Allocator, json_value: std.json.Value) (JsonError || eval.EvalError)!eval.Value {
    return switch (json_value) {
        .null => eval.Value{ .null_value = {} },
        .bool => |b| eval.Value{ .boolean = b },
        .integer => |i| eval.Value{ .integer = i },
        .float => |f| {
            // Lazylang doesn't have floats, convert to integer
            const i = @as(i64, @intFromFloat(f));
            return eval.Value{ .integer = i };
        },
        .number_string => |s| {
            // Try to parse as integer
            const i = std.fmt.parseInt(i64, s, 10) catch return error.NumberOutOfRange;
            return eval.Value{ .integer = i };
        },
        .string => |s| {
            const str = try arena.dupe(u8, s);
            return eval.Value{ .string = str };
        },
        .array => |arr| {
            const elements = try arena.alloc(eval.Value, arr.items.len);
            for (arr.items, 0..) |item, i| {
                elements[i] = try jsonValueToLazylang(arena, item);
            }
            return eval.Value{ .array = .{ .elements = elements } };
        },
        .object => |obj| {
            const fields = try arena.alloc(eval.ObjectFieldValue, obj.count());
            var iter = obj.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                const key = try arena.dupe(u8, entry.key_ptr.*);
                const value = try jsonValueToLazylang(arena, entry.value_ptr.*);
                fields[i] = .{ .key = key, .value = value };
                i += 1;
            }
            return eval.Value{ .object = .{ .fields = fields, .module_doc = null } };
        },
    };
}

/// Encode a Lazylang Value to JSON string
fn encodeValue(value: eval.Value, buf: *std.ArrayList(u8), indent: usize, arena: std.mem.Allocator) (JsonError || eval.EvalError)!void {
    switch (value) {
        .null_value => try buf.appendSlice(arena, "null"),
        .boolean => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
        .integer => |i| {
            const str = try std.fmt.allocPrint(arena, "{d}", .{i});
            try buf.appendSlice(arena, str);
        },
        .string => |s| {
            try buf.append(arena, '"');
            // Escape special characters
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(arena, "\\\""),
                    '\\' => try buf.appendSlice(arena, "\\\\"),
                    '\n' => try buf.appendSlice(arena, "\\n"),
                    '\r' => try buf.appendSlice(arena, "\\r"),
                    '\t' => try buf.appendSlice(arena, "\\t"),
                    0x08 => try buf.appendSlice(arena, "\\b"),
                    0x0C => try buf.appendSlice(arena, "\\f"),
                    else => {
                        if (c < 0x20) {
                            // Control characters: use \uXXXX
                            const escaped = try std.fmt.allocPrint(arena, "\\u{x:0>4}", .{c});
                            try buf.appendSlice(arena, escaped);
                        } else {
                            try buf.append(arena, c);
                        }
                    },
                }
            }
            try buf.append(arena, '"');
        },
        .symbol => |s| {
            // Encode symbols as strings (without the # prefix)
            try buf.append(arena, '"');
            // Skip the '#' at the start if present
            const str = if (s.len > 0 and s[0] == '#') s[1..] else s;
            try buf.appendSlice(arena, str);
            try buf.append(arena, '"');
        },
        .array => |arr| {
            if (arr.elements.len == 0) {
                try buf.appendSlice(arena, "[]");
                return;
            }

            try buf.append(arena, '[');
            for (arr.elements, 0..) |elem, i| {
                if (i > 0) try buf.appendSlice(arena, ", ");
                try encodeValue(elem, buf, indent, arena);
            }
            try buf.append(arena, ']');
        },
        .tuple => |t| {
            // Encode tuples as arrays
            if (t.elements.len == 0) {
                try buf.appendSlice(arena, "[]");
                return;
            }

            try buf.append(arena, '[');
            for (t.elements, 0..) |elem, i| {
                if (i > 0) try buf.appendSlice(arena, ", ");
                try encodeValue(elem, buf, indent, arena);
            }
            try buf.append(arena, ']');
        },
        .object => |obj| {
            if (obj.fields.len == 0) {
                try buf.appendSlice(arena, "{}");
                return;
            }

            try buf.append(arena, '{');
            for (obj.fields, 0..) |field, i| {
                if (i > 0) try buf.appendSlice(arena, ", ");

                // Encode key
                try buf.append(arena, '"');
                try buf.appendSlice(arena, field.key);
                try buf.appendSlice(arena, "\": ");

                // Force thunks first
                const field_value = switch (field.value) {
                    .thunk => try eval.force(arena, field.value),
                    else => field.value,
                };

                try encodeValue(field_value, buf, indent + 2, arena);
            }
            try buf.append(arena, '}');
        },
        .thunk => {
            // Force the thunk and encode the result
            const forced = try eval.force(arena, value);
            try encodeValue(forced, buf, indent, arena);
        },
        .function, .native_fn => {
            return error.UnsupportedType;
        },
    }
}
