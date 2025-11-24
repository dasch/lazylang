//! Core evaluation engine for Lazylang.
//!
//! This module contains the tree-walking interpreter that evaluates Lazylang expressions:
//!
//! - Pattern matching and destructuring (matchPattern)
//! - Lazy evaluation with thunk forcing (force)
//! - Expression evaluation (evaluateExpression)
//! - Array and object comprehensions
//! - Module importing and loading (importModule, createStdlibEnvironment)
//! - Object merging and field access
//!
//! The evaluator uses an Environment chain for lexical scoping and supports:
//! - Pure functional semantics
//! - Recursive definitions through thunks
//! - First-class functions with closures
//! - Dynamic typing with runtime type checking

const std = @import("std");
const ast = @import("ast.zig");
const value_mod = @import("value.zig");
const error_reporter = @import("error_reporter.zig");
const error_context = @import("error_context.zig");
const value_format = @import("value_format.zig");
const builtin_env = @import("builtin_env.zig");
const parser_mod = @import("parser.zig");
const module_resolver = @import("module_resolver.zig");

// Re-export types from dependencies
pub const Expression = ast.Expression;
pub const Pattern = ast.Pattern;
pub const SourceLocation = ast.SourceLocation;
pub const ArrayComprehension = ast.ArrayComprehension;
pub const ObjectComprehension = ast.ObjectComprehension;
pub const Value = value_mod.Value;
pub const Environment = value_mod.Environment;
pub const EvalError = value_mod.EvalError;
pub const EvalContext = value_mod.EvalContext;
pub const ObjectValue = value_mod.ObjectValue;
pub const ObjectFieldValue = value_mod.ObjectFieldValue;
pub const ArrayValue = value_mod.ArrayValue;
pub const TupleValue = value_mod.TupleValue;
pub const FunctionValue = value_mod.FunctionValue;
pub const Thunk = value_mod.Thunk;
pub const ThunkState = value_mod.ThunkState;
pub const Parser = parser_mod.Parser;

// Import formatting functions
const formatValueShort = value_format.formatValueShort;
const valueToString = value_format.valueToString;

