//! Core evaluation engine for Lazylang.
//!
//! This module serves as the main entry point for parsing and evaluating Lazylang code.
//! It re-exports modularized components while maintaining backward compatibility:
//!
//! Architecture:
//! - Imports and re-exports AST types from ast.zig
//! - Imports and re-exports Tokenizer from tokenizer.zig
//! - Imports and re-exports Parser from parser.zig
//! - Imports builtin environment setup from builtin_env.zig
//! - Contains Evaluator: Tree-walking interpreter with pattern matching
//! - Contains Value types: Runtime value representation (Value, Environment, Thunk)
//! - Contains module system: Import resolution and module loading
//! - Contains value formatting: JSON, YAML, and pretty-print output
//!
//! Key features:
//! - Pure functional semantics with lazy evaluation
//! - Pattern matching and destructuring
//! - Object merging with patch fields (field vs field:)
//! - Array/object comprehensions
//! - Module imports with LAZYLANG_PATH resolution
//!
//! Public API:
//! - evalInline/evalFile: Parse and evaluate code
//! - Parser.init: Create parser from source
//! - evaluateExpression: Evaluate AST nodes
//!
//! See REFACTORING.md for details on ongoing modularization.

const std = @import("std");
const error_reporter = @import("error_reporter.zig");
const error_context = @import("error_context.zig");
const ast = @import("ast.zig");
const tokenizer_mod = @import("tokenizer.zig");
const parser_mod = @import("parser.zig");
const builtin_env = @import("builtin_env.zig");
const value_format = @import("value_format.zig");
const value_mod = @import("value.zig");
const module_resolver = @import("module_resolver.zig");
const evaluator = @import("evaluator.zig");

// Re-export error_context for use by other modules
pub const ErrorContext = error_context.ErrorContext;
pub const ErrorData = error_context.ErrorData;

// Re-export tokenizer types
pub const Tokenizer = tokenizer_mod.Tokenizer;
pub const TokenizerError = tokenizer_mod.TokenizerError;

// Re-export parser types
pub const Parser = parser_mod.Parser;
pub const ParseError = parser_mod.ParseError;

// Re-export value types and functions
pub const Environment = value_mod.Environment;
pub const FunctionValue = value_mod.FunctionValue;
pub const NativeFn = value_mod.NativeFn;
pub const ThunkState = value_mod.ThunkState;
pub const Thunk = value_mod.Thunk;
pub const Value = value_mod.Value;
pub const ArrayValue = value_mod.ArrayValue;
pub const TupleValue = value_mod.TupleValue;
pub const ObjectFieldValue = value_mod.ObjectFieldValue;
pub const ObjectValue = value_mod.ObjectValue;
pub const EvalError = value_mod.EvalError;
pub const EvalContext = value_mod.EvalContext;
pub const setUserCrashMessage = value_mod.setUserCrashMessage;
pub const getUserCrashMessage = value_mod.getUserCrashMessage;
pub const clearUserCrashMessage = value_mod.clearUserCrashMessage;

// Re-export value formatting functions
pub const formatValue = value_format.formatValue;
pub const formatValuePretty = value_format.formatValuePretty;
pub const formatValueAsJson = value_format.formatValueAsJson;
pub const formatValueAsYaml = value_format.formatValueAsYaml;
pub const formatValueShort = value_format.formatValueShort;
pub const valueToString = value_format.valueToString;

// Re-export AST types
pub const TokenKind = ast.TokenKind;
pub const Token = ast.Token;
pub const BinaryOp = ast.BinaryOp;
pub const UnaryOp = ast.UnaryOp;
pub const SourceLocation = ast.SourceLocation;
pub const Expression = ast.Expression;
pub const ExpressionData = ast.ExpressionData;
pub const Pattern = ast.Pattern;
pub const PatternData = ast.PatternData;
pub const Lambda = ast.Lambda;
pub const Let = ast.Let;
pub const WhereBinding = ast.WhereBinding;
pub const WhereExpr = ast.WhereExpr;
pub const Unary = ast.Unary;
pub const Binary = ast.Binary;
pub const Application = ast.Application;
pub const If = ast.If;
pub const WhenMatches = ast.WhenMatches;
pub const MatchBranch = ast.MatchBranch;
pub const ConditionalElement = ast.ConditionalElement;
pub const ArrayElement = ast.ArrayElement;
pub const ArrayLiteral = ast.ArrayLiteral;
pub const TupleLiteral = ast.TupleLiteral;
pub const ObjectFieldKey = ast.ObjectFieldKey;
pub const ObjectField = ast.ObjectField;
pub const ObjectLiteral = ast.ObjectLiteral;
pub const ObjectExtend = ast.ObjectExtend;
pub const ImportExpr = ast.ImportExpr;
pub const StringInterpolation = ast.StringInterpolation;
pub const StringPart = ast.StringPart;
pub const ForClause = ast.ForClause;
pub const ArrayComprehension = ast.ArrayComprehension;
pub const ObjectComprehension = ast.ObjectComprehension;
pub const FieldAccess = ast.FieldAccess;
pub const Index = ast.Index;
pub const FieldAccessor = ast.FieldAccessor;
pub const FieldProjection = ast.FieldProjection;
pub const TuplePattern = ast.TuplePattern;
pub const ArrayPattern = ast.ArrayPattern;
pub const ObjectPattern = ast.ObjectPattern;
pub const ObjectPatternField = ast.ObjectPatternField;

