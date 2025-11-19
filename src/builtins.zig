//! Native builtin functions for Lazylang.
//!
//! This module implements native functions that are exposed to Lazylang code
//! via the builtin environment. Functions are prefixed with __ in the environment
//! and typically wrapped by stdlib modules (Array.lazy, String.lazy, etc.).
//!
//! Categories:
//! - Array operations: length, get, fold, reverse
//! - String operations: length, concat, split, toUpperCase, toLowerCase, etc.
//! - Math operations: round, floor, ceil, abs, sqrt, pow, mod, rem
//! - Object operations: get
//! - Error handling: crash
//!
//! All functions follow the signature:
//!   fn(arena: Allocator, args: []const Value) EvalError!Value
//!
//! The arena allocator is used for all allocations - memory is freed in bulk
//! when evaluation completes. Functions validate argument counts and types,
//! returning appropriate errors for invalid inputs.

const std = @import("std");
const eval = @import("eval.zig");
const yaml = @import("yaml.zig");

// Array builtins

pub fn arrayLength(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const array = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    return eval.Value{ .integer = @intCast(array.elements.len) };
}

pub fn arrayGet(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const array = switch (tuple_arg.elements[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    const index = switch (tuple_arg.elements[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    if (index < 0 or index >= array.elements.len) {
        return eval.Value{ .symbol = "#outOfBounds" };
    }

    // Return (#ok, value)
    const result_elements = try arena.alloc(eval.Value, 2);
    result_elements[0] = eval.Value{ .symbol = "#ok" };
    result_elements[1] = array.elements[@intCast(index)];
    return eval.Value{ .tuple = .{ .elements = result_elements } };
}

pub fn arrayReverse(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const array = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    const reversed = try arena.alloc(eval.Value, array.elements.len);
    for (array.elements, 0..) |elem, i| {
        reversed[array.elements.len - 1 - i] = elem;
    }

    return eval.Value{ .array = .{ .elements = reversed } };
}

pub fn arrayFold(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 3) return error.WrongNumberOfArguments;

    const function = tuple_arg.elements[0];
    var accumulator = tuple_arg.elements[1];
    const array = switch (tuple_arg.elements[2]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    // Apply function to each element: fold(fn, init, [x, y, z]) = fn(fn(fn(init, x), y), z)
    // Function is curried: acc -> x -> result
    const ctx = eval.EvalContext{
        .allocator = arena,
        .lazy_paths = &[_][]const u8{},
        .error_ctx = null,
    };

    for (array.elements) |element| {
        // Apply function to accumulator: fn(acc)(elem)
        accumulator = switch (function) {
            .function => |func| blk: {
                // Apply first argument (accumulator)
                const env1 = try eval.matchPattern(arena, func.param, accumulator, func.env, &ctx);
                const intermediate = try eval.evaluateExpression(arena, func.body, env1, null, &ctx);

                // The result should be a function, apply second argument (element)
                const func2 = switch (intermediate) {
                    .function => |f| f,
                    else => return error.TypeMismatch,
                };
                const env2 = try eval.matchPattern(arena, func2.param, element, func2.env, &ctx);
                break :blk try eval.evaluateExpression(arena, func2.body, env2, null, &ctx);
            },
            else => return error.TypeMismatch,
        };
    }

    return accumulator;
}

pub fn arrayConcatAll(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const array = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    // Calculate total length
    var total_len: usize = 0;
    for (array.elements) |elem| {
        const str = switch (elem) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        total_len += str.len;
    }

    // Concatenate all strings
    const result = try arena.alloc(u8, total_len);
    var offset: usize = 0;
    for (array.elements) |elem| {
        const str = elem.string;
        @memcpy(result[offset..][0..str.len], str);
        offset += str.len;
    }

    return eval.Value{ .string = result };
}

pub fn arraySlice(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 3) return error.WrongNumberOfArguments;

    const start_val = switch (tuple_arg.elements[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const end_val = switch (tuple_arg.elements[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const array = switch (tuple_arg.elements[2]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    const len = @as(i64, @intCast(array.elements.len));

    // Normalize negative indices
    const start = if (start_val < 0) @max(0, len + start_val) else @min(start_val, len);
    const end = if (end_val < 0) @max(0, len + end_val) else @min(end_val, len);

    // Handle invalid ranges
    if (start >= end or start >= len) {
        const empty = try arena.alloc(eval.Value, 0);
        return eval.Value{ .array = .{ .elements = empty } };
    }

    const slice_start = @as(usize, @intCast(start));
    const slice_end = @as(usize, @intCast(end));
    const slice_len = slice_end - slice_start;

    const result = try arena.alloc(eval.Value, slice_len);
    @memcpy(result, array.elements[slice_start..slice_end]);

    return eval.Value{ .array = .{ .elements = result } };
}

pub fn arraySort(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const array = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    // Create a copy to sort
    const result = try arena.alloc(eval.Value, array.elements.len);
    @memcpy(result, array.elements);

    // Sort using a simple comparison
    const Context = struct {
        fn lessThan(_: void, a: eval.Value, b: eval.Value) bool {
            return switch (a) {
                .integer => |av| switch (b) {
                    .integer => |bv| av < bv,
                    else => false,
                },
                .string => |av| switch (b) {
                    .string => |bv| std.mem.order(u8, av, bv) == .lt,
                    else => false,
                },
                else => false,
            };
        }
    };

    std.mem.sort(eval.Value, result, {}, Context.lessThan);

    return eval.Value{ .array = .{ .elements = result } };
}

pub fn arrayUniq(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const array = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    if (array.elements.len == 0) {
        const empty = try arena.alloc(eval.Value, 0);
        return eval.Value{ .array = .{ .elements = empty } };
    }

    // Use ArrayList to build result
    var seen = std.ArrayList(eval.Value){};
    defer seen.deinit(arena);

    for (array.elements) |elem| {
        // Check if element is already in seen
        var found = false;
        for (seen.items) |seen_elem| {
            if (valuesEqual(arena, elem, seen_elem)) {
                found = true;
                break;
            }
        }

        if (!found) {
            try seen.append(arena, elem);
        }
    }

    return eval.Value{ .array = .{ .elements = try seen.toOwnedSlice(arena) } };
}

fn valuesEqual(arena: std.mem.Allocator, a: eval.Value, b: eval.Value) bool {
    // Force thunks before comparison
    const a_forced = eval.force(arena, a) catch a;
    const b_forced = eval.force(arena, b) catch b;

    return switch (a_forced) {
        .integer => |av| switch (b_forced) {
            .integer => |bv| av == bv,
            else => false,
        },
        .boolean => |av| switch (b_forced) {
            .boolean => |bv| av == bv,
            else => false,
        },
        .null_value => switch (b_forced) {
            .null_value => true,
            else => false,
        },
        .symbol => |av| switch (b_forced) {
            .symbol => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .string => |av| switch (b_forced) {
            .string => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        else => false, // Functions, arrays, objects, tuples not compared
    };
}

// String builtins
pub fn stringLength(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    return eval.Value{ .integer = @intCast(str.len) };
}

pub fn stringConcat(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const a = switch (tuple_arg.elements[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const b = switch (tuple_arg.elements[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = try std.fmt.allocPrint(arena, "{s}{s}", .{ a, b });
    return eval.Value{ .string = result };
}

pub fn stringSplit(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const str = switch (tuple_arg.elements[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const delimiter = switch (tuple_arg.elements[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    var parts = std.ArrayList(eval.Value){};
    defer parts.deinit(arena);

    var iter = std.mem.splitSequence(u8, str, delimiter);
    while (iter.next()) |part| {
        const part_copy = try arena.dupe(u8, part);
        try parts.append(arena, eval.Value{ .string = part_copy });
    }

    return eval.Value{ .array = .{ .elements = try parts.toOwnedSlice(arena) } };
}

pub fn stringToUpper(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = try arena.alloc(u8, str.len);
    for (str, 0..) |c, i| {
        result[i] = std.ascii.toUpper(c);
    }

    return eval.Value{ .string = result };
}

pub fn stringToLower(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = try arena.alloc(u8, str.len);
    for (str, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }

    return eval.Value{ .string = result };
}

pub fn stringChars(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const chars = try arena.alloc(eval.Value, str.len);
    for (str, 0..) |c, i| {
        const char_str = try arena.alloc(u8, 1);
        char_str[0] = c;
        chars[i] = eval.Value{ .string = char_str };
    }

    return eval.Value{ .array = .{ .elements = chars } };
}

pub fn stringTrim(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const trimmed = std.mem.trim(u8, str, &std.ascii.whitespace);
    const result = try arena.dupe(u8, trimmed);

    return eval.Value{ .string = result };
}

pub fn stringStartsWith(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const str = switch (tuple_arg.elements[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const prefix = switch (tuple_arg.elements[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = std.mem.startsWith(u8, str, prefix);
    return eval.Value{ .boolean = result };
}

pub fn stringEndsWith(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const str = switch (tuple_arg.elements[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const suffix = switch (tuple_arg.elements[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = std.mem.endsWith(u8, str, suffix);
    return eval.Value{ .boolean = result };
}

pub fn stringContains(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const str = switch (tuple_arg.elements[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const substring = switch (tuple_arg.elements[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = std.mem.indexOf(u8, str, substring) != null;
    return eval.Value{ .boolean = result };
}

pub fn stringRepeat(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const count = switch (tuple_arg.elements[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const str = switch (tuple_arg.elements[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (count < 0) return error.TypeMismatch;
    if (count == 0) {
        const empty = try arena.alloc(u8, 0);
        return eval.Value{ .string = empty };
    }

    const total_len = str.len * @as(usize, @intCast(count));
    const result = try arena.alloc(u8, total_len);

    var offset: usize = 0;
    var i: i64 = 0;
    while (i < count) : (i += 1) {
        @memcpy(result[offset..][0..str.len], str);
        offset += str.len;
    }

    return eval.Value{ .string = result };
}

pub fn stringReplace(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 3) return error.WrongNumberOfArguments;

    const from = switch (tuple_arg.elements[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const to = switch (tuple_arg.elements[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const str = switch (tuple_arg.elements[2]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    // Handle empty 'from' string - return original
    if (from.len == 0) {
        const result = try arena.dupe(u8, str);
        return eval.Value{ .string = result };
    }

    // Count occurrences
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, str, pos, from)) |found| {
        count += 1;
        pos = found + from.len;
    }

    if (count == 0) {
        const result = try arena.dupe(u8, str);
        return eval.Value{ .string = result };
    }

    // Calculate result length
    const result_len = str.len - (from.len * count) + (to.len * count);
    const result = try arena.alloc(u8, result_len);

    // Perform replacement
    var src_pos: usize = 0;
    var dst_pos: usize = 0;
    while (std.mem.indexOfPos(u8, str, src_pos, from)) |found| {
        // Copy text before match
        const before_len = found - src_pos;
        @memcpy(result[dst_pos..][0..before_len], str[src_pos..found]);
        dst_pos += before_len;

        // Copy replacement
        @memcpy(result[dst_pos..][0..to.len], to);
        dst_pos += to.len;

        src_pos = found + from.len;
    }

    // Copy remaining text
    const remaining = str[src_pos..];
    @memcpy(result[dst_pos..][0..remaining.len], remaining);

    return eval.Value{ .string = result };
}

pub fn stringSlice(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 3) return error.WrongNumberOfArguments;

    const start_val = switch (tuple_arg.elements[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const end_val = switch (tuple_arg.elements[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const str = switch (tuple_arg.elements[2]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const len = @as(i64, @intCast(str.len));

    // Normalize negative indices
    const start = if (start_val < 0) @max(0, len + start_val) else @min(start_val, len);
    const end = if (end_val < 0) @max(0, len + end_val) else @min(end_val, len);

    // Handle invalid ranges
    if (start >= end or start >= len) {
        const empty = try arena.alloc(u8, 0);
        return eval.Value{ .string = empty };
    }

    const slice_start = @as(usize, @intCast(start));
    const slice_end = @as(usize, @intCast(end));

    const result = try arena.dupe(u8, str[slice_start..slice_end]);
    return eval.Value{ .string = result };
}

pub fn stringJoin(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const separator = switch (tuple_arg.elements[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const array = switch (tuple_arg.elements[1]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    if (array.elements.len == 0) {
        const empty = try arena.alloc(u8, 0);
        return eval.Value{ .string = empty };
    }

    if (array.elements.len == 1) {
        const str = switch (array.elements[0]) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        const result = try arena.dupe(u8, str);
        return eval.Value{ .string = result };
    }

    // Calculate total length
    var total_len: usize = 0;
    for (array.elements, 0..) |elem, i| {
        const str = switch (elem) {
            .string => |s| s,
            else => return error.TypeMismatch,
        };
        total_len += str.len;
        if (i < array.elements.len - 1) {
            total_len += separator.len;
        }
    }

    // Build result
    const result = try arena.alloc(u8, total_len);
    var offset: usize = 0;
    for (array.elements, 0..) |elem, i| {
        const str = elem.string;
        @memcpy(result[offset..][0..str.len], str);
        offset += str.len;

        if (i < array.elements.len - 1) {
            @memcpy(result[offset..][0..separator.len], separator);
            offset += separator.len;
        }
    }

    return eval.Value{ .string = result };
}

// Math builtins
pub fn mathMax(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const a = switch (tuple_arg.elements[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const b = switch (tuple_arg.elements[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    return eval.Value{ .integer = @max(a, b) };
}

pub fn mathMin(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const a = switch (tuple_arg.elements[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const b = switch (tuple_arg.elements[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    return eval.Value{ .integer = @min(a, b) };
}

pub fn mathAbs(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const n = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    return eval.Value{ .integer = if (n < 0) -n else n };
}

// Object builtins
pub fn objectKeys(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const obj = switch (args[0]) {
        .object => |o| o,
        else => return error.TypeMismatch,
    };

    const keys = try arena.alloc(eval.Value, obj.fields.len);
    for (obj.fields, 0..) |field, i| {
        keys[i] = eval.Value{ .string = field.key };
    }
    return eval.Value{ .array = .{ .elements = keys } };
}

pub fn objectValues(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const obj = switch (args[0]) {
        .object => |o| o,
        else => return error.TypeMismatch,
    };

    const values = try arena.alloc(eval.Value, obj.fields.len);
    for (obj.fields, 0..) |field, i| {
        values[i] = try eval.force(arena, field.value);
    }
    return eval.Value{ .array = .{ .elements = values } };
}

pub fn objectGet(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const obj = switch (tuple_arg.elements[0]) {
        .object => |o| o,
        else => return error.TypeMismatch,
    };

    const key = switch (tuple_arg.elements[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    for (obj.fields) |field| {
        if (std.mem.eql(u8, field.key, key)) {
            // Force thunk if needed before returning
            const forced_value = try eval.force(arena, field.value);
            // Return (#ok, value)
            const result_elements = try arena.alloc(eval.Value, 2);
            result_elements[0] = eval.Value{ .symbol = "#ok" };
            result_elements[1] = forced_value;
            return eval.Value{ .tuple = .{ .elements = result_elements } };
        }
    }

    return eval.Value{ .symbol = "#noSuchKey" };
}

pub fn mathPow(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const base = switch (tuple_arg.elements[0]) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    const exponent = switch (tuple_arg.elements[1]) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    const result = std.math.pow(f64, base, exponent);
    return eval.Value{ .integer = @intFromFloat(result) };
}

pub fn mathSqrt(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const n = switch (args[0]) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    const result = @sqrt(n);
    return eval.Value{ .integer = @intFromFloat(result) };
}

pub fn mathFloor(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const n = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    // For integers, floor is identity
    return eval.Value{ .integer = n };
}

pub fn mathCeil(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const n = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    // For integers, ceil is identity
    return eval.Value{ .integer = n };
}

pub fn mathRound(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const n = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    // For integers, round is identity
    return eval.Value{ .integer = n };
}

pub fn mathLog(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const n = switch (args[0]) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    const result = @log(n);
    return eval.Value{ .integer = @intFromFloat(result) };
}

pub fn mathExp(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const n = switch (args[0]) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    const result = @exp(n);
    return eval.Value{ .integer = @intFromFloat(result) };
}

// Error handling builtins
pub fn crash(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const message = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    // Duplicate the message using page_allocator so it persists after arena is freed
    // The message will be freed when clearUserCrashMessage is called
    const message_copy = try std.heap.page_allocator.dupe(u8, message);
    eval.setUserCrashMessage(message_copy);
    return error.UserCrash;
}

// Utility to create a curried native function wrapper
// This allows native functions to be partially applied like regular functions
pub fn curry2(comptime impl: fn (std.mem.Allocator, eval.Value, eval.Value) eval.EvalError!eval.Value) eval.NativeFn {
    const Wrapper = struct {
        fn call(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
            if (args.len != 1) return error.WrongNumberOfArguments;

            const tuple_arg = switch (args[0]) {
                .tuple => |t| t,
                else => return error.TypeMismatch,
            };

            if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

            return impl(arena, tuple_arg.elements[0], tuple_arg.elements[1]);
        }
    };
    return Wrapper.call;
}

// YAML builtins

/// Parse a YAML string into a Lazylang value
/// Returns (#ok, value) on success or (#error, message) on failure
pub fn yamlParse(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const yaml_str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = yaml.parse(arena, yaml_str) catch |err| {
        const error_msg = switch (err) {
            error.InvalidYaml => "Invalid YAML syntax",
            error.UnexpectedToken => "Unexpected token in YAML",
            error.OutOfMemory => "Out of memory while parsing YAML",
            else => "Failed to parse YAML",
        };

        const msg = try arena.dupe(u8, error_msg);
        const result_elements = try arena.alloc(eval.Value, 2);
        result_elements[0] = eval.Value{ .symbol = "#error" };
        result_elements[1] = eval.Value{ .string = msg };
        return eval.Value{ .tuple = .{ .elements = result_elements } };
    };

    // Return (#ok, value)
    const result_elements = try arena.alloc(eval.Value, 2);
    result_elements[0] = eval.Value{ .symbol = "#ok" };
    result_elements[1] = result;
    return eval.Value{ .tuple = .{ .elements = result_elements } };
}

/// Encode a Lazylang value into a YAML string
/// Returns the YAML string directly. Throws error if value cannot be encoded (e.g., functions).
pub fn yamlEncode(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const value = args[0];
    const yaml_str = yaml.encode(arena, value) catch |err| {
        return switch (err) {
            error.TypeMismatch => error.TypeMismatch,
            error.OutOfMemory => error.OutOfMemory,
            error.UserCrash => error.UserCrash,
            else => error.TypeMismatch, // Treat other YAML errors as type mismatches
        };
    };
    return eval.Value{ .string = yaml_str };
}

// JSON builtins

const json = @import("json.zig");

/// Parse a JSON string into a Lazylang value
/// Returns (#ok, value) on success or (#error, message) on failure
pub fn jsonParse(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const json_str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = json.parse(arena, json_str) catch |err| {
        const error_msg = switch (err) {
            error.InvalidJson => "Invalid JSON syntax",
            error.NumberOutOfRange => "Number out of range",
            error.UnsupportedType => "Unsupported type in JSON",
            error.OutOfMemory => "Out of memory while parsing JSON",
            else => "Failed to parse JSON",
        };

        const msg = try arena.dupe(u8, error_msg);
        const result_elements = try arena.alloc(eval.Value, 2);
        result_elements[0] = eval.Value{ .symbol = "#error" };
        result_elements[1] = eval.Value{ .string = msg };
        return eval.Value{ .tuple = .{ .elements = result_elements } };
    };

    // Return (#ok, value)
    const result_elements = try arena.alloc(eval.Value, 2);
    result_elements[0] = eval.Value{ .symbol = "#ok" };
    result_elements[1] = result;
    return eval.Value{ .tuple = .{ .elements = result_elements } };
}

/// Encode a Lazylang value into a JSON string
/// Returns the JSON string directly. Throws error if value cannot be encoded (e.g., functions).
pub fn jsonEncode(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const value = args[0];
    const json_str = json.encode(arena, value) catch |err| {
        return switch (err) {
            error.UnsupportedType => error.TypeMismatch,
            error.OutOfMemory => error.OutOfMemory,
            error.UserCrash => error.UserCrash,
            else => error.TypeMismatch,
        };
    };
    return eval.Value{ .string = json_str };
}

// Float/Math builtins

/// Round a float to the nearest integer
pub fn floatRound(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const value = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return eval.Value{ .integer = @intFromFloat(@round(value)) };
}

/// Floor of a float (round down)
pub fn floatFloor(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const value = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return eval.Value{ .integer = @intFromFloat(@floor(value)) };
}

/// Ceiling of a float (round up)
pub fn floatCeil(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const value = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return eval.Value{ .integer = @intFromFloat(@ceil(value)) };
}

/// Absolute value
pub fn floatAbs(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    return switch (args[0]) {
        .float => |f| eval.Value{ .float = @abs(f) },
        .integer => |i| eval.Value{ .integer = if (i < 0) -i else i },
        else => error.TypeMismatch,
    };
}

/// Square root
pub fn floatSqrt(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const value = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return eval.Value{ .float = @sqrt(value) };
}

/// Power (x^y)
pub fn floatPow(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const base = switch (tuple_arg.elements[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    const exponent = switch (tuple_arg.elements[1]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return eval.Value{ .float = std.math.pow(f64, base, exponent) };
}

/// Modulo operation (remainder with sign of divisor)
pub fn mathMod(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    // Check if we're dealing with floats
    const is_float = (tuple_arg.elements[0] == .float or tuple_arg.elements[1] == .float);

    if (is_float) {
        const a = switch (tuple_arg.elements[0]) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => return error.TypeMismatch,
        };

        const b = switch (tuple_arg.elements[1]) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => return error.TypeMismatch,
        };

        if (b == 0.0) return error.DivisionByZero;
        return eval.Value{ .float = @mod(a, b) };
    } else {
        const a = switch (tuple_arg.elements[0]) {
            .integer => |i| i,
            else => return error.TypeMismatch,
        };

        const b = switch (tuple_arg.elements[1]) {
            .integer => |i| i,
            else => return error.TypeMismatch,
        };

        if (b == 0) return error.DivisionByZero;
        return eval.Value{ .integer = @mod(a, b) };
    }
}

/// Remainder operation (remainder with sign of dividend)
pub fn mathRem(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    // Check if we're dealing with floats
    const is_float = (tuple_arg.elements[0] == .float or tuple_arg.elements[1] == .float);

    if (is_float) {
        const a = switch (tuple_arg.elements[0]) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => return error.TypeMismatch,
        };

        const b = switch (tuple_arg.elements[1]) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => return error.TypeMismatch,
        };

        if (b == 0.0) return error.DivisionByZero;
        return eval.Value{ .float = @rem(a, b) };
    } else {
        const a = switch (tuple_arg.elements[0]) {
            .integer => |i| i,
            else => return error.TypeMismatch,
        };

        const b = switch (tuple_arg.elements[1]) {
            .integer => |i| i,
            else => return error.TypeMismatch,
        };

        if (b == 0) return error.DivisionByZero;
        return eval.Value{ .integer = @rem(a, b) };
    }
}

// Type predicate builtins

/// Check if a value is an integer
pub fn isInteger(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    return eval.Value{ .boolean = args[0] == .integer };
}

/// Check if a value is a float
pub fn isFloat(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    return eval.Value{ .boolean = args[0] == .float };
}

/// Check if a value is a boolean
pub fn isBoolean(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    return eval.Value{ .boolean = args[0] == .boolean };
}

/// Check if a value is null
pub fn isNull(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    return eval.Value{ .boolean = args[0] == .null_value };
}

/// Check if a value is a symbol
pub fn isSymbol(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    return eval.Value{ .boolean = args[0] == .symbol };
}

/// Check if a value is a string
pub fn isString(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    return eval.Value{ .boolean = args[0] == .string };
}

/// Check if a value is an array
pub fn isArray(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    return eval.Value{ .boolean = args[0] == .array };
}

/// Check if a value is a tuple
pub fn isTuple(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    return eval.Value{ .boolean = args[0] == .tuple };
}

/// Check if a value is an object
pub fn isObject(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    return eval.Value{ .boolean = args[0] == .object };
}

/// Check if a value is a function (either Lazylang function or native function)
pub fn isFunction(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    return eval.Value{ .boolean = args[0] == .function or args[0] == .native_fn };
}
