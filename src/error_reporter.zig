//! Pretty error reporting with source context.
//!
//! This module formats errors with:
//! - File location indicators (--> file.lazy:10:5)
//! - Source line excerpts with line numbers
//! - Caret/underline highlighting of error locations
//! - Colored output (respects NO_COLOR environment variable)
//! - Secondary location support for multi-location errors
//!
//! Example output:
//!   error: Unknown identifier
//!   --> example.lazy:5:12
//!   5 |   let result = unknownVar + 42
//!                    ^^^^^^^^^^
//!   Identifier `unknownVar` is not defined in the current scope.
//!   help: Check the spelling or define this variable before using it.
//!
//! The reporter works with ErrorInfo structures that contain:
//! - Error title and message
//! - Source location(s)
//! - Helpful suggestions
//!
//! Color support can be disabled by setting the NO_COLOR environment variable.

const std = @import("std");
const error_context = @import("error_context.zig");

/// Check if colors should be used in error output
/// Respects NO_COLOR environment variable (https://no-color.org/)
pub fn shouldUseColors() bool {
    // Check NO_COLOR environment variable
    if (std.process.hasEnvVarConstant("NO_COLOR")) {
        return false;
    }
    // Default to colors enabled
    return true;
}

// ============================================================================
// Color Helper Functions
// ============================================================================

/// Write text with ANSI color codes (only if colors are enabled)
fn colored(writer: anytype, text: []const u8, code: []const u8, use_colors: bool) !void {
    if (use_colors) {
        try writer.writeAll(code);
        try writer.writeAll(text);
        try writer.writeAll("\x1b[0m");
    } else {
        try writer.writeAll(text);
    }
}

/// Write text in bold red (for error labels and carets)
fn boldRed(writer: anytype, text: []const u8, use_colors: bool) !void {
    try colored(writer, text, "\x1b[1;31m", use_colors);
}

/// Write text in bold blue (for line numbers, arrows, and vertical bars)
fn boldBlue(writer: anytype, text: []const u8, use_colors: bool) !void {
    try colored(writer, text, "\x1b[1;34m", use_colors);
}

/// Write text in bold cyan (for help labels)
fn boldCyan(writer: anytype, text: []const u8, use_colors: bool) !void {
    try colored(writer, text, "\x1b[1;36m", use_colors);
}

/// Write text in bold (for error titles)
fn bold(writer: anytype, text: []const u8, use_colors: bool) !void {
    try colored(writer, text, "\x1b[1m", use_colors);
}

// ============================================================================

/// Source location information for error reporting
pub const SourceLocation = struct {
    line: usize, // 1-indexed
    column: usize, // 1-indexed
    offset: usize, // byte offset in source
    length: usize, // length of the problematic token/span
};

/// Error information for pretty-printing
pub const ErrorInfo = struct {
    title: []const u8,
    location: ?SourceLocation,
    secondary_location: ?SourceLocation = null,
    location_label: ?[]const u8 = null,
    secondary_label: ?[]const u8 = null,
    message: []const u8,
    suggestion: ?[]const u8,
    stack_trace: ?[]error_context.StackFrame = null,
};

