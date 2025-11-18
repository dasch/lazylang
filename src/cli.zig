//! Command-line interface for Lazylang.
//!
//! This module implements the CLI dispatcher and command handlers for the
//! Lazylang interpreter. It provides the following subcommands:
//!
//! Commands:
//! - eval: Evaluate a Lazylang file or expression
//!   - Supports --json and --yaml output formats
//!   - Supports --manifest mode for multi-file output
//!   - Can evaluate inline expressions with -e/--expr
//!
//! - run: Execute a Lazylang program with system args/env
//!   - Program must be a function taking {args, env}
//!   - Passes command-line args and environment variables
//!
//! - spec: Run Lazylang test files (*Spec.lazy)
//!   - Supports running individual tests by line number
//!   - Colored output with test results
//!
//! - format: Format Lazylang source code
//!   - Normalizes whitespace and indentation
//!
//! - docs: Generate HTML documentation from doc comments
//!   - Extracts /// comments from stdlib modules
//!   - Generates browsable API documentation
//!
//! The CLI handles error reporting, color output, and delegates actual
//! command logic to specialized modules or evaluator functions.

const std = @import("std");
const evaluator = @import("eval.zig");
const spec = @import("spec.zig");
const error_reporter = @import("error_reporter.zig");
const error_context = @import("error_context.zig");
const json_error = @import("json_error.zig");
const formatter = @import("formatter.zig");
const docs = @import("docs.zig");
const cli_error_reporting = @import("cli_error_reporting.zig");

pub const CommandResult = struct {
    exit_code: u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    if (args.len <= 1) {
        try stderr.print("error: missing subcommand\n", .{});
        return .{ .exit_code = 1 };
    }

    const subcommand = args[1];
    if (std.mem.eql(u8, subcommand, "eval")) {
        return try runEval(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "spec")) {
        return try runSpec(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "format")) {
        return try runFormat(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "docs")) {
        return try runDocs(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "run")) {
        return try runRun(allocator, args[2..], stdout, stderr);
    }

    try stderr.print("error: unknown subcommand '{s}'\n", .{subcommand});
    return .{ .exit_code = 1 };
}

const OutputFormat = enum {
    pretty,
    json,
    yaml,
};

