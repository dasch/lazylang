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

// Helper: extract exactly 2 elements from a tuple argument.
fn extractTuple2(args: []const eval.Value) eval.EvalError!struct { eval.Value, eval.Value } {
    if (args.len != 1) return error.WrongNumberOfArguments;
    const t = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };
    if (t.elements.len != 2) return error.WrongNumberOfArguments;
    return .{ t.elements[0], t.elements[1] };
}

// Helper: extract exactly 3 elements from a tuple argument.
fn extractTuple3(args: []const eval.Value) eval.EvalError!struct { eval.Value, eval.Value, eval.Value } {
    if (args.len != 1) return error.WrongNumberOfArguments;
    const t = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };
    if (t.elements.len != 3) return error.WrongNumberOfArguments;
    return .{ t.elements[0], t.elements[1], t.elements[2] };
}

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
        return eval.Value{ .string = "outOfBounds" };
    }

    // Return (#ok, value)
    const result_elements = try arena.alloc(eval.Value, 2);
    result_elements[0] = eval.Value{ .string = "ok" };
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
    var fold_recursion_depth: u32 = 0;
    const ctx = eval.EvalContext{
        .allocator = arena,
        .lazy_paths = &[_][]const u8{},
        .error_ctx = null,
        .recursion_depth = &fold_recursion_depth,
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

pub fn stringConcatAll(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
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

    // Detect the type of the first element to pick a fast path.
    // We force thunks on the first element to get its actual type.
    const first = try eval.force(arena, array.elements[0]);

    switch (first) {
        .integer => {
            // Fast path: O(n) with hash set for integer arrays.
            var seen_set = std.AutoHashMap(i64, void).init(arena);
            defer seen_set.deinit();
            var result = std.ArrayListUnmanaged(eval.Value){};
            defer result.deinit(arena);

            for (array.elements) |elem| {
                const forced = try eval.force(arena, elem);
                const val = switch (forced) {
                    .integer => |i| i,
                    else => {
                        // Mixed type array — fall back to linear scan from this point.
                        // Flush what we have so far, then process remaining elements linearly.
                        return arrayUniqLinear(arena, array.elements);
                    },
                };
                const gop = try seen_set.getOrPut(val);
                if (!gop.found_existing) {
                    try result.append(arena, forced);
                }
            }
            return eval.Value{ .array = .{ .elements = try result.toOwnedSlice(arena) } };
        },
        .string => {
            // Fast path: O(n) with hash set for string arrays.
            var seen_set = std.StringHashMap(void).init(arena);
            defer seen_set.deinit();
            var result = std.ArrayListUnmanaged(eval.Value){};
            defer result.deinit(arena);

            for (array.elements) |elem| {
                const forced = try eval.force(arena, elem);
                const val = switch (forced) {
                    .string => |s| s,
                    else => return arrayUniqLinear(arena, array.elements),
                };
                const gop = try seen_set.getOrPut(val);
                if (!gop.found_existing) {
                    try result.append(arena, forced);
                }
            }
            return eval.Value{ .array = .{ .elements = try result.toOwnedSlice(arena) } };
        },
        .boolean => {
            // Fast path: at most two distinct values.
            var seen_true = false;
            var seen_false = false;
            var result = std.ArrayListUnmanaged(eval.Value){};
            defer result.deinit(arena);

            for (array.elements) |elem| {
                const forced = try eval.force(arena, elem);
                const val = switch (forced) {
                    .boolean => |b| b,
                    else => return arrayUniqLinear(arena, array.elements),
                };
                if (val) {
                    if (!seen_true) {
                        seen_true = true;
                        try result.append(arena, forced);
                    }
                } else {
                    if (!seen_false) {
                        seen_false = true;
                        try result.append(arena, forced);
                    }
                }
            }
            return eval.Value{ .array = .{ .elements = try result.toOwnedSlice(arena) } };
        },
        .null_value => {
            // Fast path: all nulls deduplicate to one.
            for (array.elements) |elem| {
                const forced = try eval.force(arena, elem);
                switch (forced) {
                    .null_value => {},
                    else => return arrayUniqLinear(arena, array.elements),
                }
            }
            const result = try arena.alloc(eval.Value, 1);
            result[0] = eval.Value{ .null_value = {} };
            return eval.Value{ .array = .{ .elements = result } };
        },
        else => {
            // Complex or unsupported type: fall back to O(n²) linear scan.
            return arrayUniqLinear(arena, array.elements);
        },
    }
}

/// Linear-scan dedup for complex or mixed-type arrays. O(n²) but handles all types.
fn arrayUniqLinear(arena: std.mem.Allocator, elements: []const eval.Value) eval.EvalError!eval.Value {
    var result = std.ArrayListUnmanaged(eval.Value){};
    defer result.deinit(arena);

    for (elements) |elem| {
        var found = false;
        for (result.items) |seen_elem| {
            if (try valuesEqual(arena, elem, seen_elem)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try result.append(arena, elem);
        }
    }

    return eval.Value{ .array = .{ .elements = try result.toOwnedSlice(arena) } };
}


fn rangeCreate(arena: std.mem.Allocator, args: []const eval.Value, comptime inclusive: bool) eval.EvalError!eval.Value {
    _ = arena;
    const start_val, const end_val = try extractTuple2(args);
    const start = switch (start_val) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };
    const end = switch (end_val) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };
    return eval.Value{ .range = .{ .start = start, .end = end, .inclusive = inclusive } };
}