/// Report an error with full context to any writer
pub fn reportError(writer: anytype, source: []const u8, filename: []const u8, info: ErrorInfo, use_colors: bool) !void {
    const w = writer;

    // Print error title
    try boldRed(w, "error:", use_colors);
    try w.writeAll(" ");
    try bold(w, info.title, use_colors);
    try w.writeAll("\n");

    // If we have a location, show the source context
    if (info.location) |loc| {
        if (info.secondary_location) |sec_loc| {
            // We have both primary and secondary locations
            // Check if they're on the same line
            if (loc.line == sec_loc.line) {
                // Same line - show both spans with labels on one source context
                try showSourceContextTwoSpans(w, source, filename, loc, sec_loc, info.location_label, info.secondary_label, use_colors);
            } else {
                // Different lines - show two separate source contexts
                const line_num_width = countDigits(loc.line + 1);
                try showSourceContext(w, source, filename, loc, use_colors);
                if (info.location_label) |label| {
                    try writeGutter(w, line_num_width, null, use_colors);
                    try w.writeAll(" ");
                    // Add spaces to align with the caret
                    var i: usize = 0;
                    while (i < loc.column - 1) : (i += 1) {
                        try w.writeAll(" ");
                    }
                    try w.writeAll(label);
                    try w.writeAll("\n");
                }
                // Add blank gutter line between contexts
                try writeGutter(w, line_num_width, null, use_colors);
                try w.writeAll("\n");
                try showSourceContext(w, source, filename, sec_loc, use_colors);
                if (info.secondary_label) |label| {
                    const sec_line_num_width = countDigits(sec_loc.line + 1);
                    try writeGutter(w, sec_line_num_width, null, use_colors);
                    try w.writeAll(" ");
                    // Add spaces to align with the caret
                    var i: usize = 0;
                    while (i < sec_loc.column - 1) : (i += 1) {
                        try w.writeAll(" ");
                    }
                    try w.writeAll(label);
                    try w.writeAll("\n");
                }
            }
        } else {
            // Only primary location
            try showSourceContext(w, source, filename, loc, use_colors);
        }
    }

    // Print the error message (skip if empty)
    if (info.message.len > 0) {
        try w.writeAll("\n");
        try w.writeAll(info.message);
        try w.writeAll("\n");
    }

    // Print suggestion if available
    if (info.suggestion) |suggestion| {
        try w.writeAll("\n");
        try boldCyan(w, "help:", use_colors);
        try w.writeAll(" ");
        try w.writeAll(suggestion);
        try w.writeAll("\n");
    }

    // Print stack trace if available
    if (info.stack_trace) |stack_trace| {
        if (stack_trace.len > 0) {
            try w.writeAll("\n");
            try bold(w, "Stack trace:", use_colors);
            try w.writeAll("\n");
            try showStackTrace(w, stack_trace, use_colors);
        }
    }
}

/// Display a stack trace
fn showStackTrace(writer: anytype, stack_trace: []error_context.StackFrame, use_colors: bool) !void {
    const w = writer;

    for (stack_trace, 0..) |frame, i| {
        try w.print("  {d}: ", .{i});

        if (frame.is_native) {
            try boldCyan(w, "[native] ", use_colors);
        }

        if (frame.function_name) |name| {
            try bold(w, name, use_colors);
        } else {
            try w.writeAll("<anonymous>");
        }

        try w.writeAll("\n     at ");
        try w.writeAll(frame.filename);
        try w.print(":{d}:{d}\n", .{ frame.location.line, frame.location.column });
    }
}

