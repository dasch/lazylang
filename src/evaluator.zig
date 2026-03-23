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

const MAX_RECURSION_DEPTH: u32 = 512;

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
pub fn valuesEqual(arena: std.mem.Allocator, a: Value, b: Value) EvalError!bool {
    const a_forced = try force(arena, a);
    const b_forced = try force(arena, b);

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
        .string => |av| switch (b_forced) {
            .string => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .function => false,
        .native_fn => false,
        .thunk => false,
        .array => |av| switch (b_forced) {
            .array => |bv| blk: {
                if (av.elements.len != bv.elements.len) break :blk false;
                for (av.elements, 0..) |elem, i| {
                    if (!try valuesEqual(arena, elem, bv.elements[i])) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .tuple => |av| switch (b_forced) {
            .tuple => |bv| blk: {
                if (av.elements.len != bv.elements.len) break :blk false;
                for (av.elements, 0..) |elem, i| {
                    if (!try valuesEqual(arena, elem, bv.elements[i])) break :blk false;
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
                            if (!try valuesEqual(arena, afield.value, bfield.value)) break :blk false;
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
        if (scope.siblings) |map| {
            if (map.get(name)) |v| return v;
        }
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
                    const alloc = if (ctx.error_ctx) |ec| ec.allocator else std.heap.page_allocator;
                    return reportPatternMismatch(ctx, pattern, fmtPattern(alloc, pattern, "integer"), fmtValue(alloc, value, getValueTypeName(value)));
                },
            };
            if (expected != actual) {
                const alloc = if (ctx.error_ctx) |ec| ec.allocator else std.heap.page_allocator;
                return reportPatternMismatch(ctx, pattern, fmtPattern(alloc, pattern, "value"), fmtValue(alloc, value, "value"));
            }
            break :blk base_env;
        },
        .float => |expected| blk: {
            const actual = switch (value) {
                .float => |v| v,
                else => {
                    return reportPatternMismatch(ctx, pattern, .{ .str = getPatternTypeName(pattern), .owned = false }, .{ .str = getValueTypeName(value), .owned = false });
                },
            };
            if (expected != actual) {
                const alloc = if (ctx.error_ctx) |ec| ec.allocator else std.heap.page_allocator;
                return reportPatternMismatch(ctx, pattern, fmtPattern(alloc, pattern, "value"), fmtValue(alloc, value, "value"));
            }
            break :blk base_env;
        },
        .boolean => |expected| blk: {
            const actual = switch (value) {
                .boolean => |v| v,
                else => {
                    return reportPatternMismatch(ctx, pattern, .{ .str = getPatternTypeName(pattern), .owned = false }, .{ .str = getValueTypeName(value), .owned = false });
                },
            };
            if (expected != actual) {
                const alloc = if (ctx.error_ctx) |ec| ec.allocator else std.heap.page_allocator;
                return reportPatternMismatch(ctx, pattern, fmtPattern(alloc, pattern, "value"), fmtValue(alloc, value, "value"));
            }
            break :blk base_env;
        },
        .null_literal => blk: {
            switch (value) {
                .null_value => {},
                else => {
                    return reportPatternMismatch(ctx, pattern, .{ .str = "null", .owned = false }, .{ .str = getValueTypeName(value), .owned = false });
                },
            }
            break :blk base_env;
        },
        .string_literal => |expected| blk: {
            const actual = switch (value) {
                .string => |v| v,
                else => {
                    return reportPatternMismatch(ctx, pattern, .{ .str = "string", .owned = false }, .{ .str = getValueTypeName(value), .owned = false });
                },
            };
            if (!std.mem.eql(u8, expected, actual)) {
                const alloc = if (ctx.error_ctx) |ec| ec.allocator else std.heap.page_allocator;
                return reportPatternMismatch(ctx, pattern, fmtPattern(alloc, pattern, "value"), fmtValue(alloc, value, "value"));
            }
            break :blk base_env;
        },
        .symbol => |raw_expected| blk: {
            // Symbol patterns match against strings (strip # prefix)
            const expected = if (raw_expected.len > 0 and raw_expected[0] == '#') raw_expected[1..] else raw_expected;
            const actual = switch (value) {
                .string => |v| v,
                else => {
                    return reportPatternMismatch(ctx, pattern, .{ .str = "string", .owned = false }, .{ .str = getValueTypeName(value), .owned = false });
                },
            };
            if (!std.mem.eql(u8, expected, actual)) {
                const alloc = if (ctx.error_ctx) |ec| ec.allocator else std.heap.page_allocator;
                return reportPatternMismatch(ctx, pattern, fmtPattern(alloc, pattern, "value"), fmtValue(alloc, value, "value"));
            }
            break :blk base_env;
        },
        .tuple => |tuple_pattern| blk: {
            const tuple_value = switch (value) {
                .tuple => |t| t,
                else => {
                    return reportPatternMismatch(ctx, pattern, .{ .str = "tuple", .owned = false }, .{ .str = getValueTypeName(value), .owned = false });
                },
            };

            if (tuple_pattern.elements.len != tuple_value.elements.len) {
                const alloc = if (ctx.error_ctx) |ec| ec.allocator else std.heap.page_allocator;
                return reportPatternMismatch(ctx, pattern, fmtPattern(alloc, pattern, "tuple"), fmtValue(alloc, value, "tuple"));
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
                    return reportPatternMismatch(ctx, pattern, .{ .str = "array", .owned = false }, .{ .str = getValueTypeName(value), .owned = false });
                },
            };

            // If there's no rest pattern, lengths must match exactly
            if (array_pattern.rest == null) {
                if (array_pattern.elements.len != array_value.elements.len) {
                    const alloc = if (ctx.error_ctx) |ec| ec.allocator else std.heap.page_allocator;
                    return reportPatternMismatch(ctx, pattern, fmtPattern(alloc, pattern, "array"), fmtValue(alloc, value, "array"));
                }
            } else {
                // With rest pattern, array must have at least as many elements as fixed patterns
                if (array_value.elements.len < array_pattern.elements.len) {
                    const alloc = if (ctx.error_ctx) |ec| ec.allocator else std.heap.page_allocator;
                    return reportPatternMismatch(ctx, pattern, fmtPattern(alloc, pattern, "array"), fmtValue(alloc, value, "array"));
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
                    return reportPatternMismatch(ctx, pattern, .{ .str = "object", .owned = false }, .{ .str = getValueTypeName(value), .owned = false });
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
                    if (pattern_field.default) |default_expr| {
                        // Use default value when field is missing
                        const default_value = try evaluateExpression(arena, default_expr, current_env, null, ctx);
                        current_env = try matchPattern(arena, pattern_field.pattern, default_value, current_env, ctx);
                        continue;
                    }
                    const alloc = if (ctx.error_ctx) |ec| ec.allocator else std.heap.page_allocator;
                    const ps: OwnedStr = if (std.fmt.allocPrint(alloc, "object with field '{s}'", .{pattern_field.key})) |s|
                        .{ .str = s, .owned = true }
                    else |_|
                        .{ .str = "object", .owned = false };
                    const vs: OwnedStr = if (object_value.fields.len == 0)
                        if (std.fmt.allocPrint(alloc, "object with no fields", .{})) |s|
                            OwnedStr{ .str = s, .owned = true }
                        else |_|
                            OwnedStr{ .str = "object", .owned = false }
                    else blk2: {
                        var fields_str = std.ArrayList(u8){};
                        defer fields_str.deinit(alloc);
                        fields_str.appendSlice(alloc, "object with fields: {") catch break :blk2 OwnedStr{ .str = "object", .owned = false };
                        for (object_value.fields, 0..) |field, i| {
                            if (i > 0) fields_str.appendSlice(alloc, ", ") catch break :blk2 OwnedStr{ .str = "object", .owned = false };
                            fields_str.appendSlice(alloc, field.key) catch break :blk2 OwnedStr{ .str = "object", .owned = false };
                        }
                        fields_str.append(alloc, '}') catch break :blk2 OwnedStr{ .str = "object", .owned = false };
                        break :blk2 OwnedStr{ .str = fields_str.toOwnedSlice(alloc) catch break :blk2 OwnedStr{ .str = "object", .owned = false }, .owned = true };
                    };
                    return reportPatternMismatch(ctx, pattern, ps, vs);
                }
            }
            break :blk current_env;
        },
    };
}

const OwnedStr = struct { str: []const u8, owned: bool };

fn fmtPattern(allocator: std.mem.Allocator, pattern: *Pattern, fallback: []const u8) OwnedStr {
    const s = formatPatternValue(allocator, pattern) catch return .{ .str = fallback, .owned = false };
    return .{ .str = s, .owned = true };
}

fn fmtValue(allocator: std.mem.Allocator, value: Value, fallback: []const u8) OwnedStr {
    const s = formatValueShort(allocator, value) catch return .{ .str = fallback, .owned = false };
    return .{ .str = s, .owned = true };
}

/// Report a type mismatch error during pattern destructuring and return error.TypeMismatch.
fn reportPatternMismatch(
    ctx: *const EvalContext,
    pattern: *Pattern,
    expected: OwnedStr,
    found: OwnedStr,
) EvalError {
    if (ctx.error_ctx) |err_ctx| {
        err_ctx.setErrorLocation(
            pattern.location.line,
            pattern.location.column,
            pattern.location.offset,
            pattern.location.length,
        );
        err_ctx.setErrorData(.{ .type_mismatch = .{
            .expected = expected.str,
            .found = found.str,
            .operation = "destructuring",
            .expected_owned = expected.owned,
            .found_owned = found.owned,
        } });
    }
    return error.TypeMismatch;
}

const INDEX_THRESHOLD = 8;

/// Returns a pointer to the object's field index, building it if necessary.
/// The index maps field names to their position in obj.fields.
/// Only called for objects with at least INDEX_THRESHOLD fields.
fn getOrBuildIndex(arena: std.mem.Allocator, obj: *ObjectValue) !*std.StringHashMapUnmanaged(usize) {
    if (obj.field_index) |idx| return idx;
    const idx = try arena.create(std.StringHashMapUnmanaged(usize));
    idx.* = .{};
    for (obj.fields, 0..) |field, i| {
        try idx.put(arena, field.key, i);
    }
    obj.field_index = idx;
    return idx;
}

fn findObjectField(arena: std.mem.Allocator, obj: *ObjectValue, key: []const u8) EvalError!?Value {
    if (obj.fields.len >= INDEX_THRESHOLD) {
        const idx = try getOrBuildIndex(arena, obj);
        if (idx.get(key)) |i| return obj.fields[i].value;
        return null;
    }
    for (obj.fields) |field| {
        if (std.mem.eql(u8, field.key, key)) {
            return field.value;
        }
    }
    return null;
}

fn mergeObjects(arena: std.mem.Allocator, base: ObjectValue, extension: ObjectValue) EvalError!Value {
    var result_fields = std.ArrayListUnmanaged(ObjectFieldValue){};

    // Build indices for O(n+m) merge instead of O(n×m).
    // We use local mutable copies so getOrBuildIndex can cache the index on them.
    var base_mut = base;
    var ext_mut = extension;

    // Build an index for the extension so we can look up each base field in O(1).
    // For small objects we fall back to linear scan inside findObjectField.
    const use_ext_index = extension.fields.len >= INDEX_THRESHOLD;
    const ext_idx: ?*std.StringHashMapUnmanaged(usize) = if (use_ext_index)
        try getOrBuildIndex(arena, &ext_mut)
    else
        null;

    // First, add all fields from base, replacing/merging with extension where needed.
    for (base_mut.fields) |base_field| {
        // Look up whether this base key is overridden in extension.
        const ext_field_opt: ?ObjectFieldValue = if (ext_idx) |idx| blk: {
            if (idx.get(base_field.key)) |i| break :blk extension.fields[i];
            break :blk null;
        } else blk: {
            var found: ?ObjectFieldValue = null;
            for (extension.fields) |ef| {
                if (std.mem.eql(u8, base_field.key, ef.key)) {
                    found = ef;
                    break;
                }
            }
            break :blk found;
        };

        if (ext_field_opt) |ext_field| {
            // Check if we should deep merge or replace
            if (ext_field.is_patch) {
                // Deep merge: both values should be objects
                const base_forced = try force(arena, base_field.value);
                const ext_forced = try force(arena, ext_field.value);
                if (base_forced == .object and ext_forced == .object) {
                    const merged = try mergeObjects(arena, base_forced.object, ext_forced.object);
                    try result_fields.append(arena, .{ .key = ext_field.key, .value = merged, .is_patch = false, .is_hidden = ext_field.is_hidden or base_field.is_hidden, .doc = ext_field.doc orelse base_field.doc });
                } else {
                    // Not both objects, just use extension value
                    try result_fields.append(arena, .{ .key = ext_field.key, .value = ext_field.value, .is_patch = ext_field.is_patch, .is_hidden = ext_field.is_hidden or base_field.is_hidden, .doc = ext_field.doc orelse base_field.doc });
                }
            } else {
                // Shallow replace: use the extension value
                try result_fields.append(arena, .{ .key = ext_field.key, .value = ext_field.value, .is_patch = ext_field.is_patch, .is_hidden = ext_field.is_hidden or base_field.is_hidden, .doc = ext_field.doc orelse base_field.doc });
            }
        } else {
            // No override, keep the base field
            try result_fields.append(arena, .{ .key = base_field.key, .value = base_field.value, .is_patch = base_field.is_patch, .is_hidden = base_field.is_hidden, .doc = base_field.doc });
        }
    }

    // Build an index for base to efficiently find which extension fields are new.
    const use_base_index = base.fields.len >= INDEX_THRESHOLD;
    const base_idx: ?*std.StringHashMapUnmanaged(usize) = if (use_base_index)
        try getOrBuildIndex(arena, &base_mut)
    else
        null;

    // Then, add fields from extension that are not in base.
    for (extension.fields) |ext_field| {
        const found_in_base: bool = if (base_idx) |idx|
            idx.contains(ext_field.key)
        else blk: {
            var found = false;
            for (base.fields) |bf| {
                if (std.mem.eql(u8, bf.key, ext_field.key)) {
                    found = true;
                    break;
                }
            }
            break :blk found;
        };

        if (!found_in_base) {
            try result_fields.append(arena, .{ .key = ext_field.key, .value = ext_field.value, .is_patch = ext_field.is_patch, .is_hidden = ext_field.is_hidden, .doc = ext_field.doc });
        }
    }

    // Prefer extension's module_doc if it exists, otherwise use base's
    const module_doc = extension.module_doc orelse base.module_doc;
    const fields = try result_fields.toOwnedSlice(arena);

    // Late-binding self: clone thunks and point them to a new self_value cell
    // for the merged object. Cloning is necessary so the base object's thunks
    // are not mutated (pure functional semantics).
    const self_cell = try arena.create(Value);
    self_cell.* = .null_value; // placeholder
    for (fields) |*field| {
        if (field.value == .thunk) {
            const old_thunk = field.value.thunk;
            const new_thunk = try arena.create(Thunk);
            new_thunk.* = old_thunk.*;
            new_thunk.self_value = self_cell;
            new_thunk.state = .unevaluated; // reset so it re-evaluates with new self
            field.value = .{ .thunk = new_thunk };
        }
    }
    const result = Value{ .object = .{ .fields = fields, .module_doc = module_doc } };
    self_cell.* = result;
    return result;
}

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
                    // If this thunk has a self reference, bind `self` and all sibling
                    // field names in the environment so fields can reference each other.
                    const eval_env = if (thunk.self_value) |self_val| blk: {
                        // Use cached sibling env if available to avoid rebuilding N env nodes
                        // every time a field is accessed.
                        if (thunk.cached_sibling_env) |cached_env| {
                            break :blk cached_env;
                        }

                        // Start with `self` binding
                        var current_env = try arena.create(Environment);
                        current_env.* = .{
                            .name = "self",
                            .value = self_val.*,
                            .parent = thunk.env,
                        };
                        // Add bindings for each sibling field name,
                        // skipping the current field to avoid self-referential cycles.
                        switch (self_val.*) {
                            .object => |obj| {
                                for (obj.fields) |field| {
                                    // Skip the field being evaluated (avoid circular reference)
                                    const is_self_thunk = switch (field.value) {
                                        .thunk => |t| t == thunk,
                                        else => false,
                                    };
                                    if (is_self_thunk) continue;

                                    const field_env = try arena.create(Environment);
                                    field_env.* = .{
                                        .name = field.key,
                                        .value = field.value,
                                        .parent = current_env,
                                    };
                                    current_env = field_env;
                                }
                            },
                            else => {},
                        }
                        // Cache so subsequent forces of this thunk reuse the same env chain.
                        thunk.cached_sibling_env = current_env;
                        break :blk current_env;
                    } else thunk.env;
                    const result = try evaluateExpression(arena, thunk.expr, eval_env, thunk.current_dir, thunk.ctx);
                    thunk.state = .{ .evaluated = result };
                    return result;
                },
            }
        },
        else => value,
    };
}