fn runEval(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    var inline_expr: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var output_format: OutputFormat = .pretty;
    var json_output = false;
    var manifest_mode = false;
    var use_colors: ?bool = null; // null means auto-detect
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--expr") or std.mem.eql(u8, arg, "-e")) {
            if (index + 1 >= args.len) {
                try stderr.print("error: --expr requires a value\n", .{});
                return .{ .exit_code = 1 };
            }
            if (inline_expr != null) {
                try stderr.print("error: --expr can only be specified once\n", .{});
                return .{ .exit_code = 1 };
            }
            inline_expr = args[index + 1];
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
            output_format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--yaml")) {
            output_format = .yaml;
            continue;
        }
        if (std.mem.eql(u8, arg, "--manifest")) {
            manifest_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-color")) {
            use_colors = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--color")) {
            use_colors = true;
            continue;
        }

        // Positional argument - treat as file path
        // Check if this is an unknown flag
        if (std.mem.startsWith(u8, arg, "--") or std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("error: unknown flag '{s}'\n", .{arg});
            return .{ .exit_code = 1 };
        }

        if (file_path != null) {
            try stderr.print("error: unexpected argument '{s}'\n", .{arg});
            return .{ .exit_code = 1 };
        }
        file_path = arg;
    }

    // Determine final color value (auto-detect if not explicitly set)
    const colors_enabled = use_colors orelse error_reporter.shouldUseColors();

    // --expr takes precedence over file path
    if (inline_expr != null) {
        if (file_path != null) {
            try stderr.print("error: cannot specify both --expr and a file path\n", .{});
            return .{ .exit_code = 1 };
        }

        if (manifest_mode) {
            // Get the raw value for manifest mode
            var value_result = evaluator.evalInlineWithValue(allocator, inline_expr.?) catch |err| {
                if (json_output) {
                    try json_error.reportErrorAsJson(stderr, "<inline>", &error_context.ErrorContext.init(allocator), @errorName(err), @errorName(err), null);
                } else {
                    try cli_error_reporting.reportError(allocator, stderr, "<inline>", inline_expr.?, err, null, colors_enabled);
                }
                return .{ .exit_code = 1 };
            };
            defer value_result.deinit();

            if (value_result.err) |_| {
                try cli_error_reporting.reportErrorWithContext(allocator, stderr, "<inline>", inline_expr.?, &value_result.error_ctx, null, colors_enabled);
                return .{ .exit_code = 1 };
            }

            writeManifestFiles(allocator, value_result.value, value_result.arena.allocator(), output_format, stdout, stderr) catch |err| {
                if (err != error.TypeMismatch) {
                    return err;
                }
                return .{ .exit_code = 1 };
            };
            return .{ .exit_code = 0 };
        }

        const format: evaluator.FormatStyle = switch (output_format) {
            .pretty => .pretty,
            .json => .json,
            .yaml => .yaml,
        };

        var result = evaluator.evalInlineWithFormat(allocator, inline_expr.?, format) catch |err| {
            if (json_output) {
                const message = if (err == error.UserCrash) evaluator.getUserCrashMessage() orelse @errorName(err) else @errorName(err);
                try json_error.reportErrorAsJson(stderr, "<inline>", &error_context.ErrorContext.init(allocator), @errorName(err), message, null);
                if (err == error.UserCrash) evaluator.clearUserCrashMessage();
            } else {
                try cli_error_reporting.reportError(allocator, stderr, "<inline>", inline_expr.?, err, null, colors_enabled);
            }
            return .{ .exit_code = 1 };
        };
        defer result.deinit();

        if (result.output) |output| {
            try stdout.print("{s}\n", .{output.text});
            return .{ .exit_code = 0 };
        } else {
            // Error occurred
            if (json_output) {
                try json_error.reportErrorAsJson(stderr, "<inline>", &result.error_ctx, "ParseError", "An error occurred at this location.", null);
            } else {
                try cli_error_reporting.reportErrorWithContext(allocator, stderr, "<inline>", inline_expr.?, &result.error_ctx, result.err, colors_enabled);
            }
            return .{ .exit_code = 1 };
        }
    }

    if (file_path == null) {
        try stderr.print("error: missing file path or --expr option\n", .{});
        return .{ .exit_code = 1 };
    }

    // Read the file content first for error reporting
    const file_content = std.fs.cwd().readFileAlloc(allocator, file_path.?, std.math.maxInt(usize)) catch |read_err| {
        try stderr.print("error: failed to read file '{s}': {}\n", .{ file_path.?, read_err });
        return .{ .exit_code = 1 };
    };
    defer allocator.free(file_content);

    const format: evaluator.FormatStyle = switch (output_format) {
        .pretty => .pretty,
        .json => .json,
        .yaml => .yaml,
    };

    var result = evaluator.evalFileWithFormat(allocator, file_path.?, format) catch |err| {
        // For file I/O errors, we don't have source context
        if (json_output) {
            const message = if (err == error.UserCrash) evaluator.getUserCrashMessage() orelse @errorName(err) else @errorName(err);
            try json_error.reportErrorAsJson(stderr, file_path.?, &error_context.ErrorContext.init(allocator), @errorName(err), message, null);
            if (err == error.UserCrash) evaluator.clearUserCrashMessage();
        } else {
            try cli_error_reporting.reportError(allocator, stderr, file_path.?, file_content, err, null, colors_enabled);
        }
        return .{ .exit_code = 1 };
    };
    defer result.deinit();

    // Register the main file in the error context for error reporting
    if (result.err == null and result.output != null) {
        // No need to register if there's no error
    } else {
        result.error_ctx.registerSource(file_path.?, file_content) catch {};
    }

    if (result.output) |output| {
        if (manifest_mode) {
            // Get the raw value for manifest mode
            var value_result = evaluator.evalFileWithValue(allocator, file_path.?) catch |err| {
                if (json_output) {
                    try json_error.reportErrorAsJson(stderr, file_path.?, &error_context.ErrorContext.init(allocator), @errorName(err), @errorName(err), null);
                } else {
                    try cli_error_reporting.reportError(allocator, stderr, file_path.?, file_content, err, null, colors_enabled);
                }
                return .{ .exit_code = 1 };
            };
            defer value_result.deinit();

            if (value_result.err) |_| {
                try cli_error_reporting.reportErrorWithContext(allocator, stderr, file_path.?, file_content, &value_result.error_ctx, null, colors_enabled);
                return .{ .exit_code = 1 };
            }

            writeManifestFiles(allocator, value_result.value, value_result.arena.allocator(), output_format, stdout, stderr) catch |err| {
                if (err != error.TypeMismatch) {
                    return err;
                }
                return .{ .exit_code = 1 };
            };
            return .{ .exit_code = 0 };
        }

        try stdout.print("{s}\n", .{output.text});
        return .{ .exit_code = 0 };
    } else {
        // Error occurred during parsing/evaluation
        // Look up the correct source from the error context's source map
        const error_filename = if (result.error_ctx.source_filename.len > 0)
            result.error_ctx.source_filename
        else
            file_path.?;

        const error_source = result.error_ctx.source_map.get(error_filename) orelse file_content;

        if (json_output) {
            try json_error.reportErrorAsJson(stderr, error_filename, &result.error_ctx, "ParseError", "An error occurred at this location.", null);
        } else {
            try cli_error_reporting.reportErrorWithContext(allocator, stderr, error_filename, error_source, &result.error_ctx, result.err, colors_enabled);
        }
        return .{ .exit_code = 1 };
    }
}

