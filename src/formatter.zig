const std = @import("std");
const evaluator = @import("eval.zig");

pub const FormatterError = error{
    ParseError,
    FormatError,
} || std.mem.Allocator.Error;

pub const FormatterOutput = struct {
    text: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FormatterOutput) void {
        self.allocator.free(self.text);
    }
};

/// Format a Lazylang source string
pub fn formatSource(allocator: std.mem.Allocator, source: []const u8) FormatterError!FormatterOutput {
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    var tokenizer = evaluator.Tokenizer.init(source);
    var indent_level: usize = 0;
    var prev_token: ?evaluator.TokenKind = null;
    var at_line_start = true;

    while (true) {
        const token = tokenizer.next() catch {
            return FormatterError.ParseError;
        };

        if (token.kind == .eof) break;

        // Handle closing brace indentation - decrease before writing
        if (token.kind == .r_brace or token.kind == .r_bracket) {
            if (indent_level > 0) {
                indent_level -= 1;
            }
        }

        // Handle newlines
        if (token.preceded_by_newline) {
            try output.append(allocator, '\n');
            at_line_start = true;
        }

        // Add space before token if needed (before indentation)
        const needs_space_before = !at_line_start and prev_token != null and needsSpaceBefore(prev_token.?, token.kind);

        // Write indentation at line start
        if (at_line_start and token.kind != .eof) {
            for (0..indent_level) |_| {
                try output.appendSlice(allocator, "  ");
            }
            at_line_start = false;
        } else if (needs_space_before) {
            // Only add space if we didn't just write indentation
            try output.append(allocator, ' ');
        }

        // Write the token
        if (token.kind == .string) {
            // String tokens don't include quotes in lexeme, so add them
            try output.append(allocator, '"');
            try output.appendSlice(allocator, token.lexeme);
            try output.append(allocator, '"');
        } else {
            try output.appendSlice(allocator, token.lexeme);
        }

        // Update indentation for opening braces
        if (token.kind == .l_brace or token.kind == .l_bracket) {
            indent_level += 1;
        }

        prev_token = token.kind;
    }

    // Ensure file ends with newline
    if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
        try output.append(allocator, '\n');
    }

    const formatted = try output.toOwnedSlice(allocator);
    return FormatterOutput{
        .text = formatted,
        .allocator = allocator,
    };
}

/// Format a file and return the formatted source
pub fn formatFile(allocator: std.mem.Allocator, file_path: []const u8) FormatterError!FormatterOutput {
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        return FormatterError.ParseError;
    };
    defer file.close();

    const source = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return FormatterError.ParseError;
    };
    defer allocator.free(source);

    return formatSource(allocator, source);
}

fn needsSpaceBefore(prev: evaluator.TokenKind, current: evaluator.TokenKind) bool {
    // No space after opening brackets/parens or before closing ones
    if (prev == .l_paren or prev == .l_bracket or prev == .l_brace) {
        return false;
    }
    if (current == .r_paren or current == .r_bracket or current == .r_brace) {
        return false;
    }

    // No space before comma, colon, or semicolon
    if (current == .comma or current == .colon or current == .semicolon) {
        return false;
    }

    // Space after comma, colon, semicolon
    if (prev == .comma or prev == .semicolon) {
        return true;
    }

    // Space around equals and arrow
    if (prev == .equals or current == .equals) {
        return true;
    }
    if (prev == .arrow or current == .arrow) {
        return true;
    }

    // Space after colon
    if (prev == .colon) {
        return true;
    }

    // Space between identifiers, numbers, strings, symbols
    if ((prev == .identifier or prev == .number or prev == .string or prev == .symbol) and
        (current == .identifier or current == .number or current == .string or current == .symbol))
    {
        return true;
    }

    // Space between closing and opening brackets/parens
    if ((prev == .r_paren or prev == .r_bracket or prev == .r_brace) and
        (current == .l_paren or current == .l_bracket or current == .l_brace or
        current == .identifier or current == .number or current == .string or current == .symbol))
    {
        return true;
    }

    // Space around operators
    if (prev == .plus or prev == .minus or prev == .star or
        current == .plus or current == .minus or current == .star)
    {
        return true;
    }

    return false;
}
