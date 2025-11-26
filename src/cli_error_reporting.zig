//! CLI error reporting and formatting.
//!
//! This module handles error reporting for the Lazylang CLI, converting
//! evaluation errors into human-readable messages with helpful suggestions.
//!
//! It provides two main functions:
//! - reportError: Formats specific error types with detailed messages
//! - reportErrorWithContext: Wrapper that handles user crashes and delegates to reportError
//!
//! Error types handled:
//! - Syntax errors (UnexpectedToken, UnterminatedString, etc.)
//! - Type errors (TypeMismatch, ExpectedFunction, etc.)
//! - Runtime errors (UnknownIdentifier, UnknownField, ModuleNotFound, etc.)
//! - Arithmetic errors (Overflow, DivisionByZero)
//! - User errors (UserCrash from crash() builtin)
//!
//! Each error type includes:
//! - A descriptive title
//! - Source location (when available)
//! - A clear explanation of what went wrong
//! - Helpful suggestions for fixing the issue

const std = @import("std");
const evaluator = @import("eval.zig");
const error_context = @import("error_context.zig");
const error_reporter = @import("error_reporter.zig");

pub fn reportErrorWithContext(
    allocator: std.mem.Allocator,
    stderr: anytype,
    filename: []const u8,
    source: []const u8,
    err_ctx: *const error_context.ErrorContext,
    err: ?anyerror,
    use_colors: bool,
) !void {
    // Check if it's a user crash
    if (evaluator.getUserCrashMessage()) |crash_message| {
        const error_info = error_reporter.ErrorInfo{
            .title = "Runtime error",
            .location = null,
            .message = crash_message,
            .suggestion = null,
            .stack_trace = err_ctx.stack_trace,
        };
        try error_reporter.reportError(stderr, source, filename, error_info, use_colors);
        evaluator.clearUserCrashMessage();
        return;
    }

    // If we have the error type, use the detailed error reporting
    if (err) |error_type| {
        try reportError(allocator, stderr, filename, source, error_type, err_ctx, use_colors);
        return;
    }

    // Fall back to generic error reporting if we don't have the error type
    const error_info = if (err_ctx.last_error_location) |loc| blk: {
        break :blk error_reporter.ErrorInfo{
            .title = "Parse or evaluation error",
            .location = loc,
            .message = "An error occurred at this location.",
            .suggestion = null,
            .stack_trace = err_ctx.stack_trace,
        };
    } else error_reporter.ErrorInfo{
        .title = "Error",
        .location = null,
        .message = "An error occurred during evaluation.",
        .suggestion = null,
        .stack_trace = err_ctx.stack_trace,
    };

    try error_reporter.reportError(stderr, source, filename, error_info, use_colors);
}

