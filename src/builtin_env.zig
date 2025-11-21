//! Builtin environment setup for Lazylang.
//!
//! This module creates the initial environment with all builtin (native) functions
//! available to Lazylang programs. Builtin functions are implemented in Zig and
//! exposed through the evaluator.
//!
//! Function categories:
//! - Array operations: length, get, reverse, fold, concat, slice, sort, uniq, range, rangeExclusive
//! - String operations: length, concat, split, case conversion, trim, search, replace, join
//! - Math operations: max, min, abs, pow, sqrt, floor, ceil, round, log, exp, mod, rem
//! - Object operations: keys, values, get
//! - Float operations: round, floor, ceil, abs, sqrt, pow
//! - YAML/JSON: parse, encode
//! - Error handling: crash
//!
//! All builtin functions are prefixed with `__` except for `crash` which is
//! directly exposed. The actual implementations are in builtins.zig, and this
//! module simply registers them in the environment.

const std = @import("std");
const builtins = @import("builtins.zig");

// Import types from eval.zig
// Note: This creates a circular dependency, but it's acceptable since we're only
// using types, not calling functions from eval.zig
const eval = @import("eval.zig");
const Environment = eval.Environment;
const NativeFn = eval.NativeFn;

/// Creates the initial builtin environment with all native functions registered.
/// Returns null if allocation fails.
pub fn createBuiltinEnvironment(arena: std.mem.Allocator) !?*Environment {
    var env: ?*Environment = null;

    // Array builtins
    env = try addBuiltin(arena, env, "__array_length", builtins.arrayLength);
    env = try addBuiltin(arena, env, "__array_get", builtins.arrayGet);
    env = try addBuiltin(arena, env, "__array_reverse", builtins.arrayReverse);
    env = try addBuiltin(arena, env, "__array_fold", builtins.arrayFold);
    env = try addBuiltin(arena, env, "__array_concat_all", builtins.arrayConcatAll);
    env = try addBuiltin(arena, env, "__array_slice", builtins.arraySlice);
    env = try addBuiltin(arena, env, "__array_sort", builtins.arraySort);
    env = try addBuiltin(arena, env, "__array_uniq", builtins.arrayUniq);

    // Range builtins
    env = try addBuiltin(arena, env, "__range_inclusive", builtins.rangeInclusive);
    env = try addBuiltin(arena, env, "__range_exclusive", builtins.rangeExclusive);
    env = try addBuiltin(arena, env, "__range_to_array", builtins.rangeToArray);
    env = try addBuiltin(arena, env, "__range_covers", builtins.rangeCovers);

    // String builtins
    env = try addBuiltin(arena, env, "__string_length", builtins.stringLength);
    env = try addBuiltin(arena, env, "__string_concat", builtins.stringConcat);
    env = try addBuiltin(arena, env, "__string_split", builtins.stringSplit);
    env = try addBuiltin(arena, env, "__string_to_upper", builtins.stringToUpper);
    env = try addBuiltin(arena, env, "__string_to_lower", builtins.stringToLower);
    env = try addBuiltin(arena, env, "__string_chars", builtins.stringChars);
    env = try addBuiltin(arena, env, "__string_trim", builtins.stringTrim);
    env = try addBuiltin(arena, env, "__string_starts_with", builtins.stringStartsWith);
    env = try addBuiltin(arena, env, "__string_ends_with", builtins.stringEndsWith);
    env = try addBuiltin(arena, env, "__string_contains", builtins.stringContains);
    env = try addBuiltin(arena, env, "__string_repeat", builtins.stringRepeat);
    env = try addBuiltin(arena, env, "__string_replace", builtins.stringReplace);
    env = try addBuiltin(arena, env, "__string_slice", builtins.stringSlice);
    env = try addBuiltin(arena, env, "__string_join", builtins.stringJoin);

    // Math builtins
    env = try addBuiltin(arena, env, "__math_max", builtins.mathMax);
    env = try addBuiltin(arena, env, "__math_min", builtins.mathMin);
    env = try addBuiltin(arena, env, "__math_abs", builtins.mathAbs);
    env = try addBuiltin(arena, env, "__math_pow", builtins.mathPow);
    env = try addBuiltin(arena, env, "__math_sqrt", builtins.mathSqrt);
    env = try addBuiltin(arena, env, "__math_floor", builtins.mathFloor);
    env = try addBuiltin(arena, env, "__math_ceil", builtins.mathCeil);
    env = try addBuiltin(arena, env, "__math_round", builtins.mathRound);
    env = try addBuiltin(arena, env, "__math_log", builtins.mathLog);
    env = try addBuiltin(arena, env, "__math_exp", builtins.mathExp);

    // Object builtins
    env = try addBuiltin(arena, env, "__object_keys", builtins.objectKeys);
    env = try addBuiltin(arena, env, "__object_values", builtins.objectValues);
    env = try addBuiltin(arena, env, "__object_get", builtins.objectGet);

    // Error handling builtins
    env = try addBuiltin(arena, env, "crash", builtins.crash);

    // YAML builtins
    env = try addBuiltin(arena, env, "__yaml_parse", builtins.yamlParse);
    env = try addBuiltin(arena, env, "__yaml_encode", builtins.yamlEncode);

    // JSON builtins
    env = try addBuiltin(arena, env, "__json_parse", builtins.jsonParse);
    env = try addBuiltin(arena, env, "__json_encode", builtins.jsonEncode);

    // Float builtins
    env = try addBuiltin(arena, env, "__float_round", builtins.floatRound);
    env = try addBuiltin(arena, env, "__float_floor", builtins.floatFloor);
    env = try addBuiltin(arena, env, "__float_ceil", builtins.floatCeil);
    env = try addBuiltin(arena, env, "__float_abs", builtins.floatAbs);
    env = try addBuiltin(arena, env, "__float_sqrt", builtins.floatSqrt);
    env = try addBuiltin(arena, env, "__float_pow", builtins.floatPow);
    env = try addBuiltin(arena, env, "__math_mod", builtins.mathMod);
    env = try addBuiltin(arena, env, "__math_rem", builtins.mathRem);

    // Type predicate builtins
    env = try addBuiltin(arena, env, "__is_integer", builtins.isInteger);
    env = try addBuiltin(arena, env, "__is_float", builtins.isFloat);
    env = try addBuiltin(arena, env, "__is_boolean", builtins.isBoolean);
    env = try addBuiltin(arena, env, "__is_null", builtins.isNull);
    env = try addBuiltin(arena, env, "__is_symbol", builtins.isSymbol);
    env = try addBuiltin(arena, env, "__is_string", builtins.isString);
    env = try addBuiltin(arena, env, "__is_array", builtins.isArray);
    env = try addBuiltin(arena, env, "__is_tuple", builtins.isTuple);
    env = try addBuiltin(arena, env, "__is_object", builtins.isObject);
    env = try addBuiltin(arena, env, "__is_function", builtins.isFunction);

    // Reflection builtins
    env = try addBuiltin(arena, env, "__docstring", builtins.docstring);

    return env;
}

/// Helper function to add a builtin function to the environment.
/// Creates a new environment node with the function as a native_fn value.
fn addBuiltin(arena: std.mem.Allocator, parent: ?*Environment, name: []const u8, function: NativeFn) !?*Environment {
    const env = try arena.create(Environment);
    env.* = .{
        .parent = parent,
        .name = name,
        .value = .{ .native_fn = function },
    };
    return env;
}