// Re-export module resolver functions
pub const collectLazyPaths = module_resolver.collectLazyPaths;
pub const ModuleFile = module_resolver.ModuleFile;

// Re-export evaluator functions
pub const matchPattern = evaluator.matchPattern;
pub const force = evaluator.force;
pub const evaluateExpression = evaluator.evaluateExpression;
pub const importModule = evaluator.importModule;
pub const createStdlibEnvironment = evaluator.createStdlibEnvironment;

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

pub const EvalOutput = struct {
    allocator: std.mem.Allocator,
    text: []u8,

    pub fn deinit(self: *EvalOutput) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }
};

/// Extended eval output that includes error context
pub const EvalResult = struct {
    output: ?EvalOutput,
    error_ctx: error_context.ErrorContext,
    err: ?EvalError = null,

    pub fn deinit(self: *EvalResult) void {
        if (self.output) |*out| {
            out.deinit();
        }
        self.error_ctx.deinit();
    }
};

pub const FormatStyle = enum {
    pretty,
    json,
    yaml,
};

fn evalSourceWithContext(
    allocator: std.mem.Allocator,
    source: []const u8,
    current_dir: ?[]const u8,
) EvalError!EvalResult {
    return evalSourceWithFormat(allocator, source, current_dir, null, .pretty);
}

fn evalSourceWithFormat(
    allocator: std.mem.Allocator,
    source: []const u8,
    current_dir: ?[]const u8,
    filename: ?[]const u8,
    format: FormatStyle,
) EvalError!EvalResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const lazy_paths = try collectLazyPaths(arena.allocator());
    var err_ctx = error_context.ErrorContext.init(allocator);
    // NOTE: No errdefer for err_ctx because we return it to the caller who will deinit it
    err_ctx.setSource(source);

    // Set current file if provided
    if (filename) |fname| {
        err_ctx.registerSource(fname, source) catch {};
        err_ctx.setCurrentFile(fname);
    }

    const context = EvalContext{
        .allocator = allocator,
        .lazy_paths = lazy_paths,
        .error_ctx = &err_ctx,
    };

    var parser = Parser.initWithContext(arena.allocator(), source, &err_ctx) catch |err| {
        // Error location already set by tokenizer if applicable
        arena.deinit();
        return EvalResult{
            .output = null,
            .error_ctx = err_ctx,
            .err = err,
        };
    };
    const expression = parser.parse() catch |err| {
        arena.deinit();
        return EvalResult{
            .output = null,
            .error_ctx = err_ctx,
            .err = err,
        };
    };

    const env = createStdlibEnvironment(arena.allocator(), current_dir, &context) catch |err| {
        // If stdlib import fails, clean up and return error
        arena.deinit();
        return EvalResult{
            .output = null,
            .error_ctx = err_ctx,
            .err = err,
        };
    };

    // CRITICAL: Restore current_file to the main file before evaluating the main expression
    // This ensures any errors in the main file show the correct filename, not a module filename
    // Also clear any stale error state from imports
    if (filename) |fname| {
        err_ctx.setCurrentFile(fname);
        // Clear all error state to ensure fresh error reporting for main file
        if (err_ctx.source_filename_owned and err_ctx.source_filename.len > 0) {
            allocator.free(err_ctx.source_filename);
        }
        err_ctx.source_filename = "";
        err_ctx.source_filename_owned = false;
        err_ctx.last_error_location = null;
        err_ctx.last_error_secondary_location = null;
        err_ctx.last_error_location_label = null;
        err_ctx.last_error_secondary_label = null;
    }

    const value = evaluateExpression(arena.allocator(), expression, env, current_dir, &context) catch |err| {
        arena.deinit();
        return EvalResult{
            .output = null,
            .error_ctx = err_ctx,
            .err = err,
        };
    };
    const formatted = switch (format) {
        .pretty => try value_format.formatValuePretty(allocator, value),
        .json => try value_format.formatValueAsJson(allocator, value),
        .yaml => try value_format.formatValueAsYaml(allocator, value),
    };

    arena.deinit();
    return EvalResult{
        .output = .{
            .allocator = allocator,
            .text = formatted,
        },
        .error_ctx = err_ctx,
    };
}

