//! Value formatting for Lazylang.
//!
//! This module provides functions to format Lazylang runtime values in various formats:
//! - JSON: Standard JSON format with proper escaping
//! - YAML: YAML format with indentation and nested structures
//! - Pretty: Human-readable format with colors and indentation
//! - Compact: Short string representation for debugging
//!
//! Format types:
//! - formatValue: Compact single-line format
//! - formatValuePretty: Pretty-printed with indentation and colors
//! - formatValueAsJson: Standard JSON output
//! - formatValueAsYaml: YAML output with proper indentation
//! - formatValueShort: Short debugging representation
//! - valueToString: Convert value to string (for string interpolation)
//!
//! All formatters handle thunks by forcing them before formatting,
//! and properly escape strings for their target format.

const std = @import("std");
const eval = @import("eval.zig");

// Import types and functions from eval
const Value = eval.Value;
const EvalError = eval.EvalError;
const force = eval.force;
const getValueTypeName = eval.getValueTypeName;
const setUserCrashMessage = eval.setUserCrashMessage;

pub fn formatValueShort(allocator: std.mem.Allocator, value: Value) ![]u8 {
    return switch (value) {
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .boolean => |v| try std.fmt.allocPrint(allocator, "{s}", .{if (v) "true" else "false"}),
        .null_value => try allocator.dupe(u8, "null"),
        .symbol => |s| try std.fmt.allocPrint(allocator, "#{s}", .{s}),
        .string => |s| if (s.len > 20)
            try std.fmt.allocPrint(allocator, "\"{s}...\"", .{s[0..20]})
        else
            try std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
        .array => |a| try std.fmt.allocPrint(allocator, "array with {d} elements", .{a.elements.len}),
        .tuple => |t| try std.fmt.allocPrint(allocator, "tuple with {d} elements", .{t.elements.len}),
        .object => |o| try std.fmt.allocPrint(allocator, "object with {d} fields", .{o.fields.len}),
        .function => try allocator.dupe(u8, "function"),
        .native_fn => try allocator.dupe(u8, "native function"),
        .thunk => try allocator.dupe(u8, "thunk"),
    };
}

pub fn valueToString(allocator: std.mem.Allocator, value: Value) ![]u8 {
    return switch (value) {
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .boolean => |v| try std.fmt.allocPrint(allocator, "{s}", .{if (v) "true" else "false"}),
        .null_value => try std.fmt.allocPrint(allocator, "null", .{}),
        .symbol => |s| try allocator.dupe(u8, s),
        .string => |str| try allocator.dupe(u8, str),
        else => try formatValue(allocator, value),
    };
}

pub fn formatValue(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return formatValueWithArena(allocator, arena.allocator(), value);
}

pub fn formatValuePretty(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return formatValuePrettyImpl(allocator, arena.allocator(), value, 0);
}

pub fn formatValueAsJson(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return formatValueAsJsonImpl(allocator, arena.allocator(), value);
}

