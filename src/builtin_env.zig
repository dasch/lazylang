//! Builtin environment setup for Lazylang.
//!
//! This module creates the initial environment with native functions
//! exposed as a `Builtins` object. Stdlib modules access builtins via
//! `Builtins.array_length`, `Builtins.string_split`, etc.
//!
//! The `Builtins` binding is stripped from the user-visible environment
//! after stdlib modules are loaded, so user code cannot access native
//! functions directly — only through the stdlib wrappers.

const std = @import("std");
const builtins = @import("builtins.zig");

const eval = @import("eval.zig");
const Environment = eval.Environment;
const NativeFn = eval.NativeFn;
const Value = eval.Value;
const ObjectFieldValue = eval.ObjectFieldValue;

const BuiltinEntry = struct {
    name: []const u8,
    function: NativeFn,
};

const builtin_entries = [_]BuiltinEntry{
    // Array
    .{ .name = "array_length", .function = builtins.arrayLength },
    .{ .name = "array_get", .function = builtins.arrayGet },
    .{ .name = "array_reverse", .function = builtins.arrayReverse },
    .{ .name = "array_fold", .function = builtins.arrayFold },
    .{ .name = "array_slice", .function = builtins.arraySlice },
    .{ .name = "array_sort", .function = builtins.arraySort },
    .{ .name = "array_uniq", .function = builtins.arrayUniq },

    // Range
    .{ .name = "range_inclusive", .function = builtins.rangeInclusive },
    .{ .name = "range_exclusive", .function = builtins.rangeExclusive },
    .{ .name = "range_to_array", .function = builtins.rangeToArray },
    .{ .name = "range_covers", .function = builtins.rangeCovers },

    // String
    .{ .name = "string_length", .function = builtins.stringLength },
    .{ .name = "string_concat", .function = builtins.stringConcat },
    .{ .name = "string_concat_all", .function = builtins.stringConcatAll },
    .{ .name = "string_split", .function = builtins.stringSplit },
    .{ .name = "string_to_upper", .function = builtins.stringToUpper },
    .{ .name = "string_to_lower", .function = builtins.stringToLower },
    .{ .name = "string_chars", .function = builtins.stringChars },
    .{ .name = "string_trim", .function = builtins.stringTrim },
    .{ .name = "string_starts_with", .function = builtins.stringStartsWith },
    .{ .name = "string_ends_with", .function = builtins.stringEndsWith },
    .{ .name = "string_contains", .function = builtins.stringContains },
    .{ .name = "string_repeat", .function = builtins.stringRepeat },
    .{ .name = "string_replace", .function = builtins.stringReplace },
    .{ .name = "string_slice", .function = builtins.stringSlice },
    .{ .name = "string_join", .function = builtins.stringJoin },

    // Math
    .{ .name = "math_max", .function = builtins.mathMax },
    .{ .name = "math_min", .function = builtins.mathMin },
    .{ .name = "math_abs", .function = builtins.mathAbs },
    .{ .name = "math_pow", .function = builtins.mathPow },
    .{ .name = "math_sqrt", .function = builtins.mathSqrt },
    .{ .name = "math_floor", .function = builtins.mathFloor },
    .{ .name = "math_ceil", .function = builtins.mathCeil },
    .{ .name = "math_round", .function = builtins.mathRound },
    .{ .name = "math_log", .function = builtins.mathLog },
    .{ .name = "math_exp", .function = builtins.mathExp },
    .{ .name = "math_mod", .function = builtins.mathMod },
    .{ .name = "math_rem", .function = builtins.mathRem },

    // Object
    .{ .name = "object_keys", .function = builtins.objectKeys },
    .{ .name = "object_values", .function = builtins.objectValues },
    .{ .name = "object_get", .function = builtins.objectGet },

    // Bitwise
    .{ .name = "bitwise_xor", .function = builtins.bitwiseXor },
    .{ .name = "bitwise_shl", .function = builtins.bitwiseShl },
    .{ .name = "bitwise_shr", .function = builtins.bitwiseShr },
    .{ .name = "bitwise_and", .function = builtins.bitwiseAnd },

    // Error handling
    .{ .name = "crash", .function = builtins.crash },

    // Conversion
    .{ .name = "to_string", .function = builtins.toString },

    // YAML
    .{ .name = "yaml_parse", .function = builtins.yamlParse },
    .{ .name = "yaml_encode", .function = builtins.yamlEncode },

    // JSON
    .{ .name = "json_parse", .function = builtins.jsonParse },
    .{ .name = "json_encode", .function = builtins.jsonEncode },

    // Float
    .{ .name = "float_round", .function = builtins.floatRound },
    .{ .name = "float_floor", .function = builtins.floatFloor },
    .{ .name = "float_ceil", .function = builtins.floatCeil },
    .{ .name = "float_abs", .function = builtins.floatAbs },
    .{ .name = "float_sqrt", .function = builtins.floatSqrt },
    .{ .name = "float_pow", .function = builtins.floatPow },

    // Type predicates
    .{ .name = "is_integer", .function = builtins.isInteger },
    .{ .name = "is_float", .function = builtins.isFloat },
    .{ .name = "is_boolean", .function = builtins.isBoolean },
    .{ .name = "is_null", .function = builtins.isNull },
    .{ .name = "is_symbol", .function = builtins.isSymbol },
    .{ .name = "is_string", .function = builtins.isString },
    .{ .name = "is_array", .function = builtins.isArray },
    .{ .name = "is_tuple", .function = builtins.isTuple },
    .{ .name = "is_object", .function = builtins.isObject },
    .{ .name = "is_function", .function = builtins.isFunction },

    // Tuple
    .{ .name = "tuple_length", .function = builtins.tupleLength },
    .{ .name = "tuple_to_array", .function = builtins.tupleToArray },
    .{ .name = "tuple_from_array", .function = builtins.tupleFromArray },
};

/// Creates the initial builtin environment with a single `Builtins` object
/// containing all native functions as fields.
pub fn createBuiltinEnvironment(arena: std.mem.Allocator) !?*Environment {
    // Build the Builtins object fields
    const fields = try arena.alloc(ObjectFieldValue, builtin_entries.len);
    for (builtin_entries, 0..) |entry, i| {
        fields[i] = .{
            .key = entry.name,
            .value = .{ .native_fn = entry.function },
            .is_patch = false,
        };
    }

    const builtins_value = Value{ .object = .{ .fields = fields, .module_doc = null } };

    const env = try arena.create(Environment);
    env.* = .{
        .parent = null,
        .name = "Builtins",
        .value = builtins_value,
    };

    return env;
}
