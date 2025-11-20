//! Eval command handler for Lazylang CLI.
//!
//! This module implements the 'eval' subcommand which evaluates Lazylang
//! files or inline expressions and outputs the result in various formats.
//!
//! Usage:
//!   lazy eval <file>                - Evaluate file
//!   lazy eval -e <expr>             - Evaluate inline expression
//!   lazy eval --json <file>         - Output as JSON
//!   lazy eval --yaml <file>         - Output as YAML
//!   lazy eval --manifest <file>     - Write object fields to files
//!   lazy eval --color/--no-color    - Control colored output

const std = @import("std");
const evaluator = @import("eval.zig");
const error_reporter = @import("error_reporter.zig");
const error_context = @import("error_context.zig");
const json_error = @import("json_error.zig");
const cli_error_reporting = @import("cli_error_reporting.zig");

const cli_types = @import("cli_types.zig");
pub const CommandResult = cli_types.CommandResult;

const OutputFormat = enum {
    pretty,
    json,
    yaml,
};

pub fn runEval(
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