fn formatValueAsJsonImpl(allocator: std.mem.Allocator, arena: std.mem.Allocator, value: Value) EvalError![]u8 {
    return switch (value) {
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .boolean => |v| try std.fmt.allocPrint(allocator, "{s}", .{if (v) "true" else "false"}),
        .null_value => try std.fmt.allocPrint(allocator, "null", .{}),
        .symbol => |s| try std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
        .function => {
            const message = "Cannot represent function in JSON output. Functions are not serializable.";
            const message_copy = try std.heap.page_allocator.dupe(u8, message);
            setUserCrashMessage(message_copy);
            return error.UserCrash;
        },
        .native_fn => {
            const message = "Cannot represent native function in JSON output. Functions are not serializable.";
            const message_copy = try std.heap.page_allocator.dupe(u8, message);
            setUserCrashMessage(message_copy);
            return error.UserCrash;
        },
        .thunk => blk: {
            const forced = force(arena, value) catch break :blk try std.fmt.allocPrint(allocator, "null", .{});
            break :blk try formatValueAsJsonImpl(allocator, arena, forced);
        },
        .array => |arr| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '[');
            for (arr.elements, 0..) |element, i| {
                if (i != 0) try builder.appendSlice(allocator, ",");
                const formatted = try formatValueAsJsonImpl(allocator, arena, element);
                defer allocator.free(formatted);
                try builder.appendSlice(allocator, formatted);
            }
            try builder.append(allocator, ']');

            break :blk try builder.toOwnedSlice(allocator);
        },
        .tuple => |tup| blk: {
            // Tuples are represented as arrays in JSON
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '[');
            for (tup.elements, 0..) |element, i| {
                if (i != 0) try builder.appendSlice(allocator, ",");
                const formatted = try formatValueAsJsonImpl(allocator, arena, element);
                defer allocator.free(formatted);
                try builder.appendSlice(allocator, formatted);
            }
            try builder.append(allocator, ']');

            break :blk try builder.toOwnedSlice(allocator);
        },
        .object => |obj| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '{');
            for (obj.fields, 0..) |field, i| {
                if (i != 0) try builder.appendSlice(allocator, ",");
                // Escape key for JSON
                try builder.append(allocator, '"');
                try jsonEscapeString(&builder, allocator, field.key);
                try builder.appendSlice(allocator, "\":");
                const formatted = try formatValueAsJsonImpl(allocator, arena, field.value);
                defer allocator.free(formatted);
                try builder.appendSlice(allocator, formatted);
            }
            try builder.append(allocator, '}');

            break :blk try builder.toOwnedSlice(allocator);
        },
        .string => |str| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '"');
            try jsonEscapeString(&builder, allocator, str);
            try builder.append(allocator, '"');

            break :blk try builder.toOwnedSlice(allocator);
        },
    };
}

fn jsonEscapeString(builder: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try builder.appendSlice(allocator, "\\\""),
            '\\' => try builder.appendSlice(allocator, "\\\\"),
            '\n' => try builder.appendSlice(allocator, "\\n"),
            '\r' => try builder.appendSlice(allocator, "\\r"),
            '\t' => try builder.appendSlice(allocator, "\\t"),
            0x08 => try builder.appendSlice(allocator, "\\b"),
            0x0C => try builder.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    // Control characters: use \uXXXX format
                    try builder.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c}));
                } else {
                    try builder.append(allocator, c);
                }
            },
        }
    }
}

pub fn formatValueAsYaml(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return formatValueAsYamlImpl(allocator, arena.allocator(), value, 0);
}

