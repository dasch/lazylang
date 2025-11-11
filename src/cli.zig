const std = @import("std");
const evaluator = @import("eval.zig");
const spec = @import("spec.zig");
const error_reporter = @import("error_reporter.zig");
const error_context = @import("error_context.zig");
const json_error = @import("json_error.zig");
const formatter = @import("formatter.zig");

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

    try stderr.print("error: unknown subcommand '{s}'\n", .{subcommand});
    return .{ .exit_code = 1 };
}

fn runEval(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    var inline_expr: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var json_output = false;
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

        var result = evaluator.evalInlineWithContext(allocator, inline_expr.?) catch |err| {
            if (json_output) {
                try json_error.reportErrorAsJson(stderr, "<inline>", &error_context.ErrorContext.init(allocator), @errorName(err), @errorName(err), null);
            } else {
                try reportError(stderr, "<inline>", inline_expr.?, err, null);
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
                try reportErrorWithContext(stderr, "<inline>", inline_expr.?, &result.error_ctx);
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

    var result = evaluator.evalFileWithContext(allocator, file_path.?) catch |err| {
        // For file I/O errors, we don't have source context
        if (json_output) {
            try json_error.reportErrorAsJson(stderr, file_path.?, &error_context.ErrorContext.init(allocator), @errorName(err), @errorName(err), null);
        } else {
            try reportError(stderr, file_path.?, file_content, err, null);
        }
        return .{ .exit_code = 1 };
    };
    defer result.deinit();

    if (result.output) |output| {
        try stdout.print("{s}\n", .{output.text});
        return .{ .exit_code = 0 };
    } else {
        // Error occurred during parsing/evaluation
        // Use the file content we read, not the one from error context (which might be deallocated)
        if (json_output) {
            try json_error.reportErrorAsJson(stderr, file_path.?, &result.error_ctx, "ParseError", "An error occurred at this location.", null);
        } else {
            try reportErrorWithContext(stderr, file_path.?, file_content, &result.error_ctx);
        }
        return .{ .exit_code = 1 };
    }
}

fn reportErrorWithContext(stderr: anytype, filename: []const u8, source: []const u8, err_ctx: *const error_context.ErrorContext) !void {
    // Determine which error to report (we don't have the error type here, so use the location)
    const error_info = if (err_ctx.last_error_location) |loc| blk: {
        // We have location info - show it!
        break :blk error_reporter.ErrorInfo{
            .title = "Parse or evaluation error",
            .location = loc,
            .message = if (err_ctx.last_error_token_lexeme) |_|
                "An error occurred at this location."
            else
                "An error occurred at this location.",
            .suggestion = null,
        };
    } else error_reporter.ErrorInfo{
        .title = "Error",
        .location = null,
        .message = "An error occurred during evaluation.",
        .suggestion = null,
    };

    try error_reporter.reportError(stderr, source, filename, error_info);
}

fn reportError(stderr: anytype, filename: []const u8, source: []const u8, err: anyerror, err_ctx: ?*const error_context.ErrorContext) !void {
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
        error.UnexpectedToken => error_reporter.ErrorInfo{
            .title = "Unexpected token",
            .location = location,
            .message = "Found an unexpected token.",
            .suggestion = "Check the syntax at this location.",
        },
        error.UnknownIdentifier => error_reporter.ErrorInfo{
            .title = "Unknown identifier",
            .location = null,
            .message = "This identifier is not defined in the current scope.",
            .suggestion = "Check the spelling or define this variable before using it.",
        },
        error.TypeMismatch => error_reporter.ErrorInfo{
            .title = "Type mismatch",
            .location = null,
            .message = error_reporter.ErrorMessages.typeMismatch("", ""),
            .suggestion = error_reporter.ErrorSuggestions.typeMismatch(),
        },
        error.ExpectedFunction => error_reporter.ErrorInfo{
            .title = "Expected function",
            .location = null,
            .message = error_reporter.ErrorMessages.expectedFunction(),
            .suggestion = error_reporter.ErrorSuggestions.expectedFunction(),
        },
        error.ModuleNotFound => error_reporter.ErrorInfo{
            .title = "Module not found",
            .location = null,
            .message = "Could not find the imported module.",
            .suggestion = "Make sure the module file exists in the correct location.",
        },
        error.WrongNumberOfArguments => error_reporter.ErrorInfo{
            .title = "Wrong number of arguments",
            .location = null,
            .message = "Function called with wrong number of arguments.",
            .suggestion = "Check the function signature and call it with the correct number of arguments.",
        },
        error.InvalidArgument => error_reporter.ErrorInfo{
            .title = "Invalid argument",
            .location = null,
            .message = error_reporter.ErrorMessages.invalidArgument(),
            .suggestion = "Check that the argument value is valid for this operation.",
        },
        else => error_reporter.ErrorInfo{
            .title = "Error",
            .location = null,
            .message = @errorName(err),
            .suggestion = null,
        },
    };

    try error_reporter.reportError(stderr, source, filename, error_info);
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
        const path = args[0];

        // Check if it's a directory
        const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr.print("error: path not found: {s}\n", .{path});
                return .{ .exit_code = 1 };
            },
            else => return err,
        };

        if (stat.kind == .directory) {
            // Run all specs in the directory recursively
            const result = spec.runAllSpecs(allocator, path, stdout) catch |err| {
                try stderr.print("error: failed to run specs: {}\n", .{err});
                return .{ .exit_code = 1 };
            };
            return .{ .exit_code = result.exitCode() };
        } else {
            // Run the specific spec file
            const result = spec.runSpec(allocator, path, stdout) catch |err| {
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