fn evalSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    current_dir: ?[]const u8,
) EvalError!EvalOutput {
    var result = try evalSourceWithContext(allocator, source, current_dir);
    defer result.error_ctx.deinit();

    if (result.output) |output| {
        return output;
    } else {
        // Return the actual error that occurred
        return result.err orelse error.UnknownIdentifier;
    }
}

pub fn evalInline(allocator: std.mem.Allocator, source: []const u8) EvalError!EvalOutput {
    return try evalSource(allocator, source, null);
}

pub fn evalInlineWithContext(allocator: std.mem.Allocator, source: []const u8) EvalError!EvalResult {
    return try evalSourceWithContext(allocator, source, null);
}

pub fn evalInlineWithFormat(allocator: std.mem.Allocator, source: []const u8, format: FormatStyle) EvalError!EvalResult {
    return try evalSourceWithFormat(allocator, source, null, null, format);
}

pub fn evalFileWithContext(allocator: std.mem.Allocator, path: []const u8) EvalError!EvalResult {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    const directory = std.fs.path.dirname(path);
    return try evalSourceWithContext(allocator, contents, directory);
}

pub fn evalFileWithFormat(allocator: std.mem.Allocator, path: []const u8, format: FormatStyle) EvalError!EvalResult {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    const directory = std.fs.path.dirname(path);
    return try evalSourceWithFormat(allocator, contents, directory, path, format);
}

pub const EvalValueResult = struct {
    value: Value,
    arena: std.heap.ArenaAllocator,
    error_ctx: error_context.ErrorContext,
    err: ?EvalError = null,

    pub fn deinit(self: *EvalValueResult) void {
        self.arena.deinit();
        self.error_ctx.deinit();
    }
};

pub fn evalInlineWithValue(allocator: std.mem.Allocator, source: []const u8) EvalError!EvalValueResult {
    return evalSourceWithValue(allocator, source, null);
}

pub fn evalFileWithValue(allocator: std.mem.Allocator, path: []const u8) EvalError!EvalValueResult {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    const directory = std.fs.path.dirname(path);
    var result = try evalSourceWithValue(allocator, contents, directory);

    // Register the main file for error reporting
    if (result.err != null) {
        result.error_ctx.registerSource(path, contents) catch {};
        if (result.error_ctx.current_file.len == 0) {
            result.error_ctx.setCurrentFile(path);
        }
    }

    return result;
}

fn evalSourceWithValue(
    allocator: std.mem.Allocator,
    source: []const u8,
    current_dir: ?[]const u8,
) EvalError!EvalValueResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const lazy_paths = try collectLazyPaths(arena.allocator());
    var err_ctx = error_context.ErrorContext.init(allocator);
    err_ctx.setSource(source);

    const context = EvalContext{
        .allocator = allocator,
        .lazy_paths = lazy_paths,
        .error_ctx = &err_ctx,
    };

    var parser = try Parser.init(arena.allocator(), source);
    parser.setErrorContext(&err_ctx);
    const expression = parser.parse() catch |err| {
        arena.deinit();
        return EvalValueResult{
            .value = .null_value,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .error_ctx = err_ctx,
            .err = err,
        };
    };

    const env = try builtin_env.createBuiltinEnvironment(arena.allocator());
    const value = evaluateExpression(arena.allocator(), expression, env, current_dir, &context) catch |err| {
        arena.deinit();
        return EvalValueResult{
            .value = .null_value,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .error_ctx = err_ctx,
            .err = err,
        };
    };

    return EvalValueResult{
        .value = value,
        .arena = arena,
        .error_ctx = err_ctx,
    };
}

pub fn evalFile(allocator: std.mem.Allocator, path: []const u8) EvalError!EvalOutput {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    const directory = std.fs.path.dirname(path);
    return try evalSource(allocator, contents, directory);
}

pub fn evalFileValue(
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    path: []const u8,
) EvalError!Value {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    const lazy_paths = try collectLazyPaths(arena);
    const context = EvalContext{ .allocator = allocator, .lazy_paths = lazy_paths };

    var parser = try Parser.init(arena, contents);
    const expression = try parser.parse();

    const directory = std.fs.path.dirname(path);
    const env = try createStdlibEnvironment(arena, directory, &context);
    return try evaluateExpression(arena, expression, env, directory, &context);
}