fn formatValueAsYamlImpl(allocator: std.mem.Allocator, arena: std.mem.Allocator, value: Value, indent: usize) EvalError![]u8 {
    return switch (value) {
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .boolean => |v| try std.fmt.allocPrint(allocator, "{s}", .{if (v) "true" else "false"}),
        .null_value => try std.fmt.allocPrint(allocator, "null", .{}),
        .symbol => |s| blk: {
            // Symbols are represented as strings in YAML
            if (yamlNeedsQuoting(s)) {
                var builder = std.ArrayList(u8){};
                errdefer builder.deinit(allocator);
                try builder.append(allocator, '"');
                try yamlEscapeString(&builder, allocator, s);
                try builder.append(allocator, '"');
                break :blk try builder.toOwnedSlice(allocator);
            } else {
                break :blk try allocator.dupe(u8, s);
            }
        },
        .function => {
            const message = "Cannot represent function in YAML output. Functions are not serializable.";
            const message_copy = try std.heap.page_allocator.dupe(u8, message);
            setUserCrashMessage(message_copy);
            return error.UserCrash;
        },
        .native_fn => {
            const message = "Cannot represent native function in YAML output. Functions are not serializable.";
            const message_copy = try std.heap.page_allocator.dupe(u8, message);
            setUserCrashMessage(message_copy);
            return error.UserCrash;
        },
        .thunk => blk: {
            const forced = force(arena, value) catch break :blk try std.fmt.allocPrint(allocator, "null", .{});
            break :blk try formatValueAsYamlImpl(allocator, arena, forced, indent);
        },
        .array => |arr| blk: {
            if (arr.elements.len == 0) {
                break :blk try std.fmt.allocPrint(allocator, "[]", .{});
            }

            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            for (arr.elements) |element| {
                if (builder.items.len > 0) {
                    try builder.append(allocator, '\n');
                }
                for (0..indent) |_| {
                    try builder.appendSlice(allocator, "  ");
                }
                try builder.appendSlice(allocator, "- ");

                const formatted = try formatValueAsYamlImpl(allocator, arena, element, indent + 1);
                defer allocator.free(formatted);

                // If the formatted value contains newlines, append as-is (already properly indented)
                if (std.mem.indexOf(u8, formatted, "\n")) |_| {
                    // Child was formatted with indent+1, so lines are already indented
                    // First line goes after "- ", subsequent lines already have correct indentation
                    var is_first = true;
                    var iter = std.mem.splitScalar(u8, formatted, '\n');
                    while (iter.next()) |line| {
                        if (is_first) {
                            // Strip leading indent from first line (it goes inline with "- ")
                            const spaces_to_strip = (indent + 1) * 2;
                            const stripped = if (line.len >= spaces_to_strip and std.mem.allEqual(u8, line[0..spaces_to_strip], ' '))
                                line[spaces_to_strip..]
                            else
                                line;
                            try builder.appendSlice(allocator, stripped);
                            is_first = false;
                        } else {
                            try builder.append(allocator, '\n');
                            try builder.appendSlice(allocator, line);
                        }
                    }
                } else {
                    // Single-line value: strip leading indentation (it goes inline with "- ")
                    const spaces_to_strip = (indent + 1) * 2;
                    const stripped = if (formatted.len >= spaces_to_strip and std.mem.allEqual(u8, formatted[0..spaces_to_strip], ' '))
                        formatted[spaces_to_strip..]
                    else
                        formatted;
                    try builder.appendSlice(allocator, stripped);
                }
            }

            break :blk try builder.toOwnedSlice(allocator);
        },
        .tuple => |tup| blk: {
            // Tuples are represented as arrays in YAML
            if (tup.elements.len == 0) {
                break :blk try std.fmt.allocPrint(allocator, "[]", .{});
            }

            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            for (tup.elements) |element| {
                if (builder.items.len > 0) {
                    try builder.append(allocator, '\n');
                }
                for (0..indent) |_| {
                    try builder.appendSlice(allocator, "  ");
                }
                try builder.appendSlice(allocator, "- ");
                const formatted = try formatValueAsYamlImpl(allocator, arena, element, indent + 1);
                defer allocator.free(formatted);

                // If the formatted value contains newlines, append as-is (already properly indented)
                if (std.mem.indexOf(u8, formatted, "\n")) |_| {
                    // Child was formatted with indent+1, so lines are already indented
                    // First line goes after "- ", subsequent lines already have correct indentation
                    var is_first = true;
                    var iter = std.mem.splitScalar(u8, formatted, '\n');
                    while (iter.next()) |line| {
                        if (is_first) {
                            // Strip leading indent from first line (it goes inline with "- ")
                            const spaces_to_strip = (indent + 1) * 2;
                            const stripped = if (line.len >= spaces_to_strip and std.mem.allEqual(u8, line[0..spaces_to_strip], ' '))
                                line[spaces_to_strip..]
                            else
                                line;
                            try builder.appendSlice(allocator, stripped);
                            is_first = false;
                        } else {
                            try builder.append(allocator, '\n');
                            try builder.appendSlice(allocator, line);
                        }
                    }
                } else {
                    // Single-line value: strip leading indentation (it goes inline with "- ")
                    const spaces_to_strip = (indent + 1) * 2;
                    const stripped = if (formatted.len >= spaces_to_strip and std.mem.allEqual(u8, formatted[0..spaces_to_strip], ' '))
                        formatted[spaces_to_strip..]
                    else
                        formatted;
                    try builder.appendSlice(allocator, stripped);
                }
            }

            break :blk try builder.toOwnedSlice(allocator);
        },
        .object => |obj| blk: {
            if (obj.fields.len == 0) {
                break :blk try std.fmt.allocPrint(allocator, "{{}}", .{});
            }

            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            for (obj.fields, 0..) |field, i| {
                if (i > 0) {
                    try builder.append(allocator, '\n');
                }
                for (0..indent) |_| {
                    try builder.appendSlice(allocator, "  ");
                }

                // Format the key
                if (yamlNeedsQuoting(field.key)) {
                    try builder.append(allocator, '"');
                    try yamlEscapeString(&builder, allocator, field.key);
                    try builder.append(allocator, '"');
                } else {
                    try builder.appendSlice(allocator, field.key);
                }
                try builder.appendSlice(allocator, ": ");

                const formatted = try formatValueAsYamlImpl(allocator, arena, field.value, indent + 1);
                defer allocator.free(formatted);

                // Check if value should go on a new line (multiline, array, or nested object)
                const expected_indent = (indent + 1) * 2;
                const is_multiline = std.mem.indexOf(u8, formatted, "\n") != null;
                const is_structured = formatted.len >= expected_indent and
                                     std.mem.allEqual(u8, formatted[0..expected_indent], ' ');

                if (is_multiline or is_structured) {
                    try builder.append(allocator, '\n');
                    // Child was formatted with indent+1, so lines already have correct indentation
                    var is_first = true;
                    var iter = std.mem.splitScalar(u8, formatted, '\n');
                    while (iter.next()) |line| {
                        if (!is_first) {
                            try builder.append(allocator, '\n');
                        }
                        try builder.appendSlice(allocator, line);
                        is_first = false;
                    }
                } else {
                    // Simple scalar value: goes inline with ": "
                    try builder.appendSlice(allocator, formatted);
                }
            }

            break :blk try builder.toOwnedSlice(allocator);
        },
        .string => |str| blk: {
            if (yamlNeedsQuoting(str)) {
                var builder = std.ArrayList(u8){};
                errdefer builder.deinit(allocator);
                try builder.append(allocator, '"');
                try yamlEscapeString(&builder, allocator, str);
                try builder.append(allocator, '"');
                break :blk try builder.toOwnedSlice(allocator);
            } else {
                break :blk try allocator.dupe(u8, str);
            }
        },
    };
}

