const std = @import("std");
const eval = @import("eval.zig");

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
                const env1 = try eval.matchPattern(arena, func.param, accumulator, func.env);
                const intermediate = try eval.evaluateExpression(arena, func.body, env1, null, &ctx);

                // The result should be a function, apply second argument (element)
                const func2 = switch (intermediate) {
                    .function => |f| f,
                    else => return error.TypeMismatch,
                };
                const env2 = try eval.matchPattern(arena, func2.param, element, func2.env);
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
        values[i] = field.value;
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
            // Return (#ok, value)
            const result_elements = try arena.alloc(eval.Value, 2);
            result_elements[0] = eval.Value{ .symbol = "#ok" };
            result_elements[1] = field.value;
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