/// Recursively force all thunks in a value, including nested objects and arrays.
/// Use this to ensure all thunks are evaluated with the correct arena before
/// passing values to formatters that use temporary arenas.
pub fn forceDeep(arena: std.mem.Allocator, value: Value) EvalError!Value {
    const forced = try force(arena, value);
    return switch (forced) {
        .object => |obj| {
            for (obj.fields) |*field| {
                field.value = try forceDeep(arena, field.value);
            }
            return forced;
        },
        .array => |arr| {
            for (arr.elements) |*elem| {
                elem.* = try forceDeep(arena, elem.*);
            }
            return forced;
        },
        .tuple => |tup| {
            for (tup.elements) |*elem| {
                elem.* = try forceDeep(arena, elem.*);
            }
            return forced;
        },
        else => forced,
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


fn evaluateBinaryOp(
    arena: std.mem.Allocator,
    binary: ast.Binary,
    env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!Value {
    const left_value = try evaluateExpression(arena, binary.left, env, current_dir, ctx);
    const right_value = try evaluateExpression(arena, binary.right, env, current_dir, ctx);

    return switch (binary.op) {
        .add, .subtract, .multiply, .divide => {
            // String concatenation: "hello" + "world"
            if (binary.op == .add) {
                if (left_value == .string and right_value == .string) {
                    const left_str = left_value.string;
                    const right_str = right_value.string;
                    const concatenated = try std.fmt.allocPrint(arena, "{s}{s}", .{ left_str, right_str });
                    return Value{ .string = concatenated };
                }
            }

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
                    .divide => divide: {
                        if (right_float == 0.0) {
                            if (ctx.error_ctx) |err_ctx| {
                                // Point to the divisor (right operand)
                                err_ctx.setErrorLocation(binary.right.location.line, binary.right.location.column, binary.right.location.offset, binary.right.location.length);
                            }
                            return error.DivisionByZero;
                        }
                        break :divide left_float / right_float;
                    },
                    else => unreachable,
                };
                return Value{ .float = float_result };
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
                    .divide => divide: {
                        if (right_int == 0) {
                            if (ctx.error_ctx) |err_ctx| {
                                // Point to the divisor (right operand)
                                err_ctx.setErrorLocation(binary.right.location.line, binary.right.location.column, binary.right.location.offset, binary.right.location.length);
                            }
                            return error.DivisionByZero;
                        }
                        break :divide @divTrunc(left_int, right_int);
                    },
                    else => unreachable,
                };
                return Value{ .integer = int_result };
            }
        },
        .logical_and => {
            const left_bool = switch (left_value) {
                .boolean => |v| v,
                else => return error.TypeMismatch,
            };
            const right_bool = switch (right_value) {
                .boolean => |v| v,
                else => return error.TypeMismatch,
            };
            return Value{ .boolean = left_bool and right_bool };
        },
        .logical_or => {
            const left_bool = switch (left_value) {
                .boolean => |v| v,
                else => return error.TypeMismatch,
            };
            const right_bool = switch (right_value) {
                .boolean => |v| v,
                else => return error.TypeMismatch,
            };
            return Value{ .boolean = left_bool or right_bool };
        },
        .equal, .not_equal => {
            const bool_result = switch (binary.op) {
                .equal => try valuesEqual(arena, left_value, right_value),
                .not_equal => !try valuesEqual(arena, left_value, right_value),
                else => unreachable,
            };
            return Value{ .boolean = bool_result };
        },
        .less_than, .greater_than, .less_or_equal, .greater_or_equal => {
            // Check if either operand is a float
            const is_float_op = (left_value == .float or right_value == .float);

            const bool_result = if (is_float_op) float_cmp: {
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

                break :float_cmp switch (binary.op) {
                    .less_than => left_float < right_float,
                    .greater_than => left_float > right_float,
                    .less_or_equal => left_float <= right_float,
                    .greater_or_equal => left_float >= right_float,
                    else => unreachable,
                };
            } else int_cmp: {
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

                break :int_cmp switch (binary.op) {
                    .less_than => left_int < right_int,
                    .greater_than => left_int > right_int,
                    .less_or_equal => left_int <= right_int,
                    .greater_or_equal => left_int >= right_int,
                    else => unreachable,
                };
            };
            return Value{ .boolean = bool_result };
        },
        .pipeline => {
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
                        const arg_str = formatValueShort(err_ctx.allocator, left_value) catch null;
                        err_ctx.pushStackFrame(
                            function_name,
                            err_ctx.current_file,
                            binary.right.location.line,
                            binary.right.location.column,
                            binary.right.location.offset,
                            binary.right.location.length,
                            false,
                            arg_str,
                        ) catch {
                            if (arg_str) |s| err_ctx.allocator.free(s);
                        };
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

                    return result;
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
                            null,
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

                    return result;
                },
                else => |bad_value| {
                    // Point to the right operand (function) that isn't actually a function
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(binary.right.location.line, binary.right.location.column, binary.right.location.offset, binary.right.location.length);
                        err_ctx.setErrorData(.{ .not_a_function = .{ .value_type = getValueTypeName(bad_value) } });
                        err_ctx.captureStackTrace() catch {};
                    }
                    return error.ExpectedFunction;
                },
            }
        },
        .merge => {
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
            return try mergeObjects(arena, left_obj, right_obj);
        },
        .concatenate => {
            // Array concatenation operator: arr1 ++ arr2
            const left_arr = switch (left_value) {
                .array => |a| a,
                else => return error.TypeMismatch,
            };
            const right_arr = switch (right_value) {
                .array => |a| a,
                else => return error.TypeMismatch,
            };

            const combined = try arena.alloc(Value, left_arr.elements.len + right_arr.elements.len);
            @memcpy(combined[0..left_arr.elements.len], left_arr.elements);
            @memcpy(combined[left_arr.elements.len..], right_arr.elements);

            return Value{ .array = .{ .elements = combined } };
        },
    };
}