pub fn rangeInclusive(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    return rangeCreate(arena, args, true);
}

pub fn rangeExclusive(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    return rangeCreate(arena, args, false);
}

pub fn rangeToArray(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const range = switch (args[0]) {
        .range => |r| r,
        else => return error.TypeMismatch,
    };

    // Calculate actual end
    const actual_end = if (range.inclusive) range.end else range.end - 1;

    // Empty range if start > actual_end
    if (range.start > actual_end) {
        const empty = try arena.alloc(eval.Value, 0);
        return eval.Value{ .array = .{ .elements = empty } };
    }

    const len = @as(usize, @intCast(actual_end - range.start + 1));
    const result = try arena.alloc(eval.Value, len);

    var i: usize = 0;
    var current = range.start;
    while (current <= actual_end) : (current += 1) {
        result[i] = eval.Value{ .integer = current };
        i += 1;
    }

    return eval.Value{ .array = .{ .elements = result } };
}

pub fn rangeCovers(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple_arg = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    if (tuple_arg.elements.len != 2) return error.WrongNumberOfArguments;

    const range = switch (tuple_arg.elements[0]) {
        .range => |r| r,
        else => return error.TypeMismatch,
    };

    const value = switch (tuple_arg.elements[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    // Check if value is within range
    const actual_end = if (range.inclusive) range.end else range.end - 1;
    const is_covered = value >= range.start and value <= actual_end;

    return eval.Value{ .boolean = is_covered };
}

const valuesEqual = eval.valuesEqual;

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

    const backing = try arena.alloc(u8, str.len);
    @memcpy(backing, str);
    const chars = try arena.alloc(eval.Value, str.len);
    for (0..str.len) |i| {
        chars[i] = eval.Value{ .string = backing[i .. i + 1] };
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
            result_elements[0] = eval.Value{ .string = "ok" };
            result_elements[1] = forced_value;
            return eval.Value{ .tuple = .{ .elements = result_elements } };
        }
    }

    return eval.Value{ .string = "noSuchKey" };
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

// For integers, floor/ceil/round are all identity functions.
fn mathIntIdentity(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    const n = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };
    return eval.Value{ .integer = n };
}

pub const mathFloor = mathIntIdentity;
pub const mathCeil = mathIntIdentity;
pub const mathRound = mathIntIdentity;

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