/// Show source code context with two spans on the same line
fn showSourceContextTwoSpans(
    writer: anytype,
    source: []const u8,
    filename: []const u8,
    loc1: SourceLocation,
    loc2: SourceLocation,
    label1: ?[]const u8,
    label2: ?[]const u8,
    use_colors: bool,
) !void {
    const w = writer;

    const line_num_width = countDigits(loc1.line + 1);

    // Show location (filename:line:column)
    try w.writeAll("  ");
    try boldBlue(w, "-->", use_colors);
    try w.writeAll(" ");
    try w.writeAll(filename);
    try w.print(":{d}:{d}\n", .{ loc1.line, loc1.column });

    // Check if offset is valid for this source
    if (loc1.offset >= source.len or loc2.offset >= source.len) {
        try w.writeAll("  ");
        try boldBlue(w, "|", use_colors);
        try w.writeAll("\n");
        try w.writeAll("  ");
        try boldBlue(w, "|", use_colors);
        try w.writeAll(" (Source context unavailable - error is in imported module)\n");
        try w.writeAll("  ");
        try boldBlue(w, "|", use_colors);
        try w.writeAll("\n\n");
        return;
    }

    // Find the line containing the error
    const line_start = findLineStart(source, loc1.offset);
    const line_end = findLineEnd(source, loc1.offset);
    const line_content = source[line_start..line_end];

    // Limit line content length
    const max_line_length = 200;
    const display_line_content = if (line_content.len > max_line_length)
        line_content[0..max_line_length]
    else
        line_content;
    const was_truncated = line_content.len > max_line_length;

    // Show empty line with gutter
    try writeGutter(w, line_num_width, null, use_colors);
    try w.writeAll("\n");

    // Show the error line
    try writeGutter(w, line_num_width, loc1.line, use_colors);
    try w.writeAll(" ");
    try w.writeAll(display_line_content);
    if (was_truncated) {
        try w.writeAll("...");
    }
    try w.writeAll("\n");

    // Show the error markers (carets) for both locations
    try writeGutter(w, line_num_width, null, use_colors);
    try w.writeAll(" ");

    // Determine which location comes first
    const first_loc = if (loc1.column <= loc2.column) loc1 else loc2;
    const second_loc = if (loc1.column <= loc2.column) loc2 else loc1;
    const first_label = if (loc1.column <= loc2.column) label1 else label2;
    const second_label = if (loc1.column <= loc2.column) label2 else label1;

    // Write spaces up to the first error column
    var i: usize = 0;
    while (i < first_loc.column - 1) : (i += 1) {
        try w.writeAll(" ");
    }

    // Write the first caret
    try boldRed(w, "^", use_colors);

    // Write spaces between the two carets
    // After writing the first caret at column N, we need (second_column - first_column - 1) spaces
    var j: usize = first_loc.column + 1;
    while (j < second_loc.column) : (j += 1) {
        try w.writeAll(" ");
    }

    // Write the second caret
    try boldRed(w, "^", use_colors);
    try w.writeAll("\n");

    // Show labels with connecting lines if provided
    if (first_label != null or second_label != null) {
        // Show vertical bars
        try writeGutter(w, line_num_width, null, use_colors);
        try w.writeAll(" ");
        i = 0;
        while (i < first_loc.column - 1) : (i += 1) {
            try w.writeAll(" ");
        }
        try boldBlue(w, "|", use_colors);
        j = first_loc.column + 1;
        while (j < second_loc.column) : (j += 1) {
            try w.writeAll(" ");
        }
        try boldBlue(w, "|", use_colors);
        try w.writeAll("\n");

        // Show second label first (rightmost label)
        if (second_label) |label| {
            try writeGutter(w, line_num_width, null, use_colors);
            try w.writeAll(" ");
            // Write first bar (no label)
            i = 0;
            while (i < first_loc.column - 1) : (i += 1) {
                try w.writeAll(" ");
            }
            try boldBlue(w, "|", use_colors);
            // Write spaces to reach second caret column, then label
            j = first_loc.column + 1;
            while (j < second_loc.column) : (j += 1) {
                try w.writeAll(" ");
            }
            try w.writeAll(label);
            try w.writeAll("\n");
        }

        // Show first label second (leftmost label)
        if (first_label) |label| {
            try writeGutter(w, line_num_width, null, use_colors);
            try w.writeAll(" ");
            i = 0;
            while (i < first_loc.column - 1) : (i += 1) {
                try w.writeAll(" ");
            }
            try w.writeAll(label);
            try w.writeAll("\n");
        }
    }
}

/// Show source code context with line numbers and error marker
fn showSourceContext(writer: anytype, source: []const u8, filename: []const u8, loc: SourceLocation, use_colors: bool) !void {
    const w = writer;

    // Show location (filename:line:column)
    try w.writeAll("  ");
    try boldBlue(w, "-->", use_colors);
    try w.writeAll(" ");
    try w.writeAll(filename);
    try w.print(":{d}:{d}\n", .{ loc.line, loc.column });

    // Check if offset is valid for this source
    if (loc.offset >= source.len) {
        // Offset is beyond source length - this means we're trying to show
        // an error from a different file. Don't show source context.
        try w.writeAll("  ");
        try boldBlue(w, "|", use_colors);
        try w.writeAll("\n");
        try w.writeAll("  ");
        try boldBlue(w, "|", use_colors);
        try w.writeAll(" (Source context unavailable - error is in imported module)\n");
        try w.writeAll("  ");
        try boldBlue(w, "|", use_colors);
        try w.writeAll("\n\n");
        return;
    }

    // Find the line containing the error
    const line_start = findLineStart(source, loc.offset);
    const line_end = findLineEnd(source, loc.offset);
    const line_content = source[line_start..line_end];

    // Limit line content length to prevent showing huge amounts of code
    const max_line_length = 200;
    const display_line_content = if (line_content.len > max_line_length)
        line_content[0..max_line_length]
    else
        line_content;
    const was_truncated = line_content.len > max_line_length;

        // Calculate padding for line numbers (we show 3 lines max, so we need space for the biggest number)
        const line_num_width = countDigits(loc.line + 1);

    // Show empty line with gutter
    try writeGutter(w, line_num_width, null, use_colors);
    try w.writeAll("\n");

    // Show the error line
    try writeGutter(w, line_num_width, loc.line, use_colors);
    try w.writeAll(" ");
    try w.writeAll(display_line_content);
    if (was_truncated) {
        try w.writeAll("...");
    }
    try w.writeAll("\n");

    // Show the error marker (caret/underline)
    try writeGutter(w, line_num_width, null, use_colors);
    try w.writeAll(" ");

    // Write spaces up to the error column
    const column_offset = loc.column - 1;
    var i: usize = 0;
    while (i < column_offset) : (i += 1) {
        try w.writeAll(" ");
    }

    // Write the caret/underline
    if (loc.length <= 1) {
        try boldRed(w, "^", use_colors);
    } else if (loc.length == 2) {
        try boldRed(w, "^^", use_colors);
    } else {
        // For longer spans, use ^--- style
        if (use_colors) try w.writeAll("\x1b[1;31m");
        try w.writeAll("^");
        var j: usize = 1;
        while (j < loc.length) : (j += 1) {
            try w.writeAll("-");
        }
        if (use_colors) try w.writeAll("\x1b[0m");
    }
    try w.writeAll("\n");
}