pub fn reportError(
    allocator: std.mem.Allocator,
    stderr: anytype,
    filename: []const u8,
    source: []const u8,
    err: anyerror,
    err_ctx: ?*const error_context.ErrorContext,
    use_colors: bool,
) !void {
    // Use an arena allocator for all temporary error message strings
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const location = if (err_ctx) |ctx| ctx.last_error_location else null;
    const stack_trace = if (err_ctx) |ctx| ctx.stack_trace else null;

    const error_info = switch (err) {
        error.UnexpectedCharacter => error_reporter.ErrorInfo{
            .title = "Unexpected character",
            .location = location,
            .message = "Found an unexpected character in the source code.",
            .suggestion = "Remove the invalid character or check for typos.",
            .stack_trace = stack_trace,
        },
        error.UnterminatedString => error_reporter.ErrorInfo{
            .title = "Unterminated string",
            .location = location,
            .message = error_reporter.ErrorMessages.unterminatedString(),
            .suggestion = error_reporter.ErrorSuggestions.unterminatedString(),
            .stack_trace = stack_trace,
        },
        error.ExpectedExpression => error_reporter.ErrorInfo{
            .title = "Expected expression",
            .location = location,
            .message = error_reporter.ErrorMessages.expectedExpression(),
            .suggestion = "Add an expression here.",
            .stack_trace = stack_trace,
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
                            .stack_trace = stack_trace,
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
                        .stack_trace = stack_trace,
                    };
                }
            }
            break :blk error_reporter.ErrorInfo{
                .title = "Unexpected token",
                .location = location,
                .message = "Found an unexpected token.",
                .suggestion = "Check the syntax at this location.",
                .stack_trace = stack_trace,
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
                            .stack_trace = stack_trace,
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
                .stack_trace = stack_trace,
            };
        },
        error.TypeMismatch => blk: {
            if (err_ctx) |ctx| {
                switch (ctx.last_error_data) {
                    .type_mismatch => |data| {
                        const message = if (data.operation) |op| blk2: {
                            // Special formatting for function call pattern mismatches
                            if (std.mem.startsWith(u8, op, "calling function `")) {
                                // Extract function name from "calling function `f`"
                                const func_name_start = "calling function `".len;
                                const func_name_end = std.mem.indexOf(u8, op[func_name_start..], "`") orelse break :blk2 try std.fmt.allocPrint(arena_allocator, "Expected `{s}` for {s}, but found `{s}`.", .{ data.expected, op, data.found });
                                const func_name = op[func_name_start .. func_name_start + func_name_end];
                                break :blk2 try std.fmt.allocPrint(arena_allocator, "Function `{s}` expects {s}, but is being passed {s}.", .{ func_name, data.expected, data.found });
                            } else {
                                break :blk2 try std.fmt.allocPrint(arena_allocator, "Expected `{s}` for {s}, but found `{s}`.", .{ data.expected, op, data.found });
                            }
                        } else
                            try std.fmt.allocPrint(arena_allocator, "Expected `{s}`, but found `{s}`.", .{ data.expected, data.found });

                        break :blk error_reporter.ErrorInfo{
                            .title = "Type mismatch",
                            .location = location,
                            .message = message,
                            .suggestion = "Make sure you're using compatible types for this operation.",
                            .stack_trace = stack_trace,
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
                .stack_trace = stack_trace,
            };
        },
        error.ExpectedFunction => error_reporter.ErrorInfo{
            .title = "Not a function",
            .location = location,
            .message = "Attempted to call a value that is not a function.",
            .suggestion = "Only functions can be called with arguments. Make sure this value is a function.",
            .stack_trace = stack_trace,
        },
        error.ModuleNotFound => blk: {
            if (err_ctx) |ctx| {
                switch (ctx.last_error_data) {
                    .module_not_found => |data| {
                        const message = try std.fmt.allocPrint(arena_allocator, "Could not find module `{s}`.", .{data.module_name});
                        break :blk error_reporter.ErrorInfo{
                            .title = "Module not found",
                            .location = location,
                            .message = message,
                            .suggestion = "Check that the module path is correct and the file exists. Module paths are searched in LAZYLANG_PATH and stdlib/lib.",
                            .stack_trace = stack_trace,
                        };
                    },
                    else => {},
                }
            }

            break :blk error_reporter.ErrorInfo{
                .title = "Module not found",
                .location = location,
                .message = "Could not find the imported module file.",
                .suggestion = "Check that the module path is correct and the file exists. Module paths are searched in LAZYLANG_PATH and stdlib/lib.",
                .stack_trace = stack_trace,
            };
        },
        error.WrongNumberOfArguments => error_reporter.ErrorInfo{
            .title = "Wrong number of arguments",
            .location = location,
            .message = "Function was called with the wrong number of arguments.",
            .suggestion = "Check the function signature and provide the correct number of arguments.",
            .stack_trace = stack_trace,
        },
        error.InvalidArgument => error_reporter.ErrorInfo{
            .title = "Invalid argument",
            .location = location,
            .message = "An argument has an invalid value for this operation.",
            .suggestion = "Check that argument values are within valid ranges (e.g., array indices must be non-negative).",
            .stack_trace = stack_trace,
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
                            .stack_trace = stack_trace,
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
                .stack_trace = stack_trace,
            };
        },
        error.Overflow => error_reporter.ErrorInfo{
            .title = "Arithmetic overflow",
            .location = location,
            .message = "An arithmetic operation resulted in a value that's too large to represent.",
            .suggestion = "Use smaller numbers or break the calculation into smaller steps.",
            .stack_trace = stack_trace,
        },
        error.UserCrash => blk: {
            const crash_message = evaluator.getUserCrashMessage() orelse "Program crashed with no message.";
            break :blk error_reporter.ErrorInfo{
                .title = "Runtime error",
                .location = null,
                .message = crash_message,
                .suggestion = null,
                .stack_trace = stack_trace,
            };
        },
        error.CyclicReference => blk: {
            const secondary_location = if (err_ctx) |ctx| ctx.last_error_secondary_location else null;
            const location_label = if (err_ctx) |ctx| ctx.last_error_location_label else null;
            const secondary_label = if (err_ctx) |ctx| ctx.last_error_secondary_label else null;

            break :blk error_reporter.ErrorInfo{
                .title = "Cyclic reference",
                .location = location,
                .secondary_location = secondary_location,
                .location_label = location_label,
                .secondary_label = secondary_label,
                .message = "",
                .suggestion = "Break the circular dependency by using a non-recursive value.",
                .stack_trace = stack_trace,
            };
        },
        error.DivisionByZero => error_reporter.ErrorInfo{
            .title = "Division by zero",
            .location = location,
            .message = "Cannot divide by zero.",
            .suggestion = "Ensure the divisor is not zero before performing division.",
            .stack_trace = stack_trace,
        },
        else => error_reporter.ErrorInfo{
            .title = "Error",
            .location = null,
            .message = @errorName(err),
            .suggestion = null,
            .stack_trace = stack_trace,
        },
    };

    try error_reporter.reportError(stderr, source, filename, error_info, use_colors);
}