fn writeManifestFiles(
    allocator: std.mem.Allocator,
    value: evaluator.Value,
    arena: std.mem.Allocator,
    output_format: OutputFormat,
    stdout: anytype,
    stderr: anytype,
) !void {
    // Ensure the value is an object
    const obj = switch (value) {
        .object => |o| o,
        else => {
            try stderr.print("error: --manifest requires output to be an object, got {s}\n", .{@tagName(value)});
            return error.TypeMismatch;
        },
    };

    // For each field in the object, write to a file
    for (obj.fields) |field| {
        const filename = field.key;
        const field_value = try evaluator.force(arena, field.value);

        // Format the value based on output_format
        const needs_free = output_format != .pretty;
        const content = switch (output_format) {
            .pretty => blk: {
                // In pretty mode, values must be strings
                const str = switch (field_value) {
                    .string => |s| s,
                    else => {
                        try stderr.print("error: --manifest without --json or --yaml requires all values to be strings, but field '{s}' is {s}\n", .{ filename, @tagName(field_value) });
                        return error.TypeMismatch;
                    },
                };
                break :blk str;
            },
            .json => blk: {
                // In JSON mode, any value can be encoded
                break :blk try evaluator.formatValueAsJson(allocator, field_value);
            },
            .yaml => blk: {
                // In YAML mode, any value can be encoded
                break :blk try evaluator.formatValueAsYaml(allocator, field_value);
            },
        };
        defer if (needs_free) allocator.free(content);

        // Write to file
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        try file.writeAll(content);

        // Print confirmation
        try stdout.print("Wrote {s}\n", .{filename});
    }
}