fn evaluateObjectLiteral(
    arena: std.mem.Allocator,
    object: ast.ObjectLiteral,
    env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!Value {
    // Allocate a mutable cell for `self` — thunks will read from it when forced
    const self_cell = try arena.create(Value);
    self_cell.* = .null_value; // placeholder until object is constructed

    // First pass: evaluate dynamic keys and count total fields
    var fields_list = std.ArrayList(ObjectFieldValue){};
    defer fields_list.deinit(arena);

    for (object.fields) |field| {
        // Check conditional inclusion (if/unless)
        switch (field.condition) {
            .none => {},
            .if_cond => |cond_expr| {
                const cond_val = try evaluateExpression(arena, cond_expr, env, current_dir, ctx);
                switch (cond_val) {
                    .boolean => |b| if (!b) continue,
                    else => return error.TypeMismatch,
                }
            },
            .unless_cond => |cond_expr| {
                const cond_val = try evaluateExpression(arena, cond_expr, env, current_dir, ctx);
                switch (cond_val) {
                    .boolean => |b| if (b) continue,
                    else => return error.TypeMismatch,
                }
            },
        }

        switch (field.key) {
            .static => |static_key| {
                const key_copy = try arena.dupe(u8, static_key);
                // Wrap field value in a thunk for lazy evaluation
                const thunk = try arena.create(Thunk);
                thunk.* = .{
                    .expr = field.value,
                    .env = env,
                    .current_dir = current_dir,
                    .ctx = ctx,
                    .state = .unevaluated,
                    .field_key_location = field.key_location,
                    .self_value = self_cell,
                };
                try fields_list.append(arena, .{ .key = key_copy, .value = .{ .thunk = thunk }, .is_patch = field.is_patch, .is_hidden = field.is_hidden, .doc = field.doc });
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
                        const thunk = try arena.create(Thunk);
                        thunk.* = .{
                            .expr = field.value,
                            .env = env,
                            .current_dir = current_dir,
                            .ctx = ctx,
                            .state = .unevaluated,
                            .field_key_location = field.key_location,
                            .self_value = self_cell,
                        };
                        try fields_list.append(arena, .{ .key = key_copy, .value = .{ .thunk = thunk }, .is_patch = field.is_patch, .is_hidden = field.is_hidden, .doc = field.doc });
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
                                    const thunk = try arena.create(Thunk);
                                    thunk.* = .{
                                        .expr = field.value,
                                        .env = env,
                                        .current_dir = current_dir,
                                        .ctx = ctx,
                                        .state = .unevaluated,
                                        .field_key_location = field.key_location,
                                        .self_value = self_cell,
                                    };
                                    try fields_list.append(arena, .{ .key = key_copy, .value = .{ .thunk = thunk }, .is_patch = field.is_patch, .is_hidden = field.is_hidden, .doc = field.doc });
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
    const obj_value = Value{ .object = .{ .fields = fields, .module_doc = object.module_doc } };
    // Fill in the self cell so thunks can access `self`
    self_cell.* = obj_value;
    return obj_value;
}


pub fn evaluateExpression(
    arena: std.mem.Allocator,
    initial_expr: *Expression,
    initial_env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!Value {
    // Trampoline loop for tail call optimization (TCO).
    // Tail positions (let body, where body, if/then/else branches, when branches,
    // assert body, and function application body) update `expr`/`env` and
    // continue the loop instead of recursing, keeping the Zig stack bounded.
    var expr = initial_expr;
    var env = initial_env;
    // Count tail-call function applications to detect infinite loops.
    // Structural tail positions (let, where, if, when) are not counted.
    var tco_call_count: u32 = 0;
    var tco_has_pushed_frame: bool = false;

    // Pop the last TCO stack frame when we exit (success or error via errdefer below).
    defer {
        if (tco_has_pushed_frame) {
            if (ctx.error_ctx) |err_ctx| {
                err_ctx.popStackFrame();
            }
        }
    }

    // Capture the stack trace when this evaluateExpression call exits with an error,
    // if no inner call has already captured it. This preserves the call stack for
    // error reporting even when tail calls eliminate intermediate Zig stack frames.
    errdefer {
        if (ctx.error_ctx) |err_ctx| {
            if (err_ctx.stack_trace == null) {
                err_ctx.captureStackTrace() catch {};
            }
        }
    }

    tco_loop: while (true) {
    switch (expr.data) {
        .integer => |value| return .{ .integer = value },
        .float => |value| return .{ .float = value },
        .boolean => |value| return .{ .boolean = value },
        .null_literal => return .null_value,
        .symbol => |value| return .{ .string = if (value.len > 0 and value[0] == '#') value[1..] else value },
        .identifier => |name| {
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
            return try force(arena, resolved);
        },
        .string_literal => |value| return .{ .string = value },
        .string_interpolation => |interp| {
            var result_str = std.ArrayListUnmanaged(u8){};
            for (interp.parts) |part| {
                switch (part) {
                    .literal => |lit| {
                        try result_str.appendSlice(arena, lit);
                    },
                    .interpolation => |interp_expr| {
                        const interp_value = try evaluateExpression(arena, interp_expr, env, current_dir, ctx);
                        const str_value = try valueToString(arena, interp_value);
                        try result_str.appendSlice(arena, str_value);
                    },
                }
            }
            return .{ .string = try result_str.toOwnedSlice(arena) };
        },
        .lambda => |lambda| {
            const function = try arena.create(FunctionValue);
            function.* = .{ .param = lambda.param, .body = lambda.body, .env = env };
            return Value{ .function = function };
        },
        .let => |let_expr| {
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
                const value = try evaluateExpression(arena, let_expr.value, recursive_env, current_dir, ctx);

                // Propagate doc comment to function values
                if (let_expr.doc) |doc| {
                    switch (value) {
                        .function => |func| {
                            func.doc = doc;
                        },
                        else => {},
                    }
                }

                // Update the environment entry with the actual value
                recursive_env.value = value;

                // TCO: evaluate body in the loop instead of recursing
                expr = let_expr.body;
                env = recursive_env;
                continue;
            } else {
                // Non-recursive case: evaluate value first, then pattern match
                const value = try evaluateExpression(arena, let_expr.value, env, current_dir, ctx);

                // Propagate doc comment to function values
                if (let_expr.doc) |doc| {
                    switch (value) {
                        .function => |func| {
                            func.doc = doc;
                        },
                        else => {},
                    }
                }

                const new_env = try matchPattern(arena, let_expr.pattern, value, env, ctx);
                // TCO: evaluate body in the loop instead of recursing
                expr = let_expr.body;
                env = new_env;
                continue;
            }
        },
        .where_expr => |where_expr| {
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

            // TCO: evaluate the main expression in the loop instead of recursing
            expr = where_expr.expr;
            env = current_env;
            continue;
        },
        .unary => |unary| {
            const operand_value = try evaluateExpression(arena, unary.operand, env, current_dir, ctx);
            return switch (unary.op) {
                .logical_not => blk2: {
                    const bool_val = switch (operand_value) {
                        .boolean => |v| v,
                        else => return error.TypeMismatch,
                    };
                    break :blk2 Value{ .boolean = !bool_val };
                },
            };
        },
        .binary => |binary| return try evaluateBinaryOp(arena, binary, env, current_dir, ctx),
        .if_expr => |if_expr| {
            const condition_value = try evaluateExpression(arena, if_expr.condition, env, current_dir, ctx);
            const condition_bool = switch (condition_value) {
                .boolean => |v| v,
                else => return error.TypeMismatch,
            };

            if (condition_bool) {
                // TCO: evaluate then branch in the loop
                expr = if_expr.then_expr;
                continue;
            } else if (if_expr.else_expr) |else_expr| {
                // TCO: evaluate else branch in the loop
                expr = else_expr;
                continue;
            } else {
                return .null_value;
            }
        },
        .assert_expr => |assert_expr| {
            const condition = try evaluateExpression(arena, assert_expr.condition, env, current_dir, ctx);
            const cond_bool = switch (condition) {
                .boolean => |b| b,
                else => {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorData(.{ .type_mismatch = .{
                            .expected = "boolean",
                            .found = getValueTypeName(condition),
                            .operation = null,
                        } });
                    }
                    return error.TypeMismatch;
                },
            };
            if (!cond_bool) {
                // Evaluate the message expression to get crash message
                const msg_value = try evaluateExpression(arena, assert_expr.message, env, current_dir, ctx);
                const msg_str = switch (msg_value) {
                    .string => |s| s,
                    else => "assertion failed",
                };
                const message_copy = try std.heap.page_allocator.dupe(u8, msg_str);
                value_mod.setUserCrashMessage(message_copy);
                if (ctx.error_ctx) |err_ctx| {
                    err_ctx.setErrorLocation(
                        expr.location.line,
                        expr.location.column,
                        expr.location.offset,
                        expr.location.length,
                    );
                }
                return error.UserCrash;
            }
            // TCO: evaluate body in the loop
            expr = assert_expr.body;
            continue;
        },
        .when_matches => |when_matches| {
            const value = try evaluateExpression(arena, when_matches.value, env, current_dir, ctx);

            // Try each pattern branch
            for (when_matches.branches) |branch| {
                // Try to match the pattern
                const match_env = matchPattern(arena, branch.pattern, value, env, ctx) catch |err| {
                    if (err == error.TypeMismatch) continue;
                    return err;
                };

                // Check optional `and` guard
                if (branch.guard) |guard_expr| {
                    const guard_val = try evaluateExpression(arena, guard_expr, match_env, current_dir, ctx);
                    switch (guard_val) {
                        .boolean => |b| if (!b) continue, // guard failed, try next branch
                        else => return error.TypeMismatch,
                    }
                }

                // TCO: evaluate matched branch expression in the loop
                expr = branch.expression;
                env = match_env;
                continue :tco_loop;
            }

            // No pattern matched, check for otherwise clause
            if (when_matches.otherwise) |otherwise_expr| {
                // TCO: evaluate otherwise in the loop
                expr = otherwise_expr;
                continue;
            }

            // No branch matched and no otherwise clause
            if (ctx.error_ctx) |err_ctx| {
                err_ctx.setErrorLocation(expr.location.line, expr.location.column, expr.location.offset, expr.location.length);
                const val_str = formatValueShort(err_ctx.allocator, value) catch "";
                err_ctx.setErrorData(.{ .when_no_match = .{ .value_str = val_str } });
                err_ctx.captureStackTrace() catch {};
            }
            return error.TypeMismatch;
        },
        .when_predicate => |when_pred| {
            const value = try evaluateExpression(arena, when_pred.value, env, current_dir, ctx);

            // Try each predicate branch
            for (when_pred.branches) |branch| {
                const predicate = try evaluateExpression(arena, branch.predicate, env, current_dir, ctx);

                // Call the predicate with the value
                const pred_result = switch (predicate) {
                    .function => |func| try evaluateExpression(arena, func.body, try matchPattern(arena, func.param, value, func.env, ctx), current_dir, ctx),
                    .native_fn => |native_fn| try native_fn(arena, &[_]Value{value}),
                    else => return error.ExpectedFunction,
                };

                // Check if predicate returned truthy
                const is_match = switch (pred_result) {
                    .boolean => |b| b,
                    else => true, // non-boolean truthy
                };

                if (is_match) {
                    // TCO: evaluate matched branch expression in the loop
                    expr = branch.expression;
                    continue :tco_loop;
                }
            }

            if (when_pred.otherwise) |otherwise_expr| {
                // TCO: evaluate otherwise in the loop
                expr = otherwise_expr;
                continue;
            }

            // No branch matched and no otherwise clause
            if (ctx.error_ctx) |err_ctx| {
                err_ctx.setErrorLocation(expr.location.line, expr.location.column, expr.location.offset, expr.location.length);
                const val_str = formatValueShort(err_ctx.allocator, value) catch "";
                err_ctx.setErrorData(.{ .when_no_match = .{ .value_str = val_str } });
                err_ctx.captureStackTrace() catch {};
            }
            return error.TypeMismatch;
        },
        .application => |application| {
            // Check and increment recursion depth
            if (ctx.recursion_depth.* >= MAX_RECURSION_DEPTH) {
                if (ctx.error_ctx) |err_ctx| {
                    err_ctx.setErrorLocation(application.function.location.line, application.function.location.column, application.function.location.offset, application.function.location.length);
                }
                const msg = std.heap.page_allocator.dupe(u8, "Maximum recursion depth exceeded") catch "Maximum recursion depth exceeded";
                value_mod.setUserCrashMessage(msg);
                return error.UserCrash;
            }
            ctx.recursion_depth.* += 1;

            const function_value = evaluateExpression(arena, application.function, env, current_dir, ctx) catch |err| {
                ctx.recursion_depth.* -= 1;
                return err;
            };
            const argument_value = evaluateExpression(arena, application.argument, env, current_dir, ctx) catch |err| {
                ctx.recursion_depth.* -= 1;
                return err;
            };

            switch (function_value) {
                .function => |function_ptr| {
                    const bound_env = matchPattern(arena, function_ptr.param, argument_value, function_ptr.env, ctx) catch |err| {
                        // If pattern matching fails, update error location to point to the argument
                        if (ctx.error_ctx) |err_ctx| {
                            err_ctx.setErrorLocation(application.argument.location.line, application.argument.location.column, application.argument.location.offset, application.argument.location.length);

                            // If the error is a type mismatch and the function is named, update the operation
                            if (err == error.TypeMismatch) {
                                const function_name = switch (application.function.data) {
                                    .identifier => |name| name,
                                    else => null,
                                };

                                if (function_name) |name| {
                                    if (err_ctx.last_error_data == .type_mismatch) {
                                        const old_data = err_ctx.last_error_data.type_mismatch;
                                        const was_expected_owned = old_data.expected_owned;
                                        const was_found_owned = old_data.found_owned;
                                        if (std.fmt.allocPrint(err_ctx.allocator, "calling function `{s}`", .{name})) |new_operation| {
                                            err_ctx.last_error_data.type_mismatch.expected_owned = false;
                                            err_ctx.last_error_data.type_mismatch.found_owned = false;
                                            err_ctx.setErrorData(.{ .type_mismatch = .{
                                                .expected = old_data.expected,
                                                .found = old_data.found,
                                                .operation = new_operation,
                                                .expected_owned = was_expected_owned,
                                                .found_owned = was_found_owned,
                                            } });
                                        } else |_| {}
                                    }
                                }
                            }
                            err_ctx.captureStackTrace() catch {};
                        }
                        ctx.recursion_depth.* -= 1;
                        return err;
                    };

                    // TCO: instead of recursing into function body, update expr/env and loop.
                    // Decrement depth since the current application "frame" is replaced.
                    ctx.recursion_depth.* -= 1;

                    // Check for infinite tail-call loops. Each function application
                    // via TCO increments this counter; exceeding the limit reports
                    // UserCrash (same as the recursion depth check for non-TCO calls).
                    tco_call_count += 1;
                    if (tco_call_count > MAX_RECURSION_DEPTH * MAX_RECURSION_DEPTH) {
                        if (ctx.error_ctx) |err_ctx| {
                            err_ctx.setErrorLocation(application.function.location.line, application.function.location.column, application.function.location.offset, application.function.location.length);
                        }
                        const msg = std.heap.page_allocator.dupe(u8, "Maximum recursion depth exceeded") catch "Maximum recursion depth exceeded";
                        value_mod.setUserCrashMessage(msg);
                        return error.UserCrash;
                    }

                    // Update the stack frame for this tail call (replace, not push).
                    // Pop the previous frame (if any) and push the new one so error
                    // traces always show the most recent tail-call site.
                    if (ctx.error_ctx) |err_ctx| {
                        if (tco_has_pushed_frame) err_ctx.popStackFrame();
                        const function_name_tco = switch (application.function.data) {
                            .identifier => |name| name,
                            else => null,
                        };
                        const arg_str_tco = formatValueShort(err_ctx.allocator, argument_value) catch null;
                        err_ctx.pushStackFrame(
                            function_name_tco,
                            err_ctx.current_file,
                            application.function.location.line,
                            application.function.location.column,
                            application.function.location.offset,
                            application.function.location.length,
                            false,
                            arg_str_tco,
                        ) catch {
                            if (arg_str_tco) |s| err_ctx.allocator.free(s);
                        };
                        tco_has_pushed_frame = true;
                    }

                    expr = function_ptr.body;
                    env = bound_env;
                    continue;
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
                            null,
                        ) catch {};
                    }

                    const args = [_]Value{argument_value};
                    const native_result = native_fn(arena, &args) catch |err| {
                        if (ctx.error_ctx) |err_ctx| {
                            if (err_ctx.stack_trace == null) {
                                err_ctx.captureStackTrace() catch {};
                            }
                            err_ctx.popStackFrame();
                        }
                        ctx.recursion_depth.* -= 1;
                        return err;
                    };

                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.popStackFrame();
                    }
                    ctx.recursion_depth.* -= 1;
                    return native_result;
                },
                else => |bad_value| {
                    if (ctx.error_ctx) |err_ctx| {
                        err_ctx.setErrorLocation(application.function.location.line, application.function.location.column, application.function.location.offset, application.function.location.length);
                        // Detect curried-too-many-args: if the function expr is itself an application,
                        // walk up to find the root function name
                        const orig_func: ?[]const u8 = if (application.function.data == .application) blk_orig: {
                            var func_expr = application.function;
                            while (func_expr.data == .application) {
                                func_expr = func_expr.data.application.function;
                            }
                            if (func_expr.data == .identifier) {
                                break :blk_orig err_ctx.allocator.dupe(u8, func_expr.data.identifier) catch null;
                            }
                            break :blk_orig null;
                        } else null;
                        err_ctx.setErrorData(.{ .not_a_function = .{
                            .value_type = getValueTypeName(bad_value),
                            .original_function = orig_func,
                        } });
                        err_ctx.captureStackTrace() catch {};
                    }
                    ctx.recursion_depth.* -= 1;
                    return error.ExpectedFunction;
                },
            }
        },
        .array => |array| {
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

            return Value{ .array = .{ .elements = try temp_values.toOwnedSlice(arena) } };
        },
        .tuple => |tuple| {
            const values = try arena.alloc(Value, tuple.elements.len);
            for (tuple.elements, 0..) |element, i| {
                values[i] = try evaluateExpression(arena, element, env, current_dir, ctx);
            }
            return Value{ .tuple = .{ .elements = values } };
        },
        .range => |range| {
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

            return Value{ .range = .{ .start = start_int, .end = end_int, .inclusive = range.inclusive } };
        },
        .object => |object| return try evaluateObjectLiteral(arena, object, env, current_dir, ctx),
        .object_extend => |extend| {
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
                        try fields_list.append(arena, .{ .key = key_copy, .value = try evaluateExpression(arena, field.value, env, current_dir, ctx), .is_patch = field.is_patch, .is_hidden = field.is_hidden });
                    }
                    const obj_arg = Value{ .object = .{ .fields = try fields_list.toOwnedSlice(arena), .module_doc = null } };
                    const bound_env = try matchPattern(arena, function_ptr.param, obj_arg, function_ptr.env, ctx);
                    return try evaluateExpression(arena, function_ptr.body, bound_env, current_dir, ctx);
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
                        try fields_list.append(arena, .{ .key = key_copy, .value = try evaluateExpression(arena, field.value, env, current_dir, ctx), .is_patch = field.is_patch, .is_hidden = field.is_hidden });
                    }
                    const obj_arg = Value{ .object = .{ .fields = try fields_list.toOwnedSlice(arena), .module_doc = null } };
                    const args = [_]Value{obj_arg};
                    return try native_fn(arena, &args);
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
                            const existing_value: ?Value = for (base_obj.fields) |bf| {
                                if (std.mem.eql(u8, bf.key, static_key)) break bf.value;
                            } else null;
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
                                try extension_fields.append(arena, .{ .key = key_copy, .value = merged, .is_patch = false, .doc = field.doc });
                            } else {
                                // Field doesn't exist in base, just add it
                                try extension_fields.append(arena, .{ .key = key_copy, .value = value, .is_patch = field.is_patch, .is_hidden = field.is_hidden, .doc = field.doc });
                            }
                        } else {
                            // Overwrite: just use the new value
                            try extension_fields.append(arena, .{ .key = key_copy, .value = value, .is_patch = field.is_patch, .is_hidden = field.is_hidden, .doc = field.doc });
                        }
                    }

                    // Merge base with extension
                    const extension_obj = ObjectValue{ .fields = try extension_fields.toOwnedSlice(arena), .module_doc = null };
                    return try mergeObjects(arena, base_obj, extension_obj);
                },
                else => return error.TypeMismatch,
            }
        },
        .array_comprehension => |comp| {
            var result_list = std.ArrayListUnmanaged(Value){};
            try evaluateArrayComprehension(arena, &result_list, comp, 0, env, current_dir, ctx);
            return Value{ .array = .{ .elements = try result_list.toOwnedSlice(arena) } };
        },
        .object_comprehension => |comp| {
            var result_fields = std.ArrayListUnmanaged(ObjectFieldValue){};
            try evaluateObjectComprehension(arena, &result_fields, comp, 0, env, current_dir, ctx);
            return Value{ .object = .{ .fields = try result_fields.toOwnedSlice(arena), .module_doc = null } };
        },
        .import_expr => |import_expr| return try importModule(arena, import_expr.path, current_dir, ctx),
        .field_access => |field_access| {
            const object_value = try evaluateExpression(arena, field_access.object, env, current_dir, ctx);
            const forced = try force(arena, object_value);
            return try accessField(arena, forced, field_access.field, field_access.field_location, field_access.object, ctx);
        },
        .index => |index| {
            const object_value = try evaluateExpression(arena, index.object, env, current_dir, ctx);
            const forced_object = try force(arena, object_value);
            const index_value = try evaluateExpression(arena, index.index, env, current_dir, ctx);
            const forced_index = try force(arena, index_value);

            return switch (forced_object) {
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
        .field_accessor => |field_accessor| {
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
            };

            return Value{ .function = func_value };
        },
        .operator_function => |op| {
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
            };

            return Value{ .function = outer_func };
        },
        .field_projection => |field_projection| {
            const object_value = try evaluateExpression(arena, field_projection.object, env, current_dir, ctx);

            // Verify it's an object
            _ = switch (object_value) {
                .object => |obj| obj,
                else => return error.TypeMismatch,
            };

            // Create new object with only the specified fields
            const new_fields = try arena.alloc(ObjectFieldValue, field_projection.fields.len);
            for (field_projection.fields, 0..) |field_name, i| {
                const field_value = try accessField(arena, object_value, field_name, expr.location, null, ctx);
                new_fields[i] = .{
                    .key = try arena.dupe(u8, field_name),
                    .value = field_value,
                    .is_patch = false,
                };
            }

            return Value{ .object = .{ .fields = new_fields, .module_doc = null } };
        },
    }
    } // end tco_loop
}

