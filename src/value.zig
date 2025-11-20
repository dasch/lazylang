// Runtime value types for Lazylang evaluation.
//
//! This module defines the runtime value representation used during evaluation:
//!
//! - Value: Tagged union representing all possible runtime values
//! - Environment: Lexical scope chain for variable bindings
//! - Thunk: Lazy evaluation wrapper with cycle detection
//! - Supporting types: FunctionValue, ArrayValue, TupleValue, ObjectValue
//!
//! Values are created during evaluation and can be:
//! - Primitives: integers, floats, booleans, null, symbols, strings
//! - Collections: arrays, tuples, objects
//! - Callables: functions (closures) and native functions
//! - Thunks: unevaluated expressions for lazy evaluation

const std = @import("std");
const ast = @import("ast.zig");
const error_reporter = @import("error_reporter.zig");
const error_context = @import("error_context.zig");
const parser_mod = @import("parser.zig");

// Re-export AST types needed by Value
pub const Expression = ast.Expression;
pub const Pattern = ast.Pattern;

// Re-export parser error type needed by EvalError
pub const ParseError = parser_mod.ParseError;

/// Thread-local storage for user crash messages from the crash() builtin.
/// This is stored outside the arena so it survives arena deallocation.
threadlocal var user_crash_message: ?[]const u8 = null;

pub fn setUserCrashMessage(message: []const u8) void {
    user_crash_message = message;
}

pub fn getUserCrashMessage() ?[]const u8 {
    return user_crash_message;
}

pub fn clearUserCrashMessage() void {
    if (user_crash_message) |msg| {
        std.heap.page_allocator.free(msg);
    }
    user_crash_message = null;
}

/// Environment represents a single binding in the lexical scope chain.
/// Environments form an immutable linked list (parent pointer).
pub const Environment = struct {
    parent: ?*Environment,
    name: []const u8,
    value: Value,
};

/// FunctionValue represents a user-defined function (closure).
/// It captures its lexical environment at definition time.
pub const FunctionValue = struct {
    param: *Pattern,
    body: *Expression,
    env: ?*Environment,
};

/// NativeFn is a Zig function that implements a builtin.
/// All builtins follow this signature.
pub const NativeFn = *const fn (arena: std.mem.Allocator, args: []const Value) EvalError!Value;

/// ThunkState tracks the evaluation state of a thunk for lazy evaluation.
/// The evaluating state enables cycle detection.
pub const ThunkState = union(enum) {
    unevaluated,
    evaluating, // For cycle detection
    evaluated: Value,
};

/// Thunk represents an unevaluated expression for lazy evaluation.
/// Used primarily for object fields to enable recursive definitions.
pub const Thunk = struct {
    expr: *Expression,
    env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
    state: ThunkState,
    field_key_location: ?error_reporter.SourceLocation, // For object field thunks, to show cyclic reference span
};

/// Value is the runtime representation of all Lazylang values.
/// This is a tagged union representing all possible value types.
pub const Value = union(enum) {
    integer: i64,
    float: f64,
    boolean: bool,
    null_value,
    symbol: []const u8,
    function: *FunctionValue,
    native_fn: NativeFn,
    array: ArrayValue,
    tuple: TupleValue,
    object: ObjectValue,
    string: []const u8,
    thunk: *Thunk,
    range: RangeValue,
};

/// ArrayValue represents a homogeneous array of values.
pub const ArrayValue = struct {
    elements: []Value,
};

/// TupleValue represents a fixed-size heterogeneous collection.
pub const TupleValue = struct {
    elements: []Value,
};

/// RangeValue represents an integer range for efficient iteration.
/// Ranges can be inclusive (1..5) or exclusive (1...5).
pub const RangeValue = struct {
    start: i64,
    end: i64,
    inclusive: bool,
};

/// ObjectFieldValue represents a single field in an object.
/// The is_patch flag indicates whether this field should be deep-merged.
pub const ObjectFieldValue = struct {
    key: []const u8,
    value: Value,
    is_patch: bool, // true if field should be deep-merged (written as `field { ... }` without colon)
};

/// ObjectValue represents a collection of key-value pairs.
/// Objects can have module-level documentation.
pub const ObjectValue = struct {
    fields: []ObjectFieldValue,
    module_doc: ?[]const u8, // Module-level documentation
};

/// EvalError encompasses all possible errors during evaluation.
/// Includes parse errors, allocation errors, I/O errors, and runtime errors.
pub const EvalError = ParseError || std.mem.Allocator.Error || std.process.GetEnvVarOwnedError || std.fs.File.OpenError || std.fs.File.ReadError || error{
    UnknownIdentifier,
    TypeMismatch,
    ExpectedFunction,
    ModuleNotFound,
    Overflow,
    FileTooBig,
    WrongNumberOfArguments,
    InvalidArgument,
    UnknownField,
    UserCrash,
    CyclicReference,
    DivisionByZero,
    IndexOutOfBounds,
    FieldNotFound,
};

/// EvalContext holds global evaluation state and configuration.
/// Passed through the evaluation process.
pub const EvalContext = struct {
    allocator: std.mem.Allocator,
    lazy_paths: [][]const u8,
    error_ctx: ?*error_context.ErrorContext = null,
};