fn runSpec(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    // If no arguments, run all specs in spec/ directory
    if (args.len == 0) {
        const result = spec.runAllSpecs(allocator, "spec", stdout) catch |err| {
            try stderr.print("error: failed to run specs: {}\n", .{err});
            return .{ .exit_code = 1 };
        };
        return .{ .exit_code = result.exitCode() };
    }

    // If one argument, check if it's a directory or file
    if (args.len == 1) {
        const path_arg = args[0];

        // Check if the path contains a line number (format: path:line)
        var path = path_arg;
        var line_number: ?usize = null;

        if (std.mem.lastIndexOfScalar(u8, path_arg, ':')) |colon_idx| {
            // Try to parse the part after the colon as a line number
            const line_str = path_arg[colon_idx + 1 ..];
            if (std.fmt.parseInt(usize, line_str, 10)) |line| {
                path = path_arg[0..colon_idx];
                line_number = line;
            } else |_| {
                // Not a valid line number, treat the whole thing as a path
            }
        }

        // Check if it's a directory
        const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr.print("error: path not found: {s}\n", .{path});
                return .{ .exit_code = 1 };
            },
            else => return err,
        };

        if (stat.kind == .directory) {
            if (line_number != null) {
                try stderr.print("error: cannot specify line number for directory\n", .{});
                return .{ .exit_code = 1 };
            }
            // Run all specs in the directory recursively
            const result = spec.runAllSpecs(allocator, path, stdout) catch |err| {
                try stderr.print("error: failed to run specs: {}\n", .{err});
                return .{ .exit_code = 1 };
            };
            return .{ .exit_code = result.exitCode() };
        } else {
            // Run the specific spec file
            const result = spec.runSpec(allocator, path, line_number, stdout) catch |err| {
                try stderr.print("error: failed to run spec: {}\n", .{err});
                return .{ .exit_code = 1 };
            };
            return .{ .exit_code = result.exitCode() };
        }
    }

    try stderr.print("error: unexpected arguments\n", .{});
    return .{ .exit_code = 1 };
}

fn runFormat(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    if (args.len == 0) {
        try stderr.print("error: missing file path\n", .{});
        try stderr.print("usage: lazy format <path>\n", .{});
        return .{ .exit_code = 1 };
    }

    if (args.len > 1) {
        try stderr.print("error: too many arguments\n", .{});
        try stderr.print("usage: lazy format <path>\n", .{});
        return .{ .exit_code = 1 };
    }

    const file_path = args[0];

    var format_output = formatter.formatFile(allocator, file_path) catch |err| {
        try stderr.print("error: failed to format file: {}\n", .{err});
        return .{ .exit_code = 1 };
    };
    defer format_output.deinit();

    try stdout.print("{s}", .{format_output.text});
    return .{ .exit_code = 0 };
}

fn runRun(
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

fn runDocs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    var output_dir: []const u8 = "docs";
    var input_path: ?[]const u8 = null;
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            if (index + 1 >= args.len) {
                try stderr.print("error: --output requires a value\n", .{});
                return .{ .exit_code = 1 };
            }
            output_dir = args[index + 1];
            index += 1;
            continue;
        }

        // Positional argument - treat as input path
        if (input_path != null) {
            try stderr.print("error: unexpected argument '{s}'\n", .{arg});
            return .{ .exit_code = 1 };
        }
        input_path = arg;
    }

    // Default to "lib" directory if no input path specified
    if (input_path == null) {
        input_path = "lib";
    }

    // Create output directory if it doesn't exist
    std.fs.cwd().makePath(output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Collect all module info
    var modules_list = std.ArrayList(docs.ModuleInfo){};
    defer {
        for (modules_list.items) |module| {
            allocator.free(module.name);
            for (module.items) |item| {
                allocator.free(item.name);
                allocator.free(item.signature);
                allocator.free(item.doc);
            }
            allocator.free(module.items);
        }
        modules_list.deinit(allocator);
    }

    // Check if input is a directory or file
    const stat = std.fs.cwd().statFile(input_path.?) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print("error: path not found: {s}\n", .{input_path.?});
            return .{ .exit_code = 1 };
        },
        else => return err,
    };

    if (stat.kind == .directory) {
        // Collect all modules from directory
        try docs.collectModulesFromDirectory(allocator, input_path.?, &modules_list, stdout);
    } else {
        // Collect single module
        try stdout.print("Extracting docs from {s}...\n", .{input_path.?});
        const module_info = try docs.extractModuleInfo(allocator, input_path.?);
        try modules_list.append(allocator, module_info);
    }

    // Generate index.html
    try docs.generateIndexHtml(allocator, modules_list.items, output_dir);

    // Generate HTML for each module
    for (modules_list.items) |module| {
        try stdout.print("Generating HTML for {s}...\n", .{module.name});
        try docs.generateModuleHtml(allocator, module, modules_list.items, output_dir);
    }

    try stdout.print("Documentation generated in {s}/\n", .{output_dir});
    return .{ .exit_code = 0 };
}