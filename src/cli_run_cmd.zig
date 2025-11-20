//! Run command handler for Lazylang CLI.
//!
//! This module implements the 'run' subcommand which executes a Lazylang
//! program that takes system arguments and environment variables.
//!
//! The program must be a function that takes a single object parameter
//! with `args` (array of strings) and `env` (object mapping strings to strings).
//!
//! Usage:
//!   lazylang run <file>               - Run with no arguments
//!   lazylang run <file> -- arg1 arg2  - Run with arguments

const std = @import("std");
const evaluator = @import("eval.zig");
const error_reporter = @import("error_reporter.zig");
const error_context = @import("error_context.zig");
const cli_error_reporting = @import("cli_error_reporting.zig");

const cli_types = @import("cli_types.zig");
pub const CommandResult = cli_types.CommandResult;

pub fn runRun(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    // Parse arguments: file_path [-- arg1 arg2 ...]
    if (args.len == 0) {
        try stderr.print("error: missing file path\n", .{});
        return .{ .exit_code = 1 };
    }

    const file_path = args[0];
    var run_args_start: usize = 1;
    var found_separator = false;

    // Find the -- separator
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            run_args_start = i + 1;
            found_separator = true;
            break;
        }
    }

    // Get the run arguments (everything after --)
    const run_args = if (found_separator) args[run_args_start..] else &[_][]const u8{};

    // Read the file content for error reporting
    const file_content = std.fs.cwd().readFileAlloc(allocator, file_path, std.math.maxInt(usize)) catch |read_err| {
        try stderr.print("error: failed to read file '{s}': {}\n", .{ file_path, read_err });
        return .{ .exit_code = 1 };
    };
    defer allocator.free(file_content);

    // Create an arena allocator for the evaluation
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    // Determine final color value (auto-detect since runRun doesn't have color flags)
    const colors_enabled = error_reporter.shouldUseColors();

    // Parse the file
    var parser = evaluator.Parser.init(arena, file_content) catch |err| {
        try cli_error_reporting.reportError(allocator, stderr, file_path, file_content, err, null, colors_enabled);
        return .{ .exit_code = 1 };
    };

    const expression = parser.parse() catch |err| {
        var err_ctx = error_context.ErrorContext.init(allocator);
        try cli_error_reporting.reportErrorWithContext(allocator, stderr, file_path, file_content, &err_ctx, err, colors_enabled);
        return .{ .exit_code = 1 };
    };

    // Evaluate the expression to get a value
    const directory = std.fs.path.dirname(file_path);
    var eval_ctx = evaluator.EvalContext{
        .allocator = allocator,
        .lazy_paths = &[_][]const u8{},
    };

    const value = evaluator.evaluateExpression(arena, expression, null, directory, &eval_ctx) catch |err| {
        try cli_error_reporting.reportError(allocator, stderr, file_path, file_content, err, null, colors_enabled);
        return .{ .exit_code = 1 };
    };

    // Check that the value is a function
    const function = switch (value) {
        .function => |f| f,
        else => {
            try stderr.print("error: file must evaluate to a function, got {s}\n", .{@tagName(value)});
            return .{ .exit_code = 1 };
        },
    };

    // Create the system object with args and env
    // First, create the args array
    const args_values = try arena.alloc(evaluator.Value, run_args.len);
    for (run_args, 0..) |arg, i| {
        const arg_copy = try arena.dupe(u8, arg);
        args_values[i] = evaluator.Value{ .string = arg_copy };
    }

    // Create the env object
    var env_fields = std.ArrayList(evaluator.ObjectFieldValue){};
    defer env_fields.deinit(arena);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var env_iter = env_map.iterator();
    while (env_iter.next()) |entry| {
        const key_copy = try arena.dupe(u8, entry.key_ptr.*);
        const value_copy = try arena.dupe(u8, entry.value_ptr.*);
        try env_fields.append(arena, .{
            .key = key_copy,
            .value = evaluator.Value{ .string = value_copy },
            .is_patch = false,
        });
    }

    const env_object = evaluator.Value{
        .object = .{
            .fields = try env_fields.toOwnedSlice(arena),
            .module_doc = null,
        },
    };

    // Create the system object
    const system_fields = try arena.alloc(evaluator.ObjectFieldValue, 2);
    system_fields[0] = .{
        .key = "args",
        .value = evaluator.Value{ .array = .{ .elements = args_values } },
        .is_patch = false,
    };
    system_fields[1] = .{
        .key = "env",
        .value = env_object,
        .is_patch = false,
    };

    const system_value = evaluator.Value{
        .object = .{ .fields = system_fields, .module_doc = null },
    };

    // Call the function with the system value
    const bound_env = evaluator.matchPattern(arena, function.param, system_value, function.env, &eval_ctx) catch |err| {
        try stderr.print("error: failed to bind function parameter: {}\n", .{err});
        return .{ .exit_code = 1 };
    };

    const result = evaluator.evaluateExpression(arena, function.body, bound_env, directory, &eval_ctx) catch |err| {
        try cli_error_reporting.reportError(allocator, stderr, file_path, file_content, err, null, colors_enabled);
        return .{ .exit_code = 1 };
    };

    // Format and print the result
    const formatted = try evaluator.formatValue(allocator, result);
    defer allocator.free(formatted);

    try stdout.print("{s}\n", .{formatted});
    return .{ .exit_code = 0 };
}