fn yamlNeedsQuoting(str: []const u8) bool {
    if (str.len == 0) return true;

    // Check for special YAML values that need quoting
    if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "false") or
        std.mem.eql(u8, str, "null") or std.mem.eql(u8, str, "~") or
        std.mem.eql(u8, str, "yes") or std.mem.eql(u8, str, "no"))
    {
        return true;
    }

    // Check if string starts with special characters
    switch (str[0]) {
        '-', '?', ':', '@', '`', '|', '>', '&', '*', '!', '%', '#', '[', ']', '{', '}', ',', '"', '\'', ' ' => return true,
        else => {},
    }

    // Check for special characters in the string
    for (str) |c| {
        switch (c) {
            '\n', '\r', '\t', ':', '#', ',', '[', ']', '{', '}', '"', '\'' => return true,
            else => if (c < 0x20 or c == 0x7F) return true,
        }
    }

    return false;
}

fn yamlEscapeString(builder: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try builder.appendSlice(allocator, "\\\""),
            '\\' => try builder.appendSlice(allocator, "\\\\"),
            '\n' => try builder.appendSlice(allocator, "\\n"),
            '\r' => try builder.appendSlice(allocator, "\\r"),
            '\t' => try builder.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20 or c == 0x7F) {
                    try builder.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\\x{x:0>2}", .{c}));
                } else {
                    try builder.append(allocator, c);
                }
            },
        }
    }
}