pub fn toString(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const value = args[0];
    const result = switch (value) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .float => |f| blk: {
            // Format float, stripping trailing zeros
            const raw = try std.fmt.allocPrint(arena, "{d}", .{f});
            // Check if it has a decimal point
            if (std.mem.indexOf(u8, raw, ".")) |dot_idx| {
                var end = raw.len;
                while (end > dot_idx + 1 and raw[end - 1] == '0') {
                    end -= 1;
                }
                // Don't strip the digit right after the dot
                if (end == dot_idx + 1) end = dot_idx + 2;
                break :blk raw[0..end];
            }
            break :blk raw;
        },
        .boolean => |b| if (b) "true" else "false",
        .null_value => "null",
        else => return error.TypeMismatch,
    };

    return eval.Value{ .string = result };
}

pub fn toInteger(_: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    return switch (args[0]) {
        .integer => args[0],
        .float => |f| eval.Value{ .integer = @intFromFloat(f) },
        .string => |s| eval.Value{ .integer = std.fmt.parseInt(i64, s, 10) catch return error.InvalidArgument },
        else => error.TypeMismatch,
    };
}

pub fn toFloat(_: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    return switch (args[0]) {
        .float => args[0],
        .integer => |i| eval.Value{ .float = @floatFromInt(i) },
        .string => |s| eval.Value{ .float = std.fmt.parseFloat(f64, s) catch return error.InvalidArgument },
        else => error.TypeMismatch,
    };
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
        result_elements[0] = eval.Value{ .string = "error" };
        result_elements[1] = eval.Value{ .string = msg };
        return eval.Value{ .tuple = .{ .elements = result_elements } };
    };

    // Return (#ok, value)
    const result_elements = try arena.alloc(eval.Value, 2);
    result_elements[0] = eval.Value{ .string = "ok" };
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
        result_elements[0] = eval.Value{ .string = "error" };
        result_elements[1] = eval.Value{ .string = msg };
        return eval.Value{ .tuple = .{ .elements = result_elements } };
    };

    // Return (#ok, value)
    const result_elements = try arena.alloc(eval.Value, 2);
    result_elements[0] = eval.Value{ .string = "ok" };
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

fn mathModRemImpl(
    arena: std.mem.Allocator,
    args: []const eval.Value,
    comptime float_op: fn (f64, f64) f64,
    comptime int_op: fn (i64, i64) i64,
) eval.EvalError!eval.Value {
    _ = arena;
    const a_val, const b_val = try extractTuple2(args);
    const is_float = (a_val == .float or b_val == .float);
    if (is_float) {
        const a = switch (a_val) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => return error.TypeMismatch,
        };
        const b = switch (b_val) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => return error.TypeMismatch,
        };
        if (b == 0.0) return error.DivisionByZero;
        return eval.Value{ .float = float_op(a, b) };
    } else {
        const a = switch (a_val) {
            .integer => |i| i,
            else => return error.TypeMismatch,
        };
        const b = switch (b_val) {
            .integer => |i| i,
            else => return error.TypeMismatch,
        };
        if (b == 0) return error.DivisionByZero;
        return eval.Value{ .integer = int_op(a, b) };
    }
}

/// Modulo operation (remainder with sign of divisor)
pub fn mathMod(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    return mathModRemImpl(arena, args, struct {
        fn f(a: f64, b: f64) f64 {
            return @mod(a, b);
        }
    }.f, struct {
        fn f(a: i64, b: i64) i64 {
            return @mod(a, b);
        }
    }.f);
}

/// Remainder operation (remainder with sign of dividend)
pub fn mathRem(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    return mathModRemImpl(arena, args, struct {
        fn f(a: f64, b: f64) f64 {
            return @rem(a, b);
        }
    }.f, struct {
        fn f(a: i64, b: i64) i64 {
            return @rem(a, b);
        }
    }.f);
}

// Bitwise operation builtins

