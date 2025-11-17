const std = @import("std");
const evaluator = @import("eval.zig");
const spec = @import("spec.zig");
const error_reporter = @import("error_reporter.zig");
const error_context = @import("error_context.zig");
const json_error = @import("json_error.zig");
const formatter = @import("formatter.zig");
const docs = @import("docs.zig");

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

        // Positional argument - treat as file path
        if (file_path != null) {
            try stderr.print("error: unexpected argument '{s}'\n", .{arg});
            return .{ .exit_code = 1 };
        }
        file_path = arg;
    }

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
                    try reportError(allocator, stderr, "<inline>", inline_expr.?, err, null);
                }
                return .{ .exit_code = 1 };
            };
            defer value_result.deinit();

            if (value_result.err) |_| {
                try reportErrorWithContext(allocator, stderr, "<inline>", inline_expr.?, &value_result.error_ctx, null);
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
                try reportError(allocator, stderr, "<inline>", inline_expr.?, err, null);
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
                try reportErrorWithContext(allocator, stderr, "<inline>", inline_expr.?, &result.error_ctx, result.err);
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
            try reportError(allocator, stderr, file_path.?, file_content, err, null);
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
                    try reportError(allocator, stderr, file_path.?, file_content, err, null);
                }
                return .{ .exit_code = 1 };
            };
            defer value_result.deinit();

            if (value_result.err) |_| {
                try reportErrorWithContext(allocator, stderr, file_path.?, file_content, &value_result.error_ctx, null);
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
            try reportErrorWithContext(allocator, stderr, error_filename, error_source, &result.error_ctx, result.err);
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

fn reportErrorWithContext(allocator: std.mem.Allocator, stderr: anytype, filename: []const u8, source: []const u8, err_ctx: *const error_context.ErrorContext, err: ?anyerror) !void {
    // Check if it's a user crash
    if (evaluator.getUserCrashMessage()) |crash_message| {
        const error_info = error_reporter.ErrorInfo{
            .title = "Runtime error",
            .location = null,
            .message = crash_message,
            .suggestion = null,
        };
        try error_reporter.reportError(stderr, source, filename, error_info, error_reporter.shouldUseColors());
        evaluator.clearUserCrashMessage();
        return;
    }

    // If we have the error type, use the detailed error reporting
    if (err) |error_type| {
        try reportError(allocator, stderr, filename, source, error_type, err_ctx);
        return;
    }

    // Fall back to generic error reporting if we don't have the error type
    const error_info = if (err_ctx.last_error_location) |loc| blk: {
        break :blk error_reporter.ErrorInfo{
            .title = "Parse or evaluation error",
            .location = loc,
            .message = "An error occurred at this location.",
            .suggestion = null,
        };
    } else error_reporter.ErrorInfo{
        .title = "Error",
        .location = null,
        .message = "An error occurred during evaluation.",
        .suggestion = null,
    };

    try error_reporter.reportError(stderr, source, filename, error_info, error_reporter.shouldUseColors());
}

fn reportError(allocator: std.mem.Allocator, stderr: anytype, filename: []const u8, source: []const u8, err: anyerror, err_ctx: ?*const error_context.ErrorContext) !void {
    // Use an arena allocator for all temporary error message strings
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const location = if (err_ctx) |ctx| ctx.last_error_location else null;

    const error_info = switch (err) {
        error.UnexpectedCharacter => error_reporter.ErrorInfo{
            .title = "Unexpected character",
            .location = location,
            .message = "Found an unexpected character in the source code.",
            .suggestion = "Remove the invalid character or check for typos.",
        },
        error.UnterminatedString => error_reporter.ErrorInfo{
            .title = "Unterminated string",
            .location = location,
            .message = error_reporter.ErrorMessages.unterminatedString(),
            .suggestion = error_reporter.ErrorSuggestions.unterminatedString(),
        },
        error.ExpectedExpression => error_reporter.ErrorInfo{
            .title = "Expected expression",
            .location = location,
            .message = error_reporter.ErrorMessages.expectedExpression(),
            .suggestion = "Add an expression here.",
        },
        error.UnexpectedToken => blk: {
            if (err_ctx) |ctx| {
                switch (ctx.last_error_data) {
                    .unexpected_token => |data| {
                        const message = if (ctx.last_error_token_lexeme) |lexeme|
                            try std.fmt.allocPrint(arena_allocator, "Expected {s} {s}, but found `{s}`.", .{ data.expected, data.context, lexeme })
                        else
                            try std.fmt.allocPrint(arena_allocator, "Expected {s} {s}.", .{ data.expected, data.context });

                        const suggestion = try std.fmt.allocPrint(arena_allocator, "Add {s} at this location.", .{data.expected});

                        break :blk error_reporter.ErrorInfo{
                            .title = "Unexpected token",
                            .location = location,
                            .message = message,
                            .suggestion = suggestion,
                        };
                    },
                    else => {},
                }

                if (ctx.last_error_token_lexeme) |lexeme| {
                    const message = try std.fmt.allocPrint(arena_allocator, "Found unexpected token `{s}`.", .{lexeme});
                    break :blk error_reporter.ErrorInfo{
                        .title = "Unexpected token",
                        .location = location,
                        .message = message,
                        .suggestion = "Check the syntax at this location.",
                    };
                }
            }
            break :blk error_reporter.ErrorInfo{
                .title = "Unexpected token",
                .location = location,
                .message = "Found an unexpected token.",
                .suggestion = "Check the syntax at this location.",
            };
        },
        error.UnknownIdentifier => blk: {
            if (err_ctx) |ctx| {
                switch (ctx.last_error_data) {
                    .unknown_identifier => |data| {
                        const message = try std.fmt.allocPrint(arena_allocator, "Identifier `{s}` is not defined in the current scope.", .{data.name});
                        // Try to find similar identifiers
                        const did_you_mean = try ctx.findSimilarIdentifiers(data.name, arena_allocator);
                        const suggestion = if (did_you_mean) |dym|
                            try std.fmt.allocPrint(arena_allocator, "{s} Or define this variable before using it.", .{dym})
                        else
                            "Check the spelling or define this variable before using it.";

                        break :blk error_reporter.ErrorInfo{
                            .title = "Unknown identifier",
                            .location = location,
                            .message = message,
                            .suggestion = suggestion,
                        };
                    },
                    else => {},
                }
            }

            break :blk error_reporter.ErrorInfo{
                .title = "Unknown identifier",
                .location = location,
                .message = "This identifier is not defined in the current scope.",
                .suggestion = "Check the spelling or define this variable before using it.",
            };
        },
        error.TypeMismatch => blk: {
            if (err_ctx) |ctx| {
                switch (ctx.last_error_data) {
                    .type_mismatch => |data| {
                        const message = if (data.operation) |op|
                            try std.fmt.allocPrint(arena_allocator, "Expected `{s}` for {s}, but found `{s}`.", .{ data.expected, op, data.found })
                        else
                            try std.fmt.allocPrint(arena_allocator, "Expected `{s}`, but found `{s}`.", .{ data.expected, data.found });

                        break :blk error_reporter.ErrorInfo{
                            .title = "Type mismatch",
                            .location = location,
                            .message = message,
                            .suggestion = "Make sure you're using compatible types for this operation.",
                        };
                    },
                    else => {},
                }
            }

            break :blk error_reporter.ErrorInfo{
                .title = "Type mismatch",
                .location = location,
                .message = "This operation cannot be performed on values of incompatible types.",
                .suggestion = "Make sure you're using compatible types (e.g., numbers with numbers, strings with strings).",
            };
        },
        error.ExpectedFunction => error_reporter.ErrorInfo{
            .title = "Not a function",
            .location = location,
            .message = "Attempted to call a value that is not a function.",
            .suggestion = "Only functions can be called with arguments. Make sure this value is a function.",
        },
        error.ModuleNotFound => error_reporter.ErrorInfo{
            .title = "Module not found",
            .location = location,
            .message = "Could not find the imported module file.",
            .suggestion = "Check that the module path is correct and the file exists. Module paths are searched in LAZYLANG_PATH and stdlib/lib.",
        },
        error.WrongNumberOfArguments => error_reporter.ErrorInfo{
            .title = "Wrong number of arguments",
            .location = location,
            .message = "Function was called with the wrong number of arguments.",
            .suggestion = "Check the function signature and provide the correct number of arguments.",
        },
        error.InvalidArgument => error_reporter.ErrorInfo{
            .title = "Invalid argument",
            .location = location,
            .message = "An argument has an invalid value for this operation.",
            .suggestion = "Check that argument values are within valid ranges (e.g., array indices must be non-negative).",
        },
        error.UnknownField => blk: {
            if (err_ctx) |ctx| {
                switch (ctx.last_error_data) {
                    .unknown_field => |data| {
                        // Build message based on available fields
                        const message = if (data.available_fields.len == 0)
                            try std.fmt.allocPrint(arena_allocator, "Field `{s}` is not defined on this object.", .{data.field_name})
                        else if (data.available_fields.len == 1)
                            try std.fmt.allocPrint(arena_allocator, "Field `{s}` is not defined on this object. The only available field is `{s}`.", .{ data.field_name, data.available_fields[0] })
                        else if (data.available_fields.len == 2)
                            try std.fmt.allocPrint(arena_allocator, "Field `{s}` is not defined on this object. Available fields are: `{s}`, `{s}`", .{ data.field_name, data.available_fields[0], data.available_fields[1] })
                        else if (data.available_fields.len == 3)
                            try std.fmt.allocPrint(arena_allocator, "Field `{s}` is not defined on this object. Available fields are: `{s}`, `{s}`, `{s}`", .{ data.field_name, data.available_fields[0], data.available_fields[1], data.available_fields[2] })
                        else if (data.available_fields.len == 4)
                            try std.fmt.allocPrint(arena_allocator, "Field `{s}` is not defined on this object. Available fields are: `{s}`, `{s}`, `{s}`, `{s}`", .{ data.field_name, data.available_fields[0], data.available_fields[1], data.available_fields[2], data.available_fields[3] })
                        else
                            try std.fmt.allocPrint(arena_allocator, "Field `{s}` is not defined on this object. Available fields are: `{s}`, `{s}`, `{s}`, `{s}`, `{s}`", .{ data.field_name, data.available_fields[0], data.available_fields[1], data.available_fields[2], data.available_fields[3], data.available_fields[4] });

                        break :blk error_reporter.ErrorInfo{
                            .title = "Unknown field",
                            .location = location,
                            .message = message,
                            .suggestion = "Check the field name for typos.",
                        };
                    },
                    else => {},
                }
            }

            break :blk error_reporter.ErrorInfo{
                .title = "Unknown field",
                .location = location,
                .message = "Attempted to access a field that doesn't exist on this object.",
                .suggestion = "Check the field name for typos or verify the object structure.",
            };
        },
        error.Overflow => error_reporter.ErrorInfo{
            .title = "Arithmetic overflow",
            .location = location,
            .message = "An arithmetic operation resulted in a value that's too large to represent.",
            .suggestion = "Use smaller numbers or break the calculation into smaller steps.",
        },
        error.UserCrash => blk: {
            const crash_message = evaluator.getUserCrashMessage() orelse "Program crashed with no message.";
            break :blk error_reporter.ErrorInfo{
                .title = "Runtime error",
                .location = null,
                .message = crash_message,
                .suggestion = null,
            };
        },
        error.CyclicReference => error_reporter.ErrorInfo{
            .title = "Cyclic reference",
            .location = location,
            .message = "A cyclic reference was detected during evaluation. This usually means a value depends on itself in an invalid way.",
            .suggestion = "Check for circular dependencies in your definitions.",
        },
        error.DivisionByZero => error_reporter.ErrorInfo{
            .title = "Division by zero",
            .location = location,
            .message = "Cannot divide by zero.",
            .suggestion = "Ensure the divisor is not zero before performing division.",
        },
        else => error_reporter.ErrorInfo{
            .title = "Error",
            .location = null,
            .message = @errorName(err),
            .suggestion = null,
        },
    };

    try error_reporter.reportError(stderr, source, filename, error_info, error_reporter.shouldUseColors());
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

    // Parse the file
    var parser = evaluator.Parser.init(arena, file_content) catch |err| {
        try reportError(allocator, stderr, file_path, file_content, err, null);
        return .{ .exit_code = 1 };
    };

    const expression = parser.parse() catch |err| {
        var err_ctx = error_context.ErrorContext.init(allocator);
        try reportErrorWithContext(allocator, stderr, file_path, file_content, &err_ctx, err);
        return .{ .exit_code = 1 };
    };

    // Evaluate the expression to get a value
    const directory = std.fs.path.dirname(file_path);
    var eval_ctx = evaluator.EvalContext{
        .allocator = allocator,
        .lazy_paths = &[_][]const u8{},
    };

    const value = evaluator.evaluateExpression(arena, expression, null, directory, &eval_ctx) catch |err| {
        try reportError(allocator, stderr, file_path, file_content, err, null);
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
    };
    system_fields[1] = .{
        .key = "env",
        .value = env_object,
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
        try reportError(allocator, stderr, file_path, file_content, err, null);
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