// Value comparison helper (depends on force, so kept here)
fn valuesEqual(arena: std.mem.Allocator, a: Value, b: Value) bool {
    // Force thunks before comparison
    const a_forced = force(arena, a) catch a;
    const b_forced = force(arena, b) catch b;

    return switch (a_forced) {
        .integer => |av| switch (b_forced) {
            .integer => |bv| av == bv,
            else => false,
        },
        .float => |av| switch (b_forced) {
            .float => |bv| av == bv,
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
        .function => false, // Functions are not comparable
        .native_fn => false, // Native functions are not comparable
        .thunk => false, // Should not happen after forcing above
        .array => |av| switch (b_forced) {
            .array => |bv| blk: {
                if (av.elements.len != bv.elements.len) break :blk false;
                for (av.elements, 0..) |elem, i| {
                    if (!valuesEqual(arena, elem, bv.elements[i])) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .tuple => |av| switch (b_forced) {
            .tuple => |bv| blk: {
                if (av.elements.len != bv.elements.len) break :blk false;
                for (av.elements, 0..) |elem, i| {
                    if (!valuesEqual(arena, elem, bv.elements[i])) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |av| switch (b_forced) {
            .object => |bv| blk: {
                if (av.fields.len != bv.fields.len) break :blk false;
                for (av.fields) |afield| {
                    var found = false;
                    for (bv.fields) |bfield| {
                        if (std.mem.eql(u8, afield.key, bfield.key)) {
                            if (!valuesEqual(arena, afield.value, bfield.value)) break :blk false;
                            found = true;
                            break;
                        }
                    }
                    if (!found) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .range => |av| switch (b_forced) {
            .range => |bv| av.start == bv.start and av.end == bv.end and av.inclusive == bv.inclusive,
            else => false,
        },
    };
}

// Helper function to look up a variable in the environment chain
fn lookup(env: ?*Environment, name: []const u8) ?Value {
    var current = env;
    while (current) |scope| {
        if (std.mem.eql(u8, scope.name, name)) {
            return scope.value;
        }
        current = scope.parent;
    }
    return null;
}

pub fn matchPattern(
    arena: std.mem.Allocator,
    pattern: *Pattern,
    value: Value,
    base_env: ?*Environment,
    ctx: *const EvalContext,
) EvalError!?*Environment {
    return switch (pattern.data) {
        .identifier => |name| blk: {
            const new_env = try arena.create(Environment);
            new_env.* = .{
                .parent = base_env,
                .name = name,
                .value = value,
            };
            break :blk new_env;
        },
        .integer => |expected| blk: {
            const actual = switch (value) {
                .integer => |v| v,
                else => {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        const pattern_str = formatPatternValue(std.heap.page_allocator, pattern) catch "integer";
                        const value_str = formatValueShort(std.heap.page_allocator, value) catch getValueTypeName(value);
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = pattern_str,
                            .found = value_str,
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                },
            };
            if (expected != actual) {
                if (ctx.error_ctx) |err_ctx| {
                    err_ctx.setErrorLocation(
                        pattern.location.line,
                        pattern.location.column,
                        pattern.location.offset,
                        pattern.location.length,
                    );
                    const pattern_str = formatPatternValue(std.heap.page_allocator, pattern) catch "value";
                    const value_str = formatValueShort(std.heap.page_allocator, value) catch "value";
                    err_ctx.setErrorData(.{ .type_mismatch = .{
                        .expected = pattern_str,
                        .found = value_str,
                        .operation = "destructuring",
                    } });
                }
                return error.TypeMismatch;
            }
            break :blk base_env;
        },
        .float => |expected| blk: {
            const actual = switch (value) {
                .float => |v| v,
                else => {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = getPatternTypeName(pattern),
                            .found = getValueTypeName(value),
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                },
            };
            if (expected != actual) {
                if (ctx.error_ctx) |err_ctx| {
                    err_ctx.setErrorLocation(
                        pattern.location.line,
                        pattern.location.column,
                        pattern.location.offset,
                        pattern.location.length,
                    );
                    const pattern_str = formatPatternValue(std.heap.page_allocator, pattern) catch "value";
                    const value_str = formatValueShort(std.heap.page_allocator, value) catch "value";
                    err_ctx.setErrorData(.{ .type_mismatch = .{
                        .expected = pattern_str,
                        .found = value_str,
                        .operation = "destructuring",
                    } });
                }
                return error.TypeMismatch;
            }
            break :blk base_env;
        },
        .boolean => |expected| blk: {
            const actual = switch (value) {
                .boolean => |v| v,
                else => {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = getPatternTypeName(pattern),
                            .found = getValueTypeName(value),
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                },
            };
            if (expected != actual) {
                if (ctx.error_ctx) |err_ctx| {
                    err_ctx.setErrorLocation(
                        pattern.location.line,
                        pattern.location.column,
                        pattern.location.offset,
                        pattern.location.length,
                    );
                    const pattern_str = formatPatternValue(std.heap.page_allocator, pattern) catch "value";
                    const value_str = formatValueShort(std.heap.page_allocator, value) catch "value";
                    err_ctx.setErrorData(.{ .type_mismatch = .{
                        .expected = pattern_str,
                        .found = value_str,
                        .operation = "destructuring",
                    } });
                }
                return error.TypeMismatch;
            }
            break :blk base_env;
        },
        .null_literal => blk: {
            switch (value) {
                .null_value => {},
                else => {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = "null",
                            .found = getValueTypeName(value),
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                },
            }
            break :blk base_env;
        },
        .string_literal => |expected| blk: {
            const actual = switch (value) {
                .string => |v| v,
                else => {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = "string",
                            .found = getValueTypeName(value),
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                },
            };
            if (!std.mem.eql(u8, expected, actual)) {
                if (ctx.error_ctx) |err_ctx| {
                    err_ctx.setErrorLocation(
                        pattern.location.line,
                        pattern.location.column,
                        pattern.location.offset,
                        pattern.location.length,
                    );
                    const pattern_str = formatPatternValue(std.heap.page_allocator, pattern) catch "value";
                    const value_str = formatValueShort(std.heap.page_allocator, value) catch "value";
                    err_ctx.setErrorData(.{ .type_mismatch = .{
                        .expected = pattern_str,
                        .found = value_str,
                        .operation = "destructuring",
                    } });
                }
                return error.TypeMismatch;
            }
            break :blk base_env;
        },
        .symbol => |expected| blk: {
            const actual = switch (value) {
                .symbol => |v| v,
                else => {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = "symbol",
                            .found = getValueTypeName(value),
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                },
            };
            if (!std.mem.eql(u8, expected, actual)) {
                if (ctx.error_ctx) |err_ctx| {
                    err_ctx.setErrorLocation(
                        pattern.location.line,
                        pattern.location.column,
                        pattern.location.offset,
                        pattern.location.length,
                    );
                    const pattern_str = formatPatternValue(std.heap.page_allocator, pattern) catch "value";
                    const value_str = formatValueShort(std.heap.page_allocator, value) catch "value";
                    err_ctx.setErrorData(.{ .type_mismatch = .{
                        .expected = pattern_str,
                        .found = value_str,
                        .operation = "destructuring",
                    } });
                }
                return error.TypeMismatch;
            }
            break :blk base_env;
        },
        .tuple => |tuple_pattern| blk: {
            const tuple_value = switch (value) {
                .tuple => |t| t,
                else => {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = "tuple",
                            .found = getValueTypeName(value),
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                },
            };

            if (tuple_pattern.elements.len != tuple_value.elements.len) {
                if (ctx.error_ctx) |err_ctx| {
                    err_ctx.setErrorLocation(
                        pattern.location.line,
                        pattern.location.column,
                        pattern.location.offset,
                        pattern.location.length,
                    );
                    const pattern_str = formatPatternValue(std.heap.page_allocator, pattern) catch "tuple";
                    const value_str = formatValueShort(std.heap.page_allocator, value) catch "tuple";
                    err_ctx.setErrorData(.{ .type_mismatch = .{
                        .expected = pattern_str,
                        .found = value_str,
                        .operation = "destructuring",
                    } });
                }
                return error.TypeMismatch;
            }

            var current_env = base_env;
            for (tuple_pattern.elements, 0..) |elem_pattern, i| {
                current_env = try matchPattern(arena, elem_pattern, tuple_value.elements[i], current_env, ctx);
            }
            break :blk current_env;
        },
        .array => |array_pattern| blk: {
            const array_value = switch (value) {
                .array => |a| a,
                else => {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = "array",
                            .found = getValueTypeName(value),
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                },
            };

            // If there's no rest pattern, lengths must match exactly
            if (array_pattern.rest == null) {
                if (array_pattern.elements.len != array_value.elements.len) {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        const pattern_str = formatPatternValue(std.heap.page_allocator, pattern) catch "array";
                        const value_str = formatValueShort(std.heap.page_allocator, value) catch "array";
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = pattern_str,
                            .found = value_str,
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                }
            } else {
                // With rest pattern, array must have at least as many elements as fixed patterns
                if (array_value.elements.len < array_pattern.elements.len) {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        const pattern_str = formatPatternValue(std.heap.page_allocator, pattern) catch "array";
                        const value_str = formatValueShort(std.heap.page_allocator, value) catch "array";
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = pattern_str,
                            .found = value_str,
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                }
            }

            var current_env = base_env;

            // Match fixed elements
            for (array_pattern.elements, 0..) |elem_pattern, i| {
                current_env = try matchPattern(arena, elem_pattern, array_value.elements[i], current_env, ctx);
            }

            // If there's a rest pattern, bind remaining elements to it
            if (array_pattern.rest) |rest_name| {
                const remaining_count = array_value.elements.len - array_pattern.elements.len;
                const remaining_elements = try arena.alloc(Value, remaining_count);
                for (0..remaining_count) |i| {
                    remaining_elements[i] = array_value.elements[array_pattern.elements.len + i];
                }
                const rest_array = Value{ .array = .{ .elements = remaining_elements } };
                const new_env = try arena.create(Environment);
                new_env.* = .{
                    .parent = current_env,
                    .name = rest_name,
                    .value = rest_array,
                };
                current_env = new_env;
            }

            break :blk current_env;
        },
        .object => |object_pattern| blk: {
            const object_value = switch (value) {
                .object => |o| o,
                else => {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = "object",
                            .found = getValueTypeName(value),
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                },
            };

            var current_env = base_env;
            for (object_pattern.fields) |pattern_field| {
                // Find the field in the object value
                var found = false;
                for (object_value.fields) |value_field| {
                    if (std.mem.eql(u8, value_field.key, pattern_field.key)) {
                        // Force the field value if it's a thunk, then match the pattern
                        const forced_value = try force(arena, value_field.value);
                        current_env = try matchPattern(arena, pattern_field.pattern, forced_value, current_env, ctx);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(
                            pattern.location.line,
                            pattern.location.column,
                            pattern.location.offset,
                            pattern.location.length,
                        );
                        // List available fields
                        var available_fields = std.ArrayList([]const u8){};
                        defer available_fields.deinit(std.heap.page_allocator);
                        for (object_value.fields) |field| {
                            available_fields.append(std.heap.page_allocator, field.key) catch {};
                        }

                        const pattern_str = std.fmt.allocPrint(std.heap.page_allocator, "object with field '{s}'", .{pattern_field.key}) catch "object";
                        const value_str = if (object_value.fields.len == 0)
                            std.fmt.allocPrint(std.heap.page_allocator, "object with no fields", .{}) catch "object"
                        else blk2: {
                            var fields_str = std.ArrayList(u8){};
                            defer fields_str.deinit(std.heap.page_allocator);
                            fields_str.appendSlice(std.heap.page_allocator, "object with fields: {") catch break :blk2 "object";
                            for (object_value.fields, 0..) |field, i| {
                                if (i > 0) fields_str.appendSlice(std.heap.page_allocator, ", ") catch break :blk2 "object";
                                fields_str.appendSlice(std.heap.page_allocator, field.key) catch break :blk2 "object";
                            }
                            fields_str.append(std.heap.page_allocator, '}') catch break :blk2 "object";
                            break :blk2 fields_str.toOwnedSlice(std.heap.page_allocator) catch "object";
                        };
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = pattern_str,
                            .found = value_str,
                            .operation = "destructuring",
                        } });
                    }
                    return error.TypeMismatch;
                }
            }
            break :blk current_env;
        },
    };
}

// Helper for error reporting
fn setPatternMatchError(arena: std.mem.Allocator, pattern_str: []const u8, value_str: []const u8) !void {
    _ = arena;
    _ = pattern_str;
    _ = value_str;
    // This is a placeholder for now - we're using setErrorData instead
}

fn findObjectField(obj: ObjectValue, key: []const u8) ?Value {
    for (obj.fields) |field| {
        if (std.mem.eql(u8, field.key, key)) {
            return field.value;
        }
    }
    return null;
}

fn mergeObjects(arena: std.mem.Allocator, base: ObjectValue, extension: ObjectValue) EvalError!Value {
    // Create a map to track which keys we've seen
    var result_fields = std.ArrayListUnmanaged(ObjectFieldValue){};

    // First, add all fields from base
    for (base.fields) |base_field| {
        // Check if this field is overridden in extension
        var found_override = false;
        for (extension.fields) |ext_field| {
            if (std.mem.eql(u8, base_field.key, ext_field.key)) {
                found_override = true;
                // Check if we should deep merge or replace
                if (ext_field.is_patch) {
                    // Deep merge: both values should be objects
                    const base_forced = try force(arena, base_field.value);
                    const ext_forced = try force(arena, ext_field.value);
                    if (base_forced == .object and ext_forced == .object) {
                        const merged = try mergeObjects(arena, base_forced.object, ext_forced.object);
                        const key_copy = try arena.dupe(u8, ext_field.key);
                        try result_fields.append(arena, .{ .key = key_copy, .value = merged, .is_patch = false });
                    } else {
                        // Not both objects, just use extension value
                        const key_copy = try arena.dupe(u8, ext_field.key);
                        try result_fields.append(arena, .{ .key = key_copy, .value = ext_field.value, .is_patch = ext_field.is_patch });
                    }
                } else {
                    // Shallow replace: use the extension value
                    const key_copy = try arena.dupe(u8, ext_field.key);
                    try result_fields.append(arena, .{ .key = key_copy, .value = ext_field.value, .is_patch = ext_field.is_patch });
                }
                break;
            }
        }
        if (!found_override) {
            // No override, keep the base field
            const key_copy = try arena.dupe(u8, base_field.key);
            try result_fields.append(arena, .{ .key = key_copy, .value = base_field.value, .is_patch = base_field.is_patch });
        }
    }

    // Then, add fields from extension that are not in base
    for (extension.fields) |ext_field| {
        var found_in_base = false;
        for (base.fields) |base_field| {
            if (std.mem.eql(u8, base_field.key, ext_field.key)) {
                found_in_base = true;
                break;
            }
        }
        if (!found_in_base) {
            const key_copy = try arena.dupe(u8, ext_field.key);
            try result_fields.append(arena, .{ .key = key_copy, .value = ext_field.value, .is_patch = ext_field.is_patch });
        }
    }

    // Prefer extension's module_doc if it exists, otherwise use base's
    const module_doc = extension.module_doc orelse base.module_doc;
    return Value{ .object = .{ .fields = try result_fields.toOwnedSlice(arena), .module_doc = module_doc, .name = null } };
}

/// Find field access locations in an expression for a given field name
fn findFieldAccessInExpression(expr: *Expression, field_name: []const u8) ?error_reporter.SourceLocation {
    return switch (expr.data) {
        .field_access => |fa| {
            // Check if this field access matches the field name we're looking for
            if (std.mem.eql(u8, fa.field, field_name)) {
                return fa.field_location;
            }
            // Recursively search in the object expression
            return findFieldAccessInExpression(fa.object, field_name);
        },
        .binary => |bin| {
            // Search in both operands
            if (findFieldAccessInExpression(bin.left, field_name)) |loc| return loc;
            if (findFieldAccessInExpression(bin.right, field_name)) |loc| return loc;
            return null;
        },
        .unary => |un| {
            return findFieldAccessInExpression(un.operand, field_name);
        },
        .application => |app| {
            if (findFieldAccessInExpression(app.function, field_name)) |loc| return loc;
            if (findFieldAccessInExpression(app.argument, field_name)) |loc| return loc;
            return null;
        },
        .if_expr => |if_expr| {
            if (findFieldAccessInExpression(if_expr.condition, field_name)) |loc| return loc;
            if (findFieldAccessInExpression(if_expr.then_expr, field_name)) |loc| return loc;
            if (if_expr.else_expr) |else_expr| {
                if (findFieldAccessInExpression(else_expr, field_name)) |loc| return loc;
            }
            return null;
        },
        .let => |let_expr| {
            if (findFieldAccessInExpression(let_expr.value, field_name)) |loc| return loc;
            if (findFieldAccessInExpression(let_expr.body, field_name)) |loc| return loc;
            return null;
        },
        .array => |arr| {
            for (arr.elements) |elem| {
                const elem_expr = switch (elem) {
                    .normal => |e| e,
                    .spread => |e| e,
                    .conditional_if => |c| c.expr,
                    .conditional_unless => |c| c.expr,
                };
                if (findFieldAccessInExpression(elem_expr, field_name)) |loc| return loc;
            }
            return null;
        },
        .tuple => |tup| {
            for (tup.elements) |elem| {
                if (findFieldAccessInExpression(elem, field_name)) |loc| return loc;
            }
            return null;
        },
        else => null,
    };
}

/// Force evaluation of a thunk if needed
pub fn force(arena: std.mem.Allocator, value: Value) EvalError!Value {
    return switch (value) {
        .thunk => |thunk| {
            switch (thunk.state) {
                .evaluated => |v| return v,
                .evaluating => {
                    // Set error location to highlight the cyclic field definition and reference
                    if (thunk.ctx.error_ctx) |err_ctx| {
                        if (thunk.field_key_location) |key_loc| {
                            // For object fields, try to find the field access that's causing the cycle
                            // We need to extract the field name from the key location
                            // Since we don't have the field name directly, we'll search for any field access in the expression

                            // Try to find a field access in the expression that could be causing the cycle
                            // We look for the first field access we find
                            const field_access_loc = findFirstFieldAccess(thunk.expr);

                            if (field_access_loc) |access_loc| {
                                // Recalculate the line number from the offset to fix any tokenizer issues
                                // Get the source from the error context
                                const source = err_ctx.source_map.get(err_ctx.current_file) orelse err_ctx.source;
                                const corrected_loc = error_reporter.offsetToLocation(source, access_loc.offset);

                                // Use the corrected location with the original length
                                const final_access_loc = error_reporter.SourceLocation{
                                    .line = corrected_loc.line,
                                    .column = corrected_loc.column,
                                    .offset = access_loc.offset,
                                    .length = access_loc.length,
                                };

                                // We found a field access - report both locations
                                err_ctx.setErrorLocationWithLabels(
                                    key_loc.line,
                                    key_loc.column,
                                    key_loc.offset,
                                    1, // Just the identifier character
                                    "field defined here",
                                    final_access_loc.line,
                                    final_access_loc.column,
                                    final_access_loc.offset,
                                    1, // Just the identifier character
                                    "cyclic reference here",
                                );
                            } else {
                                // Fallback: just use the field key location
                                err_ctx.setErrorLocation(key_loc.line, key_loc.column, key_loc.offset, 1);
                            }
                        } else {
                            // Not an object field, just use the expression location
                            err_ctx.setErrorLocation(thunk.expr.location.line, thunk.expr.location.column, thunk.expr.location.offset, thunk.expr.location.length);
                        }
                    }
                    return error.CyclicReference;
                },
                .unevaluated => {
                    thunk.state = .evaluating;
                    const result = try evaluateExpression(arena, thunk.expr, thunk.env, thunk.current_dir, thunk.ctx);
                    thunk.state = .{ .evaluated = result };
                    return result;
                },
            }
        },
        else => value,
    };
}

/// Find the first field access in an expression (used for cyclic reference detection)
fn findFirstFieldAccess(expr: *Expression) ?error_reporter.SourceLocation {
    return switch (expr.data) {
        .field_access => |fa| fa.field_location,
        .binary => |bin| {
            if (findFirstFieldAccess(bin.left)) |loc| return loc;
            if (findFirstFieldAccess(bin.right)) |loc| return loc;
            return null;
        },
        .unary => |un| findFirstFieldAccess(un.operand),
        .application => |app| {
            if (findFirstFieldAccess(app.function)) |loc| return loc;
            if (findFirstFieldAccess(app.argument)) |loc| return loc;
            return null;
        },
        .if_expr => |if_expr| {
            if (findFirstFieldAccess(if_expr.condition)) |loc| return loc;
            if (findFirstFieldAccess(if_expr.then_expr)) |loc| return loc;
            if (if_expr.else_expr) |else_expr| {
                if (findFirstFieldAccess(else_expr)) |loc| return loc;
            }
            return null;
        },
        .let => |let_expr| {
            if (findFirstFieldAccess(let_expr.value)) |loc| return loc;
            if (findFirstFieldAccess(let_expr.body)) |loc| return loc;
            return null;
        },
        .array => |arr| {
            for (arr.elements) |elem| {
                const elem_expr = switch (elem) {
                    .normal => |e| e,
                    .spread => |e| e,
                    .conditional_if => |c| c.expr,
                    .conditional_unless => |c| c.expr,
                };
                if (findFirstFieldAccess(elem_expr)) |loc| return loc;
            }
            return null;
        },
        .tuple => |tup| {
            for (tup.elements) |elem| {
                if (findFirstFieldAccess(elem)) |loc| return loc;
            }
            return null;
        },
        else => null,
    };
}

pub fn evaluateExpression(
    arena: std.mem.Allocator,
    expr: *Expression,
    env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!Value {
    return switch (expr.data) {
        .integer => |value| .{ .integer = value },
        .float => |value| .{ .float = value },
        .boolean => |value| .{ .boolean = value },
        .null_literal => .null_value,
        .symbol => |value| .{ .symbol = try arena.dupe(u8, value) },
        .identifier => |name| blk: {
            const resolved = lookup(env, name) orelse {
                // Set error location and data for unknown identifier
                if (ctx.error_ctx) |err_ctx| {
                    err_ctx.setErrorLocation(expr.location.line, expr.location.column, expr.location.offset, expr.location.length);

                    // Copy the identifier name using error context's allocator
                    const name_copy = try err_ctx.allocator.dupe(u8, name);
                    err_ctx.setErrorData(.{
                        .unknown_identifier = .{ .name = name_copy },
                    });
                }
                return error.UnknownIdentifier;
            };
            // Automatically force thunks when looking up identifiers
            break :blk try force(arena, resolved);
        },
        .string_literal => |value| .{ .string = try arena.dupe(u8, value) },
        .string_interpolation => |interp| blk: {
            var result = std.ArrayListUnmanaged(u8){};
            for (interp.parts) |part| {
                switch (part) {
                    .literal => |lit| {
                        try result.appendSlice(arena, lit);
                    },
                    .interpolation => |interp_expr| {
                        const interp_value = try evaluateExpression(arena, interp_expr, env, current_dir, ctx);
                        const str_value = try valueToString(arena, interp_value);
                        try result.appendSlice(arena, str_value);
                    },
                }
            }
            break :blk .{ .string = try result.toOwnedSlice(arena) };
        },
        .lambda => |lambda| blk: {
            const function = try arena.create(FunctionValue);
            function.* = .{ .param = lambda.param, .body = lambda.body, .env = env, .docstring = null, .name = null };
            break :blk Value{ .function = function };
        },
        .let => |let_expr| blk: {
            // For recursive definitions, if the pattern is a simple identifier,
            // we create the environment binding before evaluating the value
            const is_recursive = switch (let_expr.pattern.data) {
                .identifier => true,
                else => false,
            };

            if (is_recursive) {
                const identifier = let_expr.pattern.data.identifier;
                // Create environment entry with placeholder value
                const recursive_env = try arena.create(Environment);
                recursive_env.* = .{
                    .parent = env,
                    .name = identifier,
                    .value = .null_value, // Placeholder
                };

                // Evaluate value with recursive environment
                // Special handling for lambdas with docstrings
                const value = if (let_expr.doc != null and let_expr.value.data == .lambda) blk2: {
                    const lambda = let_expr.value.data.lambda;
                    const function = try arena.create(FunctionValue);
                    function.* = .{
                        .param = lambda.param,
                        .body = lambda.body,
                        .env = recursive_env,
                        .docstring = let_expr.doc,
                        .name = null,
                    };
                    break :blk2 Value{ .function = function };
                } else try evaluateExpression(arena, let_expr.value, recursive_env, current_dir, ctx);

                // Update the environment entry with the actual value
                recursive_env.value = value;

                // Evaluate body with the recursive environment
                break :blk try evaluateExpression(arena, let_expr.body, recursive_env, current_dir, ctx);
            } else {
                // Non-recursive case: evaluate value first, then pattern match
                // Special handling for lambdas with docstrings
                const value = if (let_expr.doc != null and let_expr.value.data == .lambda) blk2: {
                    const lambda = let_expr.value.data.lambda;
                    const function = try arena.create(FunctionValue);
                    function.* = .{
                        .param = lambda.param,
                        .body = lambda.body,
                        .env = env,
                        .docstring = let_expr.doc,
                        .name = null,
                    };
                    break :blk2 Value{ .function = function };
                } else try evaluateExpression(arena, let_expr.value, env, current_dir, ctx);

                const new_env = try matchPattern(arena, let_expr.pattern, value, env, ctx);
                break :blk try evaluateExpression(arena, let_expr.body, new_env, current_dir, ctx);
            }
        },
        .where_expr => |where_expr| blk: {
            // For where clauses, all bindings should be mutually recursive
            // Strategy:
            // 1. For identifier patterns: wrap in thunks for lazy mutual recursion
            // 2. For complex patterns: evaluate eagerly and pattern match
            //
            // This hybrid approach allows both mutual recursion (for identifiers)
            // and complex destructuring (for objects, tuples, arrays)

            var current_env = env;
            const thunks = try arena.alloc(?*Thunk, where_expr.bindings.len);

            // First pass: create thunks for identifier patterns, null for others
            for (where_expr.bindings, 0..) |binding, i| {
                switch (binding.pattern.data) {
                    .identifier => |name| {
                        // Create thunk for lazy evaluation
                        const thunk = try arena.create(Thunk);
                        thunk.* = .{
                            .expr = binding.value,
                            .env = undefined, // Will be set after full env is built
                            .current_dir = current_dir,
                            .ctx = ctx,
                            .state = .unevaluated,
                            .field_key_location = null, // Not an object field
                        };
                        thunks[i] = thunk;

                        // Create environment entry with thunk as value
                        const new_env = try arena.create(Environment);
                        new_env.* = .{
                            .parent = current_env,
                            .name = name,
                            .value = .{ .thunk = thunk },
                        };
                        current_env = new_env;
                    },
                    else => {
                        // Mark as non-thunk (will be evaluated eagerly)
                        thunks[i] = null;
                    },
                }
            }

            // Second pass: update all thunks with the full environment
            for (thunks) |maybe_thunk| {
                if (maybe_thunk) |thunk| {
                    thunk.env = current_env;
                }
            }

            // Third pass: evaluate and pattern match complex patterns
            for (where_expr.bindings, 0..) |binding, i| {
                if (thunks[i] == null) {
                    // This is a complex pattern - evaluate value and pattern match
                    const value = try evaluateExpression(arena, binding.value, current_env, current_dir, ctx);
                    const new_env = try matchPattern(arena, binding.pattern, value, current_env, ctx) orelse {
                        return error.TypeMismatch;
                    };
                    current_env = new_env;
                }
            }

            // Finally, evaluate the main expression with the full environment
            break :blk try evaluateExpression(arena, where_expr.expr, current_env, current_dir, ctx);
        },
        .unary => |unary| blk: {
            const operand_value = try evaluateExpression(arena, unary.operand, env, current_dir, ctx);
            const result = switch (unary.op) {
                .logical_not => blk2: {
                    const bool_val = switch (operand_value) {
                        .boolean => |v| v,
                        else => return error.TypeMismatch,
                    };
                    break :blk2 Value{ .boolean = !bool_val };
                },
            };
            break :blk result;
        },
        .binary => |binary| blk: {
            const left_value = try evaluateExpression(arena, binary.left, env, current_dir, ctx);
            const right_value = try evaluateExpression(arena, binary.right, env, current_dir, ctx);

            const result = switch (binary.op) {
                .add, .subtract, .multiply, .divide => blk2: {
                    // Check if either operand is a float
                    const is_float_op = (left_value == .float or right_value == .float);

                    if (is_float_op) {
                        // At least one operand is float, promote to float arithmetic
                        const left_float = switch (left_value) {
                            .integer => |v| @as(f64, @floatFromInt(v)),
                            .float => |v| v,
                            else => {
                                if (ctx.error_ctx) |err_ctx| {
                                    const op_name = switch (binary.op) {
                                        .add => "addition",
                                        .subtract => "subtraction",
                                        .multiply => "multiplication",
                                        .divide => "division",
                                        else => unreachable,
                                    };
                                    err_ctx.setErrorLocation(binary.left.location.line, binary.left.location.column, binary.left.location.offset, binary.left.location.length);
                                    err_ctx.setErrorData(.{ .type_mismatch = .{
                                        .expected = "number (integer or float)",
                                        .found = getValueTypeName(left_value),
                                        .operation = op_name,
                                    } });
                                }
                                return error.TypeMismatch;
                            },
                        };
                        const right_float = switch (right_value) {
                            .integer => |v| @as(f64, @floatFromInt(v)),
                            .float => |v| v,
                            else => {
                                if (ctx.error_ctx) |err_ctx| {
                                    const op_name = switch (binary.op) {
                                        .add => "addition",
                                        .subtract => "subtraction",
                                        .multiply => "multiplication",
                                        .divide => "division",
                                        else => unreachable,
                                    };
                                    err_ctx.setErrorLocation(binary.right.location.line, binary.right.location.column, binary.right.location.offset, binary.right.location.length);
                                    err_ctx.setErrorData(.{ .type_mismatch = .{
                                        .expected = "number (integer or float)",
                                        .found = getValueTypeName(right_value),
                                        .operation = op_name,
                                    } });
                                }
                                return error.TypeMismatch;
                            },
                        };

                        const float_result = switch (binary.op) {
                            .add => left_float + right_float,
                            .subtract => left_float - right_float,
                            .multiply => left_float * right_float,
                            .divide => blk3: {
                                if (right_float == 0.0) {
                                    if (ctx.error_ctx) |err_ctx| {
                                        // Point to the divisor (right operand)
                                        err_ctx.setErrorLocation(binary.right.location.line, binary.right.location.column, binary.right.location.offset, binary.right.location.length);
                                    }
                                    return error.DivisionByZero;
                                }
                                break :blk3 left_float / right_float;
                            },
                            else => unreachable,
                        };
                        break :blk2 Value{ .float = float_result };
                    } else {
                        // Both operands are integers
                        const left_int = switch (left_value) {
                            .integer => |v| v,
                            else => {
                                if (ctx.error_ctx) |err_ctx| {
                                    const op_name = switch (binary.op) {
                                        .add => "addition",
                                        .subtract => "subtraction",
                                        .multiply => "multiplication",
                                        .divide => "division",
                                        else => unreachable,
                                    };
                                    err_ctx.setErrorLocation(binary.left.location.line, binary.left.location.column, binary.left.location.offset, binary.left.location.length);
                                    err_ctx.setErrorData(.{ .type_mismatch = .{
                                        .expected = "integer",
                                        .found = getValueTypeName(left_value),
                                        .operation = op_name,
                                    } });
                                }
                                return error.TypeMismatch;
                            },
                        };
                        const right_int = switch (right_value) {
                            .integer => |v| v,
                            else => {
                                if (ctx.error_ctx) |err_ctx| {
                                    const op_name = switch (binary.op) {
                                        .add => "addition",
                                        .subtract => "subtraction",
                                        .multiply => "multiplication",
                                        .divide => "division",
                                        else => unreachable,
                                    };
                                    err_ctx.setErrorLocation(binary.right.location.line, binary.right.location.column, binary.right.location.offset, binary.right.location.length);
                                    err_ctx.setErrorData(.{ .type_mismatch = .{
                                        .expected = "integer",
                                        .found = getValueTypeName(right_value),
                                        .operation = op_name,
                                    } });
                                }
                                return error.TypeMismatch;
                            },
                        };

                        const int_result = switch (binary.op) {
                            .add => try std.math.add(i64, left_int, right_int),
                            .subtract => try std.math.sub(i64, left_int, right_int),
                            .multiply => try std.math.mul(i64, left_int, right_int),
                            .divide => blk4: {
                                if (right_int == 0) {
                                    if (ctx.error_ctx) |err_ctx| {
                                        // Point to the divisor (right operand)
                                        err_ctx.setErrorLocation(binary.right.location.line, binary.right.location.column, binary.right.location.offset, binary.right.location.length);
                                    }
                                    return error.DivisionByZero;
                                }
                                break :blk4 @divTrunc(left_int, right_int);
                            },
                            else => unreachable,
                        };
                        break :blk2 Value{ .integer = int_result };
                    }
                },
                .logical_and => blk2: {
                    const left_bool = switch (left_value) {
                        .boolean => |v| v,
                        else => return error.TypeMismatch,
                    };
                    const right_bool = switch (right_value) {
                        .boolean => |v| v,
                        else => return error.TypeMismatch,
                    };
                    break :blk2 Value{ .boolean = left_bool and right_bool };
                },
                .logical_or => blk2: {
                    const left_bool = switch (left_value) {
                        .boolean => |v| v,
                        else => return error.TypeMismatch,
                    };
                    const right_bool = switch (right_value) {
                        .boolean => |v| v,
                        else => return error.TypeMismatch,
                    };
                    break :blk2 Value{ .boolean = left_bool or right_bool };
                },
                .equal, .not_equal => blk2: {
                    const bool_result = switch (binary.op) {
                        .equal => valuesEqual(arena, left_value, right_value),
                        .not_equal => !valuesEqual(arena, left_value, right_value),
                        else => unreachable,
                    };
                    break :blk2 Value{ .boolean = bool_result };
                },
                .less_than, .greater_than, .less_or_equal, .greater_or_equal => blk2: {
                    // Check if either operand is a float
                    const is_float_op = (left_value == .float or right_value == .float);

                    const bool_result = if (is_float_op) blk3: {
                        // At least one operand is float, promote to float comparison
                        const left_float = switch (left_value) {
                            .integer => |v| @as(f64, @floatFromInt(v)),
                            .float => |v| v,
                            else => {
                                if (ctx.error_ctx) |err_ctx| {
                                    const op_name = switch (binary.op) {
                                        .less_than => "comparison (<)",
                                        .greater_than => "comparison (>)",
                                        .less_or_equal => "comparison (<=)",
                                        .greater_or_equal => "comparison (>=)",
                                        else => unreachable,
                                    };
                                    err_ctx.setErrorData(.{ .type_mismatch = .{
                                        .expected = "number (integer or float)",
                                        .found = getValueTypeName(left_value),
                                        .operation = op_name,
                                    } });
                                }
                                return error.TypeMismatch;
                            },
                        };
                        const right_float = switch (right_value) {
                            .integer => |v| @as(f64, @floatFromInt(v)),
                            .float => |v| v,
                            else => {
                                if (ctx.error_ctx) |err_ctx| {
                                    const op_name = switch (binary.op) {
                                        .less_than => "comparison (<)",
                                        .greater_than => "comparison (>)",
                                        .less_or_equal => "comparison (<=)",
                                        .greater_or_equal => "comparison (>=)",
                                        else => unreachable,
                                    };
                                    err_ctx.setErrorData(.{ .type_mismatch = .{
                                        .expected = "number (integer or float)",
                                        .found = getValueTypeName(right_value),
                                        .operation = op_name,
                                    } });
                                }
                                return error.TypeMismatch;
                            },
                        };

                        break :blk3 switch (binary.op) {
                            .less_than => left_float < right_float,
                            .greater_than => left_float > right_float,
                            .less_or_equal => left_float <= right_float,
                            .greater_or_equal => left_float >= right_float,
                            else => unreachable,
                        };
                    } else blk3: {
                        // Both operands are integers
                        const left_int = switch (left_value) {
                            .integer => |v| v,
                            else => {
                                if (ctx.error_ctx) |err_ctx| {
                                    const op_name = switch (binary.op) {
                                        .less_than => "comparison (<)",
                                        .greater_than => "comparison (>)",
                                        .less_or_equal => "comparison (<=)",
                                        .greater_or_equal => "comparison (>=)",
                                        else => unreachable,
                                    };
                                    err_ctx.setErrorData(.{ .type_mismatch = .{
                                        .expected = "integer",
                                        .found = getValueTypeName(left_value),
                                        .operation = op_name,
                                    } });
                                }
                                return error.TypeMismatch;
                            },
                        };
                        const right_int = switch (right_value) {
                            .integer => |v| v,
                            else => {
                                if (ctx.error_ctx) |err_ctx| {
                                    const op_name = switch (binary.op) {
                                        .less_than => "comparison (<)",
                                        .greater_than => "comparison (>)",
                                        .less_or_equal => "comparison (<=)",
                                        .greater_or_equal => "comparison (>=)",
                                        else => unreachable,
                                    };
                                    err_ctx.setErrorData(.{ .type_mismatch = .{
                                        .expected = "integer",
                                        .found = getValueTypeName(right_value),
                                        .operation = op_name,
                                    } });
                                }
                                return error.TypeMismatch;
                            },
                        };

                        break :blk3 switch (binary.op) {
                            .less_than => left_int < right_int,
                            .greater_than => left_int > right_int,
                            .less_or_equal => left_int <= right_int,
                            .greater_or_equal => left_int >= right_int,
                            else => unreachable,
                        };
                    };
                    break :blk2 Value{ .boolean = bool_result };
                },
                .pipeline => blk2: {
                    // Pipeline operator: x \ f evaluates to f(x)
                    // The left side is the value, the right side is the function
                    switch (right_value) {
                        .function => |function_ptr| {
                            const bound_env = matchPattern(arena, function_ptr.param, left_value, function_ptr.env, ctx) catch |err| {
                                if (ctx.error_ctx) |err_ctx| {
                                    err_ctx.captureStackTrace() catch {};
                                }
                                return err;
                            };

                            // Push stack frame for pipeline function call
                            const function_name = switch (binary.right.data) {
                                .identifier => |name| name,
                                else => null,
                            };

                            if (ctx.error_ctx) |err_ctx| {
                                err_ctx.pushStackFrame(
                                    function_name,
                                    err_ctx.current_file,
                                    binary.right.location.line,
                                    binary.right.location.column,
                                    binary.right.location.offset,
                                    binary.right.location.length,
                                    false,
                                ) catch {};
                            }

                            const result = evaluateExpression(arena, function_ptr.body, bound_env, current_dir, ctx) catch |err| {
                                if (ctx.error_ctx) |err_ctx| {
                                    if (err_ctx.stack_trace == null) {
                                        err_ctx.captureStackTrace() catch {};
                                    }
                                }
                                if (ctx.error_ctx) |err_ctx| {
                                    err_ctx.popStackFrame();
                                }
                                return err;
                            };

                            if (ctx.error_ctx) |err_ctx| {
                                err_ctx.popStackFrame();
                            }

                            break :blk2 result;
                        },
                        .native_fn => |native_fn| {
                            // Push stack frame for native function call
                            const function_name = switch (binary.right.data) {
                                .identifier => |name| name,
                                else => null,
                            };

                            if (ctx.error_ctx) |err_ctx| {
                                err_ctx.pushStackFrame(
                                    function_name,
                                    err_ctx.current_file,
                                    binary.right.location.line,
                                    binary.right.location.column,
                                    binary.right.location.offset,
                                    binary.right.location.length,
                                    true,
                                ) catch {};
                            }

                            const args = [_]Value{left_value};
                            const result = native_fn(arena, &args) catch |err| {
                                if (ctx.error_ctx) |err_ctx| {
                                    if (err_ctx.stack_trace == null) {
                                        err_ctx.captureStackTrace() catch {};
                                    }
                                }
                                if (ctx.error_ctx) |err_ctx| {
                                    err_ctx.popStackFrame();
                                }
                                return err;
                            };

                            if (ctx.error_ctx) |err_ctx| {
                                err_ctx.popStackFrame();
                            }

                            break :blk2 result;
                        },
                        else => {
                            // Point to the right operand (function) that isn't actually a function
                            if (ctx.error_ctx) |err_ctx| {
                                err_ctx.setErrorLocation(binary.right.location.line, binary.right.location.column, binary.right.location.offset, binary.right.location.length);
                                err_ctx.captureStackTrace() catch {};
                            }
                            return error.ExpectedFunction;
                        },
                    }
                },
                .merge => blk2: {
                    // Object merge operator: obj1 & obj2
                    const left_obj = switch (left_value) {
                        .object => |o| o,
                        else => return error.TypeMismatch,
                    };
                    const right_obj = switch (right_value) {
                        .object => |o| o,
                        else => return error.TypeMismatch,
                    };

                    // Merge the two objects
                    break :blk2 try mergeObjects(arena, left_obj, right_obj);
                },
            };
            break :blk result;
        },
        .if_expr => |if_expr| blk: {
            const condition_value = try evaluateExpression(arena, if_expr.condition, env, current_dir, ctx);
            const condition_bool = switch (condition_value) {
                .boolean => |v| v,
                else => return error.TypeMismatch,
            };

            if (condition_bool) {
                break :blk try evaluateExpression(arena, if_expr.then_expr, env, current_dir, ctx);
            } else if (if_expr.else_expr) |else_expr| {
                break :blk try evaluateExpression(arena, else_expr, env, current_dir, ctx);
            } else {
                break :blk .null_value;
            }
        },
        .when_matches => |when_matches| blk: {
            const value = try evaluateExpression(arena, when_matches.value, env, current_dir, ctx);

            // Try each pattern branch
            for (when_matches.branches) |branch| {
                // Try to match the pattern
                const match_env = matchPattern(arena, branch.pattern, value, env, ctx) catch |err| {
                    // If pattern doesn't match, try next branch
                    if (err == error.TypeMismatch) continue;
                    return err;
                };

                // Pattern matched, evaluate the expression
                break :blk try evaluateExpression(arena, branch.expression, match_env, current_dir, ctx);
            }

            // No pattern matched, check for otherwise clause
            if (when_matches.otherwise) |otherwise_expr| {
                break :blk try evaluateExpression(arena, otherwise_expr, env, current_dir, ctx);
            }

            // No pattern matched and no otherwise clause - error
            return error.TypeMismatch;
        },
        .application => |application| blk: {
            const function_value = try evaluateExpression(arena, application.function, env, current_dir, ctx);
            const argument_value = try evaluateExpression(arena, application.argument, env, current_dir, ctx);

            switch (function_value) {
                .function => |function_ptr| {
                    const bound_env = matchPattern(arena, function_ptr.param, argument_value, function_ptr.env, ctx) catch |err| {
                        // If pattern matching fails, update error location to point to the argument
                        // at the call site, not the parameter in the function definition
                        if (ctx.error_ctx) |err_ctx| {
                            err_ctx.setErrorLocation(application.argument.location.line, application.argument.location.column, application.argument.location.offset, application.argument.location.length);

                            // If the error is a type mismatch and the function is named, update the operation
                            if (err == error.TypeMismatch) {
                                // Check if function expression is an identifier
                                const function_name = switch (application.function.data) {
                                    .identifier => |name| name,
                                    else => null,
                                };

                                if (function_name) |name| {
                                    // Update the operation field in the error data if it exists
                                    if (err_ctx.last_error_data == .type_mismatch) {
                                        const old_data = err_ctx.last_error_data.type_mismatch;
                                        // Try to allocate new operation string; if it fails, leave error data as-is
                                        if (std.fmt.allocPrint(err_ctx.allocator, "calling function `{s}`", .{name})) |new_operation| {
                                            err_ctx.setErrorData(.{ .type_mismatch = .{
                                                .expected = old_data.expected,
                                                .found = old_data.found,
                                                .operation = new_operation,
                                            } });
                                        } else |_| {
                                            // Allocation failed, keep existing error data
                                        }
                                    }
                                }
                            }
                            // Capture stack trace on error
                            err_ctx.captureStackTrace() catch {};
                        }
                        return err;
                    };

                    // Push stack frame for function call
                    const function_name = switch (application.function.data) {
                        .identifier => |name| name,
                        else => null,
                    };

                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.pushStackFrame(
                            function_name,
                            err_ctx.current_file,
                            application.function.location.line,
                            application.function.location.column,
                            application.function.location.offset,
                            application.function.location.length,
                            false, // Not a native function
                        ) catch {};
                    }

                    // Evaluate function body
                    const result = evaluateExpression(arena, function_ptr.body, bound_env, current_dir, ctx) catch |err| {
                        // Capture stack trace on error (only if not already captured)
                        if (ctx.error_ctx) |err_ctx| {
                            if (err_ctx.stack_trace == null) {
                                err_ctx.captureStackTrace() catch {};
                            }
                        }
                        // Pop stack frame before returning error
                        if (ctx.error_ctx) |err_ctx| {
                            err_ctx.popStackFrame();
                        }
                        return err;
                    };

                    // Pop stack frame after successful evaluation
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.popStackFrame();
                    }

                    break :blk result;
                },
                .native_fn => |native_fn| {
                    // Push stack frame for native function call
                    const function_name = switch (application.function.data) {
                        .identifier => |name| name,
                        else => null,
                    };

                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.pushStackFrame(
                            function_name,
                            err_ctx.current_file,
                            application.function.location.line,
                            application.function.location.column,
                            application.function.location.offset,
                            application.function.location.length,
                            true, // Native function
                        ) catch {};
                    }

                    // Native functions receive a single argument (could be a tuple for multiple args)
                    const args = [_]Value{argument_value};
                    const result = native_fn(arena, &args) catch |err| {
                        // Capture stack trace on error (only if not already captured)
                        if (ctx.error_ctx) |err_ctx| {
                            if (err_ctx.stack_trace == null) {
                                err_ctx.captureStackTrace() catch {};
                            }
                        }
                        // Pop stack frame before returning error
                        if (ctx.error_ctx) |err_ctx| {
                            err_ctx.popStackFrame();
                        }
                        return err;
                    };

                    // Pop stack frame after successful evaluation
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.popStackFrame();
                    }

                    break :blk result;
                },
                else => {
                    // Point to the function expression that isn't actually a function
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(application.function.location.line, application.function.location.column, application.function.location.offset, application.function.location.length);
                        err_ctx.captureStackTrace() catch {};
                    }
                    return error.ExpectedFunction;
                },
            }
        },
        .array => |array| blk: {
            // First pass: evaluate all elements and count total size
            var temp_values = std.ArrayList(Value){};
            defer temp_values.deinit(arena);

            for (array.elements) |element| {
                switch (element) {
                    .normal => |elem_expr| {
                        const value = try evaluateExpression(arena, elem_expr, env, current_dir, ctx);
                        try temp_values.append(arena, value);
                    },
                    .spread => |spread_expr| {
                        const value = try evaluateExpression(arena, spread_expr, env, current_dir, ctx);
                        const spread_array = switch (value) {
                            .array => |a| a,
                            else => return error.TypeMismatch,
                        };
                        for (spread_array.elements) |spread_elem| {
                            try temp_values.append(arena, spread_elem);
                        }
                    },
                    .conditional_if => |cond_elem| {
                        const condition_value = try evaluateExpression(arena, cond_elem.condition, env, current_dir, ctx);
                        const condition = try force(arena, condition_value);
                        const is_true = switch (condition) {
                            .boolean => |b| b,
                            else => return error.TypeMismatch,
                        };
                        if (is_true) {
                            const value = try evaluateExpression(arena, cond_elem.expr, env, current_dir, ctx);
                            try temp_values.append(arena, value);
                        }
                    },
                    .conditional_unless => |cond_elem| {
                        const condition_value = try evaluateExpression(arena, cond_elem.condition, env, current_dir, ctx);
                        const condition = try force(arena, condition_value);
                        const is_true = switch (condition) {
                            .boolean => |b| b,
                            else => return error.TypeMismatch,
                        };
                        if (!is_true) {
                            const value = try evaluateExpression(arena, cond_elem.expr, env, current_dir, ctx);
                            try temp_values.append(arena, value);
                        }
                    },
                }
            }

            break :blk Value{ .array = .{ .elements = try temp_values.toOwnedSlice(arena) } };
        },
        .tuple => |tuple| blk: {
            const values = try arena.alloc(Value, tuple.elements.len);
            for (tuple.elements, 0..) |element, i| {
                values[i] = try evaluateExpression(arena, element, env, current_dir, ctx);
            }
            break :blk Value{ .tuple = .{ .elements = values } };
        },
        .range => |range| blk: {
            const start = try evaluateExpression(arena, range.start, env, current_dir, ctx);
            const end = try evaluateExpression(arena, range.end, env, current_dir, ctx);

            const start_int = switch (start) {
                .integer => |i| i,
                else => return error.TypeMismatch,
            };

            const end_int = switch (end) {
                .integer => |i| i,
                else => return error.TypeMismatch,
            };

            break :blk Value{ .range = .{ .start = start_int, .end = end_int, .inclusive = range.inclusive } };
        },
        .object => |object| blk: {
            // First pass: evaluate dynamic keys and count total fields
            var fields_list = std.ArrayList(ObjectFieldValue){};
            defer fields_list.deinit(arena);

            for (object.fields) |field| {
                switch (field.key) {
                    .static => |static_key| {
                        const key_copy = try arena.dupe(u8, static_key);
                        // Special handling for lambdas with docstrings
                        const field_value = if (field.doc != null and field.value.data == .lambda) blk2: {
                            const lambda = field.value.data.lambda;
                            const function = try arena.create(FunctionValue);
                            function.* = .{
                                .param = lambda.param,
                                .body = lambda.body,
                                .env = env,
                                .docstring = field.doc,
                                .name = null,
                            };
                            break :blk2 Value{ .function = function };
                        } else blk2: {
                            // Wrap field value in a thunk for lazy evaluation
                            const thunk = try arena.create(Thunk);
                            thunk.* = .{
                                .expr = field.value,
                                .env = env,
                                .current_dir = current_dir,
                                .ctx = ctx,
                                .state = .unevaluated,
                                .field_key_location = field.key_location,
                            };
                            break :blk2 Value{ .thunk = thunk };
                        };
                        try fields_list.append(arena, .{ .key = key_copy, .value = field_value, .is_patch = field.is_patch });
                    },
                    .dynamic => |key_expr| {
                        // Evaluate the key expression
                        const key_value = try evaluateExpression(arena, key_expr, env, current_dir, ctx);

                        switch (key_value) {
                            .null_value => {
                                // null key: skip this field
                                continue;
                            },
                            .string => |key_string| {
                                // Single string key
                                const key_copy = try arena.dupe(u8, key_string);
                                // Special handling for lambdas with docstrings
                                const field_value = if (field.doc != null and field.value.data == .lambda) blk2: {
                                    const lambda = field.value.data.lambda;
                                    const function = try arena.create(FunctionValue);
                                    function.* = .{
                                        .param = lambda.param,
                                        .body = lambda.body,
                                        .env = env,
                                        .docstring = field.doc,
                                        .name = null,
                                    };
                                    break :blk2 Value{ .function = function };
                                } else blk2: {
                                    const thunk = try arena.create(Thunk);
                                    thunk.* = .{
                                        .expr = field.value,
                                        .env = env,
                                        .current_dir = current_dir,
                                        .ctx = ctx,
                                        .state = .unevaluated,
                                        .field_key_location = field.key_location,
                                    };
                                    break :blk2 Value{ .thunk = thunk };
                                };
                                try fields_list.append(arena, .{ .key = key_copy, .value = field_value, .is_patch = field.is_patch });
                            },
                            .array => |arr| {
                                // Array of keys: create multiple fields with same value
                                for (arr.elements) |elem| {
                                    switch (elem) {
                                        .null_value => {
                                            // Skip null elements in array
                                            continue;
                                        },
                                        .string => |key_string| {
                                            const key_copy = try arena.dupe(u8, key_string);
                                            // Special handling for lambdas with docstrings
                                            const field_value = if (field.doc != null and field.value.data == .lambda) blk2: {
                                                const lambda = field.value.data.lambda;
                                                const function = try arena.create(FunctionValue);
                                                function.* = .{
                                                    .param = lambda.param,
                                                    .body = lambda.body,
                                                    .env = env,
                                                    .docstring = field.doc,
                                                    .name = null,
                                                };
                                                break :blk2 Value{ .function = function };
                                            } else blk2: {
                                                const thunk = try arena.create(Thunk);
                                                thunk.* = .{
                                                    .expr = field.value,
                                                    .env = env,
                                                    .current_dir = current_dir,
                                                    .ctx = ctx,
                                                    .state = .unevaluated,
                                                    .field_key_location = field.key_location,
                                                };
                                                break :blk2 Value{ .thunk = thunk };
                                            };
                                            try fields_list.append(arena, .{ .key = key_copy, .value = field_value, .is_patch = field.is_patch });
                                        },
                                        else => return error.TypeMismatch,
                                    }
                                }
                            },
                            else => return error.TypeMismatch,
                        }
                    },
                }
            }

            const fields = try fields_list.toOwnedSlice(arena);
            break :blk Value{ .object = .{ .fields = fields, .module_doc = object.module_doc, .name = null } };
        },
        .object_extend => |extend| blk: {
            // Evaluate the base expression
            const base_value = try evaluateExpression(arena, extend.base, env, current_dir, ctx);

            // Check if base is a function - if so, treat this as function application
            switch (base_value) {
                .function => |function_ptr| {
                    // Build an object from the extension fields and apply the function
                    // Note: object_extend only supports static keys
                    var fields_list = std.ArrayList(ObjectFieldValue){};
                    defer fields_list.deinit(arena);
                    for (extend.fields) |field| {
                        const static_key = switch (field.key) {
                            .static => |k| k,
                            .dynamic => return error.TypeMismatch, // Dynamic keys not supported in object_extend
                        };
                        const key_copy = try arena.dupe(u8, static_key);
                        try fields_list.append(arena, .{ .key = key_copy, .value = try evaluateExpression(arena, field.value, env, current_dir, ctx), .is_patch = field.is_patch });
                    }
                    const obj_arg = Value{ .object = .{ .fields = try fields_list.toOwnedSlice(arena), .module_doc = null, .name = null } };
                    const bound_env = try matchPattern(arena, function_ptr.param, obj_arg, function_ptr.env, ctx);
                    break :blk try evaluateExpression(arena, function_ptr.body, bound_env, current_dir, ctx);
                },
                .native_fn => |native_fn| {
                    // Build an object from the extension fields and call native function
                    // Note: object_extend only supports static keys
                    var fields_list = std.ArrayList(ObjectFieldValue){};
                    defer fields_list.deinit(arena);
                    for (extend.fields) |field| {
                        const static_key = switch (field.key) {
                            .static => |k| k,
                            .dynamic => return error.TypeMismatch, // Dynamic keys not supported in object_extend
                        };
                        const key_copy = try arena.dupe(u8, static_key);
                        try fields_list.append(arena, .{ .key = key_copy, .value = try evaluateExpression(arena, field.value, env, current_dir, ctx), .is_patch = field.is_patch });
                    }
                    const obj_arg = Value{ .object = .{ .fields = try fields_list.toOwnedSlice(arena), .module_doc = null, .name = null } };
                    const args = [_]Value{obj_arg};
                    break :blk try native_fn(arena, &args);
                },
                .object => |base_obj| {
                    // Build the extension object with proper handling of is_patch
                    // Note: object_extend only supports static keys
                    var extension_fields = std.ArrayListUnmanaged(ObjectFieldValue){};
                    for (extend.fields) |field| {
                        const static_key = switch (field.key) {
                            .static => |k| k,
                            .dynamic => return error.TypeMismatch, // Dynamic keys not supported in object_extend
                        };
                        const key_copy = try arena.dupe(u8, static_key);
                        const value = try evaluateExpression(arena, field.value, env, current_dir, ctx);

                        if (field.is_patch) {
                            // Patch: merge with existing field if it exists and is an object
                            const existing_value = findObjectField(base_obj, static_key);
                            if (existing_value) |existing| {
                                // Force the existing value if it's a thunk
                                const forced_existing = try force(arena, existing);
                                const existing_obj = switch (forced_existing) {
                                    .object => |o| o,
                                    else => return error.TypeMismatch,
                                };
                                const value_obj = switch (value) {
                                    .object => |o| o,
                                    else => return error.TypeMismatch,
                                };
                                const merged = try mergeObjects(arena, existing_obj, value_obj);
                                try extension_fields.append(arena, .{ .key = key_copy, .value = merged, .is_patch = false });
                            } else {
                                // Field doesn't exist in base, just add it
                                try extension_fields.append(arena, .{ .key = key_copy, .value = value, .is_patch = field.is_patch });
                            }
                        } else {
                            // Overwrite: just use the new value
                            try extension_fields.append(arena, .{ .key = key_copy, .value = value, .is_patch = field.is_patch });
                        }
                    }

                    // Merge base with extension
                    const extension_obj = ObjectValue{ .fields = try extension_fields.toOwnedSlice(arena), .module_doc = null, .name = null };
                    break :blk try mergeObjects(arena, base_obj, extension_obj);
                },
                else => return error.TypeMismatch,
            }
        },
        .array_comprehension => |comp| blk: {
            var result_list = std.ArrayListUnmanaged(Value){};
            try evaluateArrayComprehension(arena, &result_list, comp, 0, env, current_dir, ctx);
            break :blk Value{ .array = .{ .elements = try result_list.toOwnedSlice(arena) } };
        },
        .object_comprehension => |comp| blk: {
            var result_fields = std.ArrayListUnmanaged(ObjectFieldValue){};
            try evaluateObjectComprehension(arena, &result_fields, comp, 0, env, current_dir, ctx);
            break :blk Value{ .object = .{ .fields = try result_fields.toOwnedSlice(arena), .module_doc = null, .name = null } };
        },
        .import_expr => |import_expr| blk: {
            // Import the module - error location will be set inside importModule if it fails
            break :blk try importModule(arena, import_expr.path, current_dir, ctx);
        },
        .field_access => |field_access| blk: {
            const object_value = try evaluateExpression(arena, field_access.object, env, current_dir, ctx);
            const forced = try force(arena, object_value);
            break :blk try accessField(arena, forced, field_access.field, field_access.field_location, ctx);
        },
        .index => |index| blk: {
            const object_value = try evaluateExpression(arena, index.object, env, current_dir, ctx);
            const forced_object = try force(arena, object_value);
            const index_value = try evaluateExpression(arena, index.index, env, current_dir, ctx);
            const forced_index = try force(arena, index_value);

            break :blk switch (forced_object) {
                .array => |arr| blk2: {
                    const idx = switch (forced_index) {
                        .integer => |i| i,
                        else => return error.TypeMismatch,
                    };

                    if (idx < 0 or idx >= arr.elements.len) {
                        return error.IndexOutOfBounds;
                    }

                    break :blk2 arr.elements[@intCast(idx)];
                },
                .object => |obj| blk2: {
                    const key = switch (forced_index) {
                        .string => |s| s,
                        .symbol => |s| s,
                        else => return error.TypeMismatch,
                    };

                    // Search for the field
                    for (obj.fields) |field| {
                        if (std.mem.eql(u8, field.key, key)) {
                            break :blk2 try force(arena, field.value);
                        }
                    }

                    // Field not found
                    return error.FieldNotFound;
                },
                else => return error.TypeMismatch,
            };
        },
        .field_accessor => |field_accessor| blk: {
            // Create a function that accesses the specified fields
            const param = try arena.create(Pattern);
            param.* = .{
                .data = .{ .identifier = "__obj" },
                .location = .{ .line = 0, .column = 0, .offset = 0, .length = 0 },
            };

            // Build the body expression: __obj.field1.field2...
            // Use dummy location since these are runtime-generated expressions
            const dummy_loc = SourceLocation{ .line = 0, .column = 0, .offset = 0, .length = 0 };

            var body_expr = try arena.create(Expression);
            body_expr.* = .{
                .data = .{ .identifier = "__obj" },
                .location = dummy_loc,
            };

            for (field_accessor.fields) |field_name| {
                const field_access_expr = try arena.create(Expression);
                field_access_expr.* = .{
                    .data = .{ .field_access = .{
                        .object = body_expr,
                        .field = field_name,
                        .field_location = dummy_loc,
                    } },
                    .location = dummy_loc,
                };
                body_expr = field_access_expr;
            }

            const func_value = try arena.create(FunctionValue);
            func_value.* = .{
                .param = param,
                .body = body_expr,
                .env = env,
                .docstring = null,
                .name = null,
            };

            break :blk Value{ .function = func_value };
        },
        .operator_function => |op| blk: {
            // Create a curried binary function: x -> y -> x op y
            // First, create the parameters
            const param_x = try arena.create(Pattern);
            param_x.* = .{
                .data = .{ .identifier = "__x" },
                .location = .{ .line = 0, .column = 0, .offset = 0, .length = 0 },
            };

            const param_y = try arena.create(Pattern);
            param_y.* = .{
                .data = .{ .identifier = "__y" },
                .location = .{ .line = 0, .column = 0, .offset = 0, .length = 0 },
            };

            // Create the binary operation expression: __x op __y
            const left_expr = try arena.create(Expression);
            left_expr.* = .{
                .data = .{ .identifier = "__x" },
                .location = .{ .line = 0, .column = 0, .offset = 0, .length = 0 },
            };

            const right_expr = try arena.create(Expression);
            right_expr.* = .{
                .data = .{ .identifier = "__y" },
                .location = .{ .line = 0, .column = 0, .offset = 0, .length = 0 },
            };

            const binary_expr = try arena.create(Expression);
            binary_expr.* = .{
                .data = .{ .binary = .{
                    .op = op,
                    .left = left_expr,
                    .right = right_expr,
                } },
                .location = .{ .line = 0, .column = 0, .offset = 0, .length = 0 },
            };

            // Create the inner lambda: y -> __x op __y
            const inner_lambda_expr = try arena.create(Expression);
            inner_lambda_expr.* = .{
                .data = .{ .lambda = .{
                    .param = param_y,
                    .body = binary_expr,
                } },
                .location = .{ .line = 0, .column = 0, .offset = 0, .length = 0 },
            };

            // Create the outer function: x -> (y -> __x op __y)
            const outer_func = try arena.create(FunctionValue);
            outer_func.* = .{
                .param = param_x,
                .body = inner_lambda_expr,
                .env = env,
                .docstring = null,
                .name = null,
            };

            break :blk Value{ .function = outer_func };
        },
        .field_projection => |field_projection| blk: {
            const object_value = try evaluateExpression(arena, field_projection.object, env, current_dir, ctx);

            // Verify it's an object
            _ = switch (object_value) {
                .object => |obj| obj,
                else => return error.TypeMismatch,
            };

            // Create new object with only the specified fields
            const new_fields = try arena.alloc(ObjectFieldValue, field_projection.fields.len);
            for (field_projection.fields, 0..) |field_name, i| {
                const field_value = try accessField(arena, object_value, field_name, expr.location, ctx);
                new_fields[i] = .{
                    .key = try arena.dupe(u8, field_name),
                    .value = field_value,
                    .is_patch = false,
                };
            }

            break :blk Value{ .object = .{ .fields = new_fields, .module_doc = null, .name = null } };
        },
    };
}

fn accessField(arena: std.mem.Allocator, object_value: Value, field_name: []const u8, location: SourceLocation, ctx: *const EvalContext) EvalError!Value {
    const object = switch (object_value) {
        .object => |obj| obj,
        else => return error.TypeMismatch,
    };

    // Look for the field
    for (object.fields) |field| {
        if (std.mem.eql(u8, field.key, field_name)) {
            // Force the thunk if the value is a thunk
            return try force(arena, field.value);
        }
    }

    // Field not found - populate error context with available fields and location
    if (ctx.error_ctx) |err_ctx| {
        // Set the error location
        err_ctx.setErrorLocation(location.line, location.column, location.offset, location.length);

        // Copy the field name using error context's allocator (not arena)
        const field_name_copy = try err_ctx.allocator.dupe(u8, field_name);

        // Collect available field names (limit to 10 for readability)
        const max_fields = @min(object.fields.len, 10);
        const available = try err_ctx.allocator.alloc([]const u8, max_fields);
        for (object.fields[0..max_fields], 0..) |field, i| {
            available[i] = try err_ctx.allocator.dupe(u8, field.key);
        }

        err_ctx.setErrorData(.{
            .unknown_field = .{
                .field_name = field_name_copy,
                .available_fields = available,
            },
        });
    }

    return error.UnknownField;
}

fn evaluateArrayComprehension(
    arena: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(Value),
    comp: ArrayComprehension,
    clause_index: usize,
    env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!void {
    // Base case: all for clauses have been processed
    if (clause_index >= comp.clauses.len) {
        // Check the filter condition if present
        if (comp.filter) |filter| {
            const filter_value = try evaluateExpression(arena, filter, env, current_dir, ctx);
            const filter_bool = switch (filter_value) {
                .boolean => |b| b,
                else => return error.TypeMismatch,
            };
            if (!filter_bool) return; // Skip this iteration
        }

        // Evaluate and add the body to the result
        const value = try evaluateExpression(arena, comp.body, env, current_dir, ctx);
        try result.append(arena, value);
        return;
    }

    // Process current for clause
    const clause = comp.clauses[clause_index];
    const iterable_value = try evaluateExpression(arena, clause.iterable, env, current_dir, ctx);

    switch (iterable_value) {
        .array => |arr| {
            for (arr.elements) |element| {
                const new_env = try matchPattern(arena, clause.pattern, element, env, ctx);
                try evaluateArrayComprehension(arena, result, comp, clause_index + 1, new_env, current_dir, ctx);
            }
        },
        .range => |range| {
            const actual_end = if (range.inclusive) range.end else range.end - 1;
            if (range.start <= actual_end) {
                var i = range.start;
                while (i <= actual_end) : (i += 1) {
                    const element = Value{ .integer = i };
                    const new_env = try matchPattern(arena, clause.pattern, element, env, ctx);
                    try evaluateArrayComprehension(arena, result, comp, clause_index + 1, new_env, current_dir, ctx);
                }
            }
        },
        .object => |obj| {
            for (obj.fields) |field| {
                // Create a tuple (key, value) for object iteration
                const tuple_elements = try arena.alloc(Value, 2);
                tuple_elements[0] = .{ .string = try arena.dupe(u8, field.key) };
                // Force the thunk if the value is a thunk
                tuple_elements[1] = try force(arena, field.value);
                const tuple_value = Value{ .tuple = .{ .elements = tuple_elements } };

                const new_env = try matchPattern(arena, clause.pattern, tuple_value, env, ctx);
                try evaluateArrayComprehension(arena, result, comp, clause_index + 1, new_env, current_dir, ctx);
            }
        },
        else => return error.TypeMismatch,
    }
}

fn evaluateObjectComprehension(
    arena: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(ObjectFieldValue),
    comp: ObjectComprehension,
    clause_index: usize,
    env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!void {
    // Base case: all for clauses have been processed
    if (clause_index >= comp.clauses.len) {
        // Check the filter condition if present
        if (comp.filter) |filter| {
            const filter_value = try evaluateExpression(arena, filter, env, current_dir, ctx);
            const filter_bool = switch (filter_value) {
                .boolean => |b| b,
                else => return error.TypeMismatch,
            };
            if (!filter_bool) return; // Skip this iteration
        }

        // Evaluate key and value
        const key_value = try evaluateExpression(arena, comp.key, env, current_dir, ctx);
        const value_value = try evaluateExpression(arena, comp.value, env, current_dir, ctx);

        // Convert key to string
        const key_string = switch (key_value) {
            .string => |s| try arena.dupe(u8, s),
            .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
            .symbol => |s| try arena.dupe(u8, s),
            else => return error.TypeMismatch,
        };

        try result.append(arena, .{ .key = key_string, .value = value_value, .is_patch = false });
        return;
    }

    // Process current for clause
    const clause = comp.clauses[clause_index];
    const iterable_value = try evaluateExpression(arena, clause.iterable, env, current_dir, ctx);

    switch (iterable_value) {
        .array => |arr| {
            for (arr.elements) |element| {
                const new_env = try matchPattern(arena, clause.pattern, element, env, ctx);
                try evaluateObjectComprehension(arena, result, comp, clause_index + 1, new_env, current_dir, ctx);
            }
        },
        .range => |range| {
            const actual_end = if (range.inclusive) range.end else range.end - 1;
            if (range.start <= actual_end) {
                var i = range.start;
                while (i <= actual_end) : (i += 1) {
                    const element = Value{ .integer = i };
                    const new_env = try matchPattern(arena, clause.pattern, element, env, ctx);
                    try evaluateObjectComprehension(arena, result, comp, clause_index + 1, new_env, current_dir, ctx);
                }
            }
        },
        .object => |obj| {
            for (obj.fields) |field| {
                // Create a tuple (key, value) for object iteration
                const tuple_elements = try arena.alloc(Value, 2);
                tuple_elements[0] = .{ .string = try arena.dupe(u8, field.key) };
                // Force the thunk if the value is a thunk
                tuple_elements[1] = try force(arena, field.value);
                const tuple_value = Value{ .tuple = .{ .elements = tuple_elements } };

                const new_env = try matchPattern(arena, clause.pattern, tuple_value, env, ctx);
                try evaluateObjectComprehension(arena, result, comp, clause_index + 1, new_env, current_dir, ctx);
            }
        },
        else => return error.TypeMismatch,
    }
}

fn importModule(
    arena: std.mem.Allocator,
    import_path: []const u8,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!Value {
    var module_file = try module_resolver.openImportFile(ctx, import_path, current_dir);
    defer module_file.file.close();
    defer ctx.allocator.free(module_file.path);

    const contents = try module_file.file.readToEndAlloc(arena, std.math.maxInt(usize));

    // Save the current file so we can restore it after import
    // Make an owned copy since setCurrentFile will free the old current_file
    var saved_file: ?[]const u8 = null;
    if (ctx.error_ctx) |err_ctx| {
        if (err_ctx.current_file.len > 0) {
            saved_file = try ctx.allocator.dupe(u8, err_ctx.current_file);
        }
    }
    defer if (saved_file) |file| ctx.allocator.free(file);

    var parser = try Parser.init(arena, contents);
    if (ctx.error_ctx) |err_ctx| {
        err_ctx.setCurrentFile(module_file.path);
        parser.setErrorContext(err_ctx);
    }
    const expression = parser.parse() catch |err| {
        // Only register source on parse error
        if (ctx.error_ctx) |err_ctx| {
            err_ctx.registerSource(module_file.path, contents) catch {};
            // Restore the previous file - important to update BOTH current_file and source_filename
            // because source_filename may have been set during error reporting
            if (saved_file) |file| {
                err_ctx.setCurrentFile(file);
                // Also restore source_filename if it was set to the module file
                if (err_ctx.source_filename_owned and err_ctx.source_filename.len > 0) {
                    err_ctx.allocator.free(err_ctx.source_filename);
                }
                if (err_ctx.allocator.dupe(u8, file)) |owned| {
                    err_ctx.source_filename = owned;
                    err_ctx.source_filename_owned = true;
                } else |_| {
                    err_ctx.source_filename = file;
                    err_ctx.source_filename_owned = false;
                }
            } else {
                err_ctx.setCurrentFile("");
                if (err_ctx.source_filename_owned and err_ctx.source_filename.len > 0) {
                    err_ctx.allocator.free(err_ctx.source_filename);
                }
                err_ctx.source_filename = "";
                err_ctx.source_filename_owned = false;
            }
        }
        return err;
    };

    const env = try builtin_env.createBuiltinEnvironment(arena);
    const module_dir = std.fs.path.dirname(module_file.path);
    const result = evaluateExpression(arena, expression, env, module_dir, ctx) catch |err| {
        // Only register source on evaluation error
        if (ctx.error_ctx) |err_ctx| {
            err_ctx.registerSource(module_file.path, contents) catch {};
            // Restore the previous file - important to update BOTH current_file and source_filename
            if (saved_file) |file| {
                err_ctx.setCurrentFile(file);
                // Also restore source_filename if it was set to the module file
                if (err_ctx.source_filename_owned and err_ctx.source_filename.len > 0) {
                    err_ctx.allocator.free(err_ctx.source_filename);
                }
                if (err_ctx.allocator.dupe(u8, file)) |owned| {
                    err_ctx.source_filename = owned;
                    err_ctx.source_filename_owned = true;
                } else |_| {
                    err_ctx.source_filename = file;
                    err_ctx.source_filename_owned = false;
                }
            } else {
                err_ctx.setCurrentFile("");
                if (err_ctx.source_filename_owned and err_ctx.source_filename.len > 0) {
                    err_ctx.allocator.free(err_ctx.source_filename);
                }
                err_ctx.source_filename = "";
                err_ctx.source_filename_owned = false;
            }
        }
        return err;
    };

    // Restore the previous file
    if (ctx.error_ctx) |err_ctx| {
        if (saved_file) |file| {
            err_ctx.setCurrentFile(file);
        } else {
            err_ctx.setCurrentFile("");
        }
    }

    return result;
}

/// Create an environment with both builtin functions and standard library modules
pub fn createStdlibEnvironment(
    arena: std.mem.Allocator,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!?*Environment {
    // Start with builtin environment
    var env = try builtin_env.createBuiltinEnvironment(arena);

    // Import standard library modules (if available)
    const stdlib_modules = [_][]const u8{ "Array", "Basics", "Float", "Math", "Object", "Range", "Result", "String", "Symbol", "Tuple" };
    for (stdlib_modules) |module_name| {
        // Try to import the module, but continue if it's not found
        const module_value = importModule(arena, module_name, current_dir, ctx) catch |err| {
            if (err == error.ModuleNotFound) {
                // Module not found, skip it
                continue;
            }
            return err;
        };

        // Special handling for Basics: expose all fields unqualified
        if (std.mem.eql(u8, module_name, "Basics")) {
            const basics_obj = switch (module_value) {
                .object => |obj| obj,
                else => return error.TypeMismatch,
            };

            // Add each field from Basics to the environment
            for (basics_obj.fields) |field| {
                const field_value = try force(arena, field.value);
                const field_env = try arena.create(Environment);
                field_env.* = .{
                    .parent = env,
                    .name = field.key,
                    .value = field_value,
                };
                env = field_env;
            }
        }

        // Add the module itself to the environment
        const new_env = try arena.create(Environment);
        new_env.* = .{
            .parent = env,
            .name = module_name,
            .value = module_value,
        };
        env = new_env;
    }

    return env;
}

// Helper functions for error reporting

fn getValueTypeName(value: Value) []const u8 {
    return switch (value) {
        .integer => "integer",
        .float => "float",
        .boolean => "boolean",
        .null_value => "null",
        .symbol => "symbol",
        .string => "string",
        .array => "array",
        .tuple => "tuple",
        .object => "object",
        .function => "function",
        .native_fn => "native function",
        .thunk => "thunk",
        .range => "range",
    };
}

fn getPatternTypeName(pattern: *Pattern) []const u8 {
    return switch (pattern.data) {
        .identifier => "identifier",
        .integer => "integer",
        .float => "float",
        .boolean => "boolean",
        .null_literal => "null",
        .symbol => "symbol",
        .string_literal => "string",
        .tuple => "tuple",
        .array => "array",
        .object => "object",
    };
}

fn formatPatternValue(allocator: std.mem.Allocator, pattern: *Pattern) ![]u8 {
    return switch (pattern.data) {
        .identifier => |name| try std.fmt.allocPrint(allocator, "{s}", .{name}),
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .boolean => |v| try std.fmt.allocPrint(allocator, "{s}", .{if (v) "true" else "false"}),
        .null_literal => try allocator.dupe(u8, "null"),
        .symbol => |s| try std.fmt.allocPrint(allocator, "#{s}", .{s}),
        .string_literal => |s| try std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
        .tuple => |t| try std.fmt.allocPrint(allocator, "tuple with {d} elements", .{t.elements.len}),
        .array => |a| if (a.rest) |_|
            try std.fmt.allocPrint(allocator, "array with at least {d} elements", .{a.elements.len})
        else
            try std.fmt.allocPrint(allocator, "array with exactly {d} elements", .{a.elements.len}),
        .object => |o| try std.fmt.allocPrint(allocator, "object with fields: {s}", .{try formatObjectFields(allocator, o)}),
    };
}

fn formatObjectFields(allocator: std.mem.Allocator, obj_pattern: ast.ObjectPattern) ![]u8 {
    if (obj_pattern.fields.len == 0) return allocator.dupe(u8, "{}");

    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);
    try result.append(allocator, '{');

    for (obj_pattern.fields, 0..) |field, i| {
        if (i > 0) try result.appendSlice(allocator, ", ");
        try result.appendSlice(allocator, field.key);
    }

    try result.append(allocator, '}');

    return try result.toOwnedSlice(allocator);
}