fn formatValuePrettyImpl(allocator: std.mem.Allocator, arena: std.mem.Allocator, value: Value, indent: usize) error{OutOfMemory}![]u8 {
    return switch (value) {
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .boolean => |v| try std.fmt.allocPrint(allocator, "{s}", .{if (v) "true" else "false"}),
        .null_value => try std.fmt.allocPrint(allocator, "null", .{}),
        .symbol => |s| try std.fmt.allocPrint(allocator, "{s}", .{s}),
        .function => try std.fmt.allocPrint(allocator, "<function>", .{}),
        .native_fn => try std.fmt.allocPrint(allocator, "<native function>", .{}),
        .thunk => blk: {
            // Force the thunk and format the result
            const forced = force(arena, value) catch break :blk try std.fmt.allocPrint(allocator, "<thunk error>", .{});
            break :blk try formatValuePrettyImpl(allocator, arena, forced, indent);
        },
        .array => |arr| blk: {
            if (arr.elements.len == 0) {
                break :blk try std.fmt.allocPrint(allocator, "[]", .{});
            }

            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '[');

            // Check if all elements are simple (primitives, not nested structures)
            var all_simple = true;
            for (arr.elements) |element| {
                if (element == .array or element == .object or element == .tuple) {
                    all_simple = false;
                    break;
                }
                if (element == .thunk) {
                    const forced = force(arena, element) catch {
                        all_simple = false;
                        break;
                    };
                    if (forced == .array or forced == .object or forced == .tuple) {
                        all_simple = false;
                        break;
                    }
                }
            }

            if (all_simple) {
                // Single-line format for simple arrays
                for (arr.elements, 0..) |element, i| {
                    if (i != 0) try builder.appendSlice(allocator, ", ");
                    const formatted = try formatValuePrettyImpl(allocator, arena, element, indent);
                    defer allocator.free(formatted);
                    try builder.appendSlice(allocator, formatted);
                }
                try builder.append(allocator, ']');
            } else {
                // Multi-line format for complex arrays
                try builder.append(allocator, '\n');
                for (arr.elements, 0..) |element, i| {
                    // Indentation
                    for (0..indent + 1) |_| {
                        try builder.appendSlice(allocator, "  ");
                    }
                    const formatted = try formatValuePrettyImpl(allocator, arena, element, indent + 1);
                    defer allocator.free(formatted);
                    try builder.appendSlice(allocator, formatted);
                    if (i < arr.elements.len - 1) {
                        try builder.append(allocator, ',');
                    }
                    try builder.append(allocator, '\n');
                }
                // Closing bracket with proper indentation
                for (0..indent) |_| {
                    try builder.appendSlice(allocator, "  ");
                }
                try builder.append(allocator, ']');
            }

            break :blk try builder.toOwnedSlice(allocator);
        },
        .tuple => |tup| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '(');
            for (tup.elements, 0..) |element, i| {
                if (i != 0) try builder.appendSlice(allocator, ", ");
                const formatted = try formatValuePrettyImpl(allocator, arena, element, indent);
                defer allocator.free(formatted);
                try builder.appendSlice(allocator, formatted);
            }
            try builder.append(allocator, ')');

            break :blk try builder.toOwnedSlice(allocator);
        },
        .object => |obj| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            if (obj.fields.len == 0) {
                try builder.appendSlice(allocator, "{}");
            } else if (obj.fields.len > 3) {
                // Multi-line format for larger objects
                try builder.appendSlice(allocator, "{\n");
                for (obj.fields, 0..) |field, i| {
                    // Indentation
                    for (0..indent + 1) |_| {
                        try builder.appendSlice(allocator, "  ");
                    }
                    try builder.appendSlice(allocator, field.key);
                    try builder.appendSlice(allocator, ": ");
                    const formatted = try formatValuePrettyImpl(allocator, arena, field.value, indent + 1);
                    defer allocator.free(formatted);
                    try builder.appendSlice(allocator, formatted);
                    if (i < obj.fields.len - 1) {
                        try builder.append(allocator, ',');
                    }
                    try builder.append(allocator, '\n');
                }
                // Closing brace with proper indentation
                for (0..indent) |_| {
                    try builder.appendSlice(allocator, "  ");
                }
                try builder.append(allocator, '}');
            } else {
                // Check if all fields are simple (primitives, functions, or strings only)
                var all_simple = true;
                for (obj.fields) |field| {
                    const val = if (field.value == .thunk)
                        force(arena, field.value) catch {
                            all_simple = false;
                            break;
                        }
                    else
                        field.value;

                    // Consider nested structures (arrays, objects, tuples) as complex
                    if (val == .array or val == .object or val == .tuple) {
                        all_simple = false;
                        break;
                    }
                }

                if (all_simple) {
                    // Single-line format for simple, small objects
                    try builder.appendSlice(allocator, "{ ");
                    for (obj.fields, 0..) |field, i| {
                        if (i != 0) try builder.appendSlice(allocator, ", ");
                        try builder.appendSlice(allocator, field.key);
                        try builder.appendSlice(allocator, ": ");
                        const formatted = try formatValuePrettyImpl(allocator, arena, field.value, indent);
                        defer allocator.free(formatted);
                        try builder.appendSlice(allocator, formatted);
                    }
                    try builder.appendSlice(allocator, " }");
                } else {
                    // Multi-line format for objects with complex values
                    try builder.appendSlice(allocator, "{\n");
                    for (obj.fields, 0..) |field, i| {
                        // Indentation
                        for (0..indent + 1) |_| {
                            try builder.appendSlice(allocator, "  ");
                        }
                        try builder.appendSlice(allocator, field.key);
                        try builder.appendSlice(allocator, ": ");
                        const formatted = try formatValuePrettyImpl(allocator, arena, field.value, indent + 1);
                        defer allocator.free(formatted);
                        try builder.appendSlice(allocator, formatted);
                        if (i < obj.fields.len - 1) {
                            try builder.append(allocator, ',');
                        }
                        try builder.append(allocator, '\n');
                    }
                    // Closing brace with proper indentation
                    for (0..indent) |_| {
                        try builder.appendSlice(allocator, "  ");
                    }
                    try builder.append(allocator, '}');
                }
            }

            break :blk try builder.toOwnedSlice(allocator);
        },
        .string => |str| try std.fmt.allocPrint(allocator, "\"{s}\"", .{str}),
    };
}