fn accessField(arena: std.mem.Allocator, object_value: Value, field_name: []const u8, location: SourceLocation, object_expr: ?*Expression, ctx: *const EvalContext) EvalError!Value {
    const object = switch (object_value) {
        .object => |obj| obj,
        else => {
            // Set error location and data before returning TypeMismatch
            if (ctx.error_ctx) |err_ctx| {
                err_ctx.setErrorLocation(location.line, location.column, location.offset, location.length);
                err_ctx.setErrorData(.{ .type_mismatch = .{
                    .expected = "object",
                    .found = getValueTypeName(object_value),
                    .operation = "field access",
                } });
                err_ctx.captureStackTrace() catch {};
            }
            return error.TypeMismatch;
        },
    };

    // Look for the field
    for (object.fields) |field| {
        if (std.mem.eql(u8, field.key, field_name)) {
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

        // Build access chain from the AST expression (e.g., "config.server")
        const access_chain = if (object_expr) |expr| buildAccessChain(err_ctx.allocator, expr) else null;

        err_ctx.setErrorData(.{
            .unknown_field = .{
                .field_name = field_name_copy,
                .available_fields = available,
                .access_chain = access_chain,
            },
        });
    }

    return error.UnknownField;
}

/// Build a dotted access chain string from an expression tree.
/// For example, if the expression is `config.server`, returns "config.server".
fn buildAccessChain(allocator: std.mem.Allocator, expr: *Expression) ?[]const u8 {
    // Collect field names by walking the chain
    var parts: [16][]const u8 = undefined;
    var count: usize = 0;
    var current = expr;

    while (true) {
        switch (current.data) {
            .field_access => |fa| {
                if (count >= parts.len) return null;
                parts[count] = fa.field;
                count += 1;
                current = fa.object;
            },
            .identifier => |ident| {
                if (count >= parts.len) return null;
                parts[count] = ident;
                count += 1;
                break;
            },
            else => break,
        }
    }

    if (count == 0) return null;

    // Calculate total length
    var total_len: usize = 0;
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        total_len += parts[i].len;
        if (i > 0) total_len += 1; // for '.'
    }

    const result = allocator.alloc(u8, total_len) catch return null;
    var pos: usize = 0;
    i = count;
    while (i > 0) {
        i -= 1;
        @memcpy(result[pos .. pos + parts[i].len], parts[i]);
        pos += parts[i].len;
        if (i > 0) {
            result[pos] = '.';
            pos += 1;
        }
    }

    return result;
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
    // First resolve the path without opening the file
    const resolved_path = try module_resolver.resolveImportPath(ctx, import_path, current_dir);
    defer ctx.allocator.free(resolved_path);

    // Check module cache BEFORE opening the file
    if (ctx.module_cache) |cache| {
        if (cache.get(resolved_path)) |cached_value| {
            return cached_value;
        }
    }

    // Check for circular imports before opening the file
    if (ctx.import_stack) |stack| {
        if (stack.contains(resolved_path)) {
            const msg = std.fmt.allocPrint(std.heap.page_allocator, "Circular import detected: {s}", .{resolved_path}) catch "Circular import detected";
            value_mod.setUserCrashMessage(msg);
            return error.UserCrash;
        }
        // Mark this module as being imported; defer cleanup so it runs on all paths (including errors)
        const path_copy = try ctx.allocator.dupe(u8, resolved_path);
        try stack.put(path_copy, {});
    }
    defer if (ctx.import_stack) |stack| {
        if (stack.fetchRemove(resolved_path)) |entry| {
            ctx.allocator.free(entry.key);
        }
    };

    // Open the file only after cache miss and circular-import check
    var file = try std.fs.cwd().openFile(resolved_path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(arena, std.math.maxInt(usize));

    // Save the current file so we can restore it after import
    // Make an owned copy since setCurrentFile will free the old current_file
    var saved_file: ?[]const u8 = null;
    if (ctx.error_ctx) |err_ctx| {
        if (err_ctx.current_file.len > 0) {
            saved_file = try ctx.allocator.dupe(u8, err_ctx.current_file);
        }
    }
    defer if (saved_file) |f| ctx.allocator.free(f);

    var parser = try Parser.init(arena, contents);
    if (ctx.error_ctx) |err_ctx| {
        err_ctx.setCurrentFile(resolved_path);
        parser.setErrorContext(err_ctx);
    }
    const expression = parser.parse() catch |err| {
        // Only register source on parse error
        if (ctx.error_ctx) |err_ctx| {
            err_ctx.registerSource(resolved_path, contents) catch {};
            // Restore the previous file - important to update BOTH current_file and source_filename
            // because source_filename may have been set during error reporting
            if (saved_file) |sf| {
                err_ctx.setCurrentFile(sf);
                // Also restore source_filename if it was set to the module file
                if (err_ctx.source_filename_owned and err_ctx.source_filename.len > 0) {
                    err_ctx.allocator.free(err_ctx.source_filename);
                }
                if (err_ctx.allocator.dupe(u8, sf)) |owned| {
                    err_ctx.source_filename = owned;
                    err_ctx.source_filename_owned = true;
                } else |_| {
                    err_ctx.source_filename = sf;
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
    const module_dir = std.fs.path.dirname(resolved_path);
    const result = evaluateExpression(arena, expression, env, module_dir, ctx) catch |err| {
        // Only register source on evaluation error
        if (ctx.error_ctx) |err_ctx| {
            err_ctx.registerSource(resolved_path, contents) catch {};
            // Restore the previous file - important to update BOTH current_file and source_filename
            if (saved_file) |sf| {
                err_ctx.setCurrentFile(sf);
                // Also restore source_filename if it was set to the module file
                if (err_ctx.source_filename_owned and err_ctx.source_filename.len > 0) {
                    err_ctx.allocator.free(err_ctx.source_filename);
                }
                if (err_ctx.allocator.dupe(u8, sf)) |owned| {
                    err_ctx.source_filename = owned;
                    err_ctx.source_filename_owned = true;
                } else |_| {
                    err_ctx.source_filename = sf;
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
        if (saved_file) |sf| {
            err_ctx.setCurrentFile(sf);
        } else {
            err_ctx.setCurrentFile("");
        }
    }

    // Cache the result (import stack cleanup handled by defer above)
    if (ctx.module_cache) |cache| {
        const cache_key = try ctx.allocator.dupe(u8, resolved_path);
        errdefer ctx.allocator.free(cache_key);
        try cache.put(cache_key, result);
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

    // Basics must be loaded eagerly because its fields are spread into
    // the environment as unqualified names (isString, toString, crash, etc.)
    const basics_value = importModule(arena, "Basics", current_dir, ctx) catch |err| {
        if (err == error.ModuleNotFound) return env;
        return err;
    };
    const basics_obj = switch (basics_value) {
        .object => |obj| obj,
        else => return error.TypeMismatch,
    };
    // Use a bulk hash map node for Basics fields to avoid 13+ individual chain nodes
    const basics_map = try arena.create(std.StringHashMapUnmanaged(Value));
    basics_map.* = .{};
    for (basics_obj.fields) |field| {
        const field_value = try force(arena, field.value);
        try basics_map.put(arena, field.key, field_value);
    }
    const basics_env = try arena.create(Environment);
    basics_env.* = .{
        .parent = env,
        .name = "Basics",
        .value = basics_value,
        .siblings = basics_map,
    };
    env = basics_env;

    // Other stdlib modules are lazy-loaded: we create thunks with synthetic
    // import expressions so the module is only parsed and evaluated on first access.
    const lazy_modules = [_][]const u8{ "Array", "Float", "Math", "Object", "Range", "Result", "String", "Tuple" };
    for (lazy_modules) |module_name| {
        const import_expr = try arena.create(Expression);
        import_expr.* = .{
            .data = .{ .import_expr = .{
                .path = module_name,
                .path_location = .{ .line = 0, .column = 0, .offset = 0, .length = 0 },
            } },
            .location = .{ .line = 0, .column = 0, .offset = 0, .length = 0 },
        };

        const thunk = try arena.create(value_mod.Thunk);
        thunk.* = .{
            .expr = import_expr,
            .env = env,
            .current_dir = current_dir,
            .ctx = ctx,
            .state = .unevaluated,
            .field_key_location = null,
        };

        const new_env = try arena.create(Environment);
        new_env.* = .{
            .parent = env,
            .name = module_name,
            .value = .{ .thunk = thunk },
        };
        env = new_env;
    }

    // Strip the Builtins binding from the user-visible environment.
    // Stdlib closures already captured Builtins in their defining environments,
    // so they still work — but user code cannot access Builtins directly.
    env = try stripBinding(arena, env, "Builtins");

    return env;
}

/// Rebuild an environment chain, skipping a specific named binding.
fn stripBinding(arena: std.mem.Allocator, env: ?*Environment, name_to_strip: []const u8) !?*Environment {
    if (env == null) return null;

    const Binding = struct { name: []const u8, value: Value, siblings: ?*std.StringHashMapUnmanaged(Value) };
    var bindings = std.ArrayList(Binding){};
    defer bindings.deinit(arena);

    var current = env;
    while (current) |node| {
        if (!std.mem.eql(u8, node.name, name_to_strip)) {
            try bindings.append(arena, .{ .name = node.name, .value = node.value, .siblings = node.siblings });
        }
        current = node.parent;
    }

    var new_env: ?*Environment = null;
    var i = bindings.items.len;
    while (i > 0) {
        i -= 1;
        const binding = bindings.items[i];
        const node = try arena.create(Environment);
        node.* = .{
            .parent = new_env,
            .name = binding.name,
            .value = binding.value,
            .siblings = binding.siblings,
        };
        new_env = node;
    }

    return new_env;
}

// Helper functions for error reporting

fn getValueTypeName(value: Value) []const u8 {
    return switch (value) {
        .integer => "integer",
        .float => "float",
        .boolean => "boolean",
        .null_value => "null",
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
        .symbol => "string",
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
        .symbol => |s| blk: {
            const name = if (s.len > 0 and s[0] == '#') s[1..] else s;
            break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{name});
        },
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
