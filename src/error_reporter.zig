const std = @import("std");

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
    message: []const u8,
    suggestion: ?[]const u8,
};

/// Report an error with full context to any writer
pub fn reportError(writer: anytype, source: []const u8, filename: []const u8, info: ErrorInfo) !void {
    const w = writer;

    // Print error title in red
    try w.writeAll("\x1b[1;31merror:\x1b[0m \x1b[1m");
    try w.writeAll(info.title);
    try w.writeAll("\x1b[0m\n");

    // If we have a location, show the source context
    if (info.location) |loc| {
        try showSourceContext(w, source, filename, loc);
    }

    // Print the error message
    try w.writeAll("\n");
    try w.writeAll(info.message);
    try w.writeAll("\n");

    // Print suggestion if available
    if (info.suggestion) |suggestion| {
        try w.writeAll("\n\x1b[1;36mhelp:\x1b[0m ");
        try w.writeAll(suggestion);
        try w.writeAll("\n");
    }
}

/// Show source code context with line numbers and error marker
fn showSourceContext(writer: anytype, source: []const u8, filename: []const u8, loc: SourceLocation) !void {
    const w = writer;

    // Find the line containing the error
    const line_start = findLineStart(source, loc.offset);
    const line_end = findLineEnd(source, loc.offset);
    const line_content = source[line_start..line_end];

        // Calculate padding for line numbers (we show 3 lines max, so we need space for the biggest number)
        const line_num_width = countDigits(loc.line + 1);

    // Show location (filename:line:column)
    try w.writeAll("  \x1b[1;34m-->\x1b[0m ");
    try w.writeAll(filename);
    try w.print(":{d}:{d}\n", .{ loc.line, loc.column });

    // Show empty line with gutter
    try writeGutter(w, line_num_width, null);
    try w.writeAll("\n");

    // Show the error line
    try writeGutter(w, line_num_width, loc.line);
    try w.writeAll(" ");
    try w.writeAll(line_content);
    try w.writeAll("\n");

    // Show the error marker (caret/underline)
    try writeGutter(w, line_num_width, null);
    try w.writeAll(" ");

    // Write spaces up to the error column
    const column_offset = loc.column - 1;
    var i: usize = 0;
    while (i < column_offset) : (i += 1) {
        try w.writeAll(" ");
    }

    // Write the caret/underline in red
    try w.writeAll("\x1b[1;31m");
    if (loc.length <= 1) {
        try w.writeAll("^");
    } else {
        // Underline the entire token
        var j: usize = 0;
        while (j < loc.length) : (j += 1) {
            try w.writeAll("^");
        }
    }
    try w.writeAll("\x1b[0m\n");
}

/// Write the line number gutter
fn writeGutter(writer: anytype, width: usize, line_num: ?usize) !void {
    if (line_num) |num| {
        try writer.print("\x1b[1;34m{d:>[1]}\x1b[0m |", .{ num, width });
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