/// Write the line number gutter
fn writeGutter(writer: anytype, width: usize, line_num: ?usize, use_colors: bool) !void {
    if (line_num) |num| {
        // Write line number in bold blue
        if (use_colors) try writer.writeAll("\x1b[1;34m");
        try writer.print("{d:>[1]}", .{ num, width });
        if (use_colors) try writer.writeAll("\x1b[0m");
        try writer.writeAll(" |");
    } else {
        // Empty gutter
        var i: usize = 0;
        while (i < width) : (i += 1) {
            try writer.writeAll(" ");
        }
        try writer.writeAll(" |");
    }
}

/// Find the start of the line containing the given offset
fn findLineStart(source: []const u8, offset: usize) usize {
    if (offset >= source.len) return 0;
    var i = offset;
    while (i > 0) {
        i -= 1;
        if (source[i] == '\n') {
            return i + 1;
        }
    }
    return 0;
}

/// Find the end of the line containing the given offset
fn findLineEnd(source: []const u8, offset: usize) usize {
    if (offset >= source.len) return source.len;
    var i = offset;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            return i;
        }
    }
    return source.len;
}

/// Convert a byte offset to a source location (line and column)
pub fn offsetToLocation(source: []const u8, offset: usize) SourceLocation {
    var line: usize = 1;
    var column: usize = 1;
    var i: usize = 0;

    while (i < offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }

    return .{
        .line = line,
        .column = column,
        .offset = offset,
        .length = 1,
    };
}

/// Count the number of digits in a number (for padding)
fn countDigits(n: usize) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var num = n;
    while (num > 0) : (num /= 10) {
        count += 1;
    }
    return count;
}

/// Helper to create common error messages
pub const ErrorMessages = struct {
    pub fn unexpectedCharacter(char: u8) []const u8 {
        _ = char;
        return "Unexpected character in input.";
    }

    pub fn unterminatedString() []const u8 {
        return "String literal is not closed. Add a closing quote.";
    }

    pub fn expectedExpression() []const u8 {
        return "Expected an expression here, but found something else.";
    }

    pub fn unexpectedToken(found: []const u8, expected: []const u8) []const u8 {
        _ = found;
        _ = expected;
        return "Unexpected token.";
    }

    pub fn unknownIdentifier(name: []const u8) []const u8 {
        _ = name;
        return "This identifier is not defined in the current scope.";
    }

    pub fn typeMismatch(expected: []const u8, found: []const u8) []const u8 {
        _ = expected;
        _ = found;
        return "Type mismatch: operation expected a different type.";
    }

    pub fn expectedFunction() []const u8 {
        return "Tried to call a value that is not a function.";
    }

    pub fn moduleNotFound(path: []const u8) []const u8 {
        _ = path;
        return "Could not find the imported module.";
    }

    pub fn wrongNumberOfArguments(expected: usize, got: usize) []const u8 {
        _ = expected;
        _ = got;
        return "Function called with wrong number of arguments.";
    }

    pub fn invalidArgument() []const u8 {
        return "Invalid argument value.";
    }
};

/// Helper to create suggestions for common errors
pub const ErrorSuggestions = struct {
    pub fn unterminatedString() []const u8 {
        return "Add a matching quote character to close the string.";
    }

    pub fn unknownIdentifier(name: []const u8) []const u8 {
        _ = name;
        return "Check the spelling or define this variable before using it.";
    }

    pub fn typeMismatch() []const u8 {
        return "Check that you're using the right type for this operation.";
    }

    pub fn moduleNotFound(path: []const u8) []const u8 {
        _ = path;
        return "Make sure the module file exists in the correct location.";
    }

    pub fn expectedFunction() []const u8 {
        return "Only functions can be called. Make sure this value is a function.";
    }
};