fn formatValueWithArena(allocator: std.mem.Allocator, arena: std.mem.Allocator, value: Value) error{OutOfMemory}![]u8 {
    return switch (value) {
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .boolean => |v| try std.fmt.allocPrint(allocator, "{s}", .{if (v) "true" else "false"}),
        .null_value => try std.fmt.allocPrint(allocator, "null", .{}),
        .symbol => |s| try std.fmt.allocPrint(allocator, "{s}", .{s}),
        .function => try std.fmt.allocPrint(allocator, "<function>", .{}),
        .native_fn => try std.fmt.allocPrint(allocator, "<native function>", .{}),
        .thunk => blk: {
            // Force the thunk and format the result
            const forced = force(arena, value) catch break :blk try std.fmt.allocPrint(allocator, "<thunk error>", .{});
            break :blk try formatValueWithArena(allocator, arena, forced);
        },
        .array => |arr| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '[');
            for (arr.elements, 0..) |element, i| {
                if (i != 0) try builder.appendSlice(allocator, ", ");
                const formatted = try formatValueWithArena(allocator, arena, element);
                defer allocator.free(formatted);
                try builder.appendSlice(allocator, formatted);
            }
            try builder.append(allocator, ']');

            break :blk try builder.toOwnedSlice(allocator);
        },
        .tuple => |tup| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '(');
            for (tup.elements, 0..) |element, i| {
                if (i != 0) try builder.appendSlice(allocator, ", ");
                const formatted = try formatValueWithArena(allocator, arena, element);
                defer allocator.free(formatted);
                try builder.appendSlice(allocator, formatted);
            }
            try builder.append(allocator, ')');

            break :blk try builder.toOwnedSlice(allocator);
        },
        .object => |obj| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            if (obj.fields.len == 0) {
                try builder.appendSlice(allocator, "{}");
            } else {
                try builder.appendSlice(allocator, "{ ");
                for (obj.fields, 0..) |field, i| {
                    if (i != 0) try builder.appendSlice(allocator, ", ");
                    try builder.appendSlice(allocator, field.key);
                    try builder.appendSlice(allocator, ": ");
                    const formatted = try formatValueWithArena(allocator, arena, field.value);
                    defer allocator.free(formatted);
                    try builder.appendSlice(allocator, formatted);
                }
                try builder.appendSlice(allocator, " }");
            }

            break :blk try builder.toOwnedSlice(allocator);
        },
        .string => |str| try std.fmt.allocPrint(allocator, "\"{s}\"", .{str}),
    };
}