fn intBinaryOp(comptime op: fn (i64, i64) i64) fn (std.mem.Allocator, []const eval.Value) eval.EvalError!eval.Value {
    return struct {
        fn call(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
            _ = arena;
            const a_val, const b_val = try extractTuple2(args);
            const a = switch (a_val) {
                .integer => |i| i,
                else => return error.TypeMismatch,
            };
            const b = switch (b_val) {
                .integer => |i| i,
                else => return error.TypeMismatch,
            };
            return eval.Value{ .integer = op(a, b) };
        }
    }.call;
}

/// Bitwise XOR: a ^ b
pub const bitwiseXor = intBinaryOp(struct {
    fn f(a: i64, b: i64) i64 {
        return a ^ b;
    }
}.f);

/// Bitwise AND: a & b
pub const bitwiseAnd = intBinaryOp(struct {
    fn f(a: i64, b: i64) i64 {
        return a & b;
    }
}.f);

fn bitwiseShift(
    arena: std.mem.Allocator,
    args: []const eval.Value,
    comptime direction: enum { left, right },
) eval.EvalError!eval.Value {
    _ = arena;
    const value_val, const shift_val = try extractTuple2(args);
    const value = switch (value_val) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };
    const shift = switch (shift_val) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };
    if (shift < 0 or shift >= 64) return error.TypeMismatch;
    const shift_u6: u6 = @intCast(shift);
    return eval.Value{ .integer = switch (direction) {
        .left => value << shift_u6,
        .right => value >> shift_u6,
    } };
}

/// Bitwise left shift: a << n
pub fn bitwiseShl(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    return bitwiseShift(arena, args, .left);
}

/// Bitwise right shift (arithmetic): a >> n
pub fn bitwiseShr(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    return bitwiseShift(arena, args, .right);
}

// Type predicate builtins

fn makeTypePredicate(comptime tag: std.meta.Tag(eval.Value)) fn (std.mem.Allocator, []const eval.Value) eval.EvalError!eval.Value {
    return struct {
        fn call(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
            _ = arena;
            if (args.len != 1) return error.WrongNumberOfArguments;
            return eval.Value{ .boolean = args[0] == tag };
        }
    }.call;
}

/// Check if a value is an integer
pub const isInteger = makeTypePredicate(.integer);
/// Check if a value is a float
pub const isFloat = makeTypePredicate(.float);
/// Check if a value is a boolean
pub const isBoolean = makeTypePredicate(.boolean);
/// Check if a value is null
pub const isNull = makeTypePredicate(.null_value);
/// Check if a value is a string
pub const isString = makeTypePredicate(.string);
/// Check if a value is an array
pub const isArray = makeTypePredicate(.array);
/// Check if a value is a tuple
pub const isTuple = makeTypePredicate(.tuple);

/// Get the length of a tuple
pub fn tupleLength(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    return eval.Value{ .integer = @intCast(tuple.elements.len) };
}

/// Convert a tuple to an array
pub fn tupleToArray(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const tuple = switch (args[0]) {
        .tuple => |t| t,
        else => return error.TypeMismatch,
    };

    // Create a new array with the same elements
    const elements = try arena.alloc(eval.Value, tuple.elements.len);
    for (tuple.elements, 0..) |elem, i| {
        elements[i] = elem;
    }

    return eval.Value{ .array = .{ .elements = elements } };
}

/// Convert an array to a tuple
pub fn tupleFromArray(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const array = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    // Create a new tuple with the same elements
    const elements = try arena.alloc(eval.Value, array.elements.len);
    for (array.elements, 0..) |elem, i| {
        elements[i] = elem;
    }

    return eval.Value{ .tuple = .{ .elements = elements } };
}

/// Check if a value is an object
pub const isObject = makeTypePredicate(.object);

/// Check if a value is a function (either Lazylang function or native function)
pub fn isFunction(arena: std.mem.Allocator, args: []const eval.Value) eval.EvalError!eval.Value {
    _ = arena;
    if (args.len != 1) return error.WrongNumberOfArguments;
    return eval.Value{ .boolean = args[0] == .function or args[0] == .native_fn };
}
