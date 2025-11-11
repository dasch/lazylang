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

const BraceType = enum {
    brace,
    bracket,
    paren,
};

const BraceInfo = struct {
    brace_type: BraceType,
    is_single_line: bool,
};

const TokenInfo = struct {
    token: evaluator.Token,
    source_start: usize,
    source_end: usize,
};

/// Count newlines in a slice
fn countNewlines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

/// Format a Lazylang source string
pub fn formatSource(allocator: std.mem.Allocator, source: []const u8) FormatterError!FormatterOutput {
    // First pass: collect all tokens with their source positions
    var tokens = std.ArrayList(TokenInfo){};
    defer tokens.deinit(allocator);

    var src_index: usize = 0;
    var tokenizer = evaluator.Tokenizer.init(source);
    while (true) {
        // Find where this token starts in source (after whitespace)
        while (src_index < source.len) {
            const c = source[src_index];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
            src_index += 1;
        }
        const tok_start = src_index;

        const token = tokenizer.next() catch {
            return FormatterError.ParseError;
        };
        if (token.kind == .eof) break;

        // Find where this token ends
        if (token.kind == .string) {
            // String tokens don't include quotes in lexeme
            src_index = tok_start + token.lexeme.len + 2; // +2 for quotes
        } else {
            src_index = tok_start + token.lexeme.len;
        }

        try tokens.append(allocator, .{
            .token = token,
            .source_start = tok_start,
            .source_end = src_index,
        });
    }

    // Determine which braces/brackets are single-line
    var brace_is_single_line = std.AutoHashMap(usize, bool).init(allocator);
    defer brace_is_single_line.deinit();

    // Extract just tokens for analysis
    var token_list = std.ArrayList(evaluator.Token){};
    defer token_list.deinit(allocator);
    for (tokens.items) |info| {
        try token_list.append(allocator, info.token);
    }
    try analyzeBraces(token_list.items, &brace_is_single_line);

    // Second pass: format based on analysis
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    var indent_level: usize = 0;
    var prev_token: ?evaluator.TokenKind = null;
    var at_line_start = true;
    var brace_stack = std.ArrayList(BraceInfo){};
    defer brace_stack.deinit(allocator);
    var do_indent_level: usize = 0; // Track additional indent from `do`

    for (tokens.items, 0..) |info, i| {
        const token = info.token;
        // For single-line objects/brackets, handle special spacing before popping stack
        if (token.kind == .r_brace and brace_stack.items.len > 0) {
            const brace_info = brace_stack.items[brace_stack.items.len - 1];
            if (brace_info.brace_type == .brace and brace_info.is_single_line) {
                try output.appendSlice(allocator, " }");
                _ = brace_stack.pop();
                prev_token = token.kind;
                continue;
            }
        }

        // Handle closing brace/bracket indentation - decrease before writing
        if (token.kind == .r_brace or token.kind == .r_bracket or token.kind == .r_paren) {
            if (brace_stack.items.len > 0) {
                const brace_info = brace_stack.items[brace_stack.items.len - 1];
                _ = brace_stack.pop();
                if (!brace_info.is_single_line and indent_level > 0) {
                    indent_level -= 1;
                }
                // Reset do_indent_level when exiting bracket/brace blocks
                if (brace_info.brace_type == .bracket and !brace_info.is_single_line) {
                    do_indent_level = 0;
                }
            }
        }

        // Handle newlines
        if (token.preceded_by_newline) {
            // Check if previous token was `do` or `where` to increase indent
            if (i > 0) {
                const prev_tok = tokens.items[i - 1].token;
                if (prev_tok.kind == .identifier and
                    (std.mem.eql(u8, prev_tok.lexeme, "do") or std.mem.eql(u8, prev_tok.lexeme, "where"))) {
                    do_indent_level += 1;
                }
            }

            // Count newlines between previous token and this one
            var newline_count: usize = 1;
            if (i > 0) {
                const prev_info = tokens.items[i - 1];
                const between = source[prev_info.source_end..info.source_start];
                newline_count = countNewlines(between);
            }

            // Output the appropriate number of newlines
            for (0..newline_count) |_| {
                try output.appendSlice(allocator, "\n");
            }
            at_line_start = true;
        }

        // Calculate if we need space before this token
        const needs_space_before = !at_line_start and prev_token != null and
            needsSpaceBefore(prev_token.?, token.kind, brace_stack.items);

        // Reset do_indent_level if we're starting a new statement at array level
        if (at_line_start and token.kind == .identifier and do_indent_level > 0) {
            // Keywords that start new statements
            if (std.mem.eql(u8, token.lexeme, "it") or
                std.mem.eql(u8, token.lexeme, "describe")) {
                do_indent_level = 0;
            }
        }

        // Write indentation at line start
        if (at_line_start and token.kind != .eof) {
            const total_indent = indent_level + do_indent_level;
            for (0..total_indent) |_| {
                try output.appendSlice(allocator, "  ");
            }
            at_line_start = false;
        } else if (needs_space_before) {
            try output.appendSlice(allocator, " ");
        }

        // For single-line objects, add space after opening brace
        if (token.kind == .l_brace) {
            if (brace_is_single_line.get(i)) |is_single| {
                if (is_single) {
                    try output.appendSlice(allocator, "{ ");
                    try brace_stack.append(allocator, BraceInfo{ .brace_type = .brace, .is_single_line = true });
                    prev_token = token.kind;
                    continue;
                }
            }
        }

        // Write the token
        if (token.kind == .string) {
            try output.appendSlice(allocator, "\"");
            try output.appendSlice(allocator, token.lexeme);
            try output.appendSlice(allocator, "\"");
        } else {
            try output.appendSlice(allocator, token.lexeme);
        }

        // Update indentation for opening braces/brackets
        if (token.kind == .l_brace) {
            const is_single = brace_is_single_line.get(i) orelse false;
            try brace_stack.append(allocator, BraceInfo{ .brace_type = .brace, .is_single_line = is_single });
            if (!is_single) {
                indent_level += 1;
            }
        } else if (token.kind == .l_bracket) {
            const is_single = brace_is_single_line.get(i) orelse false;
            try brace_stack.append(allocator, BraceInfo{ .brace_type = .bracket, .is_single_line = is_single });
            if (!is_single) {
                indent_level += 1;
                // Reset do indent when entering a bracket block
                do_indent_level = 0;
            }
        } else if (token.kind == .l_paren) {
            try brace_stack.append(allocator, BraceInfo{ .brace_type = .paren, .is_single_line = true });
        }

        prev_token = token.kind;
    }

    // Ensure file ends with newline
    if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
        try output.appendSlice(allocator, "\n");
    }

    return FormatterOutput{
        .text = try output.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Analyze which braces/brackets are single-line
fn analyzeBraces(tokens: []const evaluator.Token, map: *std.AutoHashMap(usize, bool)) !void {
    var stack = std.ArrayList(usize){};
    defer stack.deinit(map.allocator);

    for (tokens, 0..) |token, i| {
        if (token.kind == .l_brace or token.kind == .l_bracket) {
            try stack.append(map.allocator, i);
        } else if (token.kind == .r_brace or token.kind == .r_bracket) {
            if (stack.items.len > 0) {
                const open_idx = stack.items[stack.items.len - 1];
                _ = stack.pop();
                // Check if there's a newline between open and close
                var has_newline = false;
                for (tokens[open_idx + 1 .. i]) |t| {
                    if (t.preceded_by_newline) {
                        has_newline = true;
                        break;
                    }
                }
                try map.put(open_idx, !has_newline);
            }
        }
    }
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

fn needsSpaceBefore(prev: evaluator.TokenKind, current: evaluator.TokenKind, brace_stack: []const BraceInfo) bool {
    _ = brace_stack; // Not currently used, but may be needed for future rules

    // Space before opening paren after number/identifier/symbol (function call)
    if (current == .l_paren and (prev == .number or prev == .identifier or prev == .symbol)) {
        return true;
    }

    // No space after opening brackets/parens
    if (prev == .l_paren or prev == .l_bracket) {
        return false;
    }

    // Space before opening bracket after identifier/string/r_paren
    if (current == .l_bracket and (prev == .identifier or prev == .string or prev == .r_paren)) {
        return true;
    }

    // Space after opening brace only handled specially in main loop
    if (prev == .l_brace) {
        return false;
    }

    // No space before closing brackets/parens
    if (current == .r_paren or current == .r_bracket) {
        return false;
    }

    // Space before closing brace only handled specially in main loop
    if (current == .r_brace) {
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

    // Space after colon
    if (prev == .colon) {
        return true;
    }

    // Space around equals and arrow
    if (prev == .equals or current == .equals) {
        return true;
    }
    if (prev == .arrow or current == .arrow) {
        return true;
    }

    // Space between identifiers, numbers, strings, symbols
    if ((prev == .identifier or prev == .number or prev == .string or prev == .symbol) and
        (current == .identifier or current == .number or current == .string or current == .symbol))
    {
        return true;
    }

    // Space between closing and opening brackets/parens/braces
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

    // Space around logical operators
    if (prev == .ampersand_ampersand or prev == .pipe_pipe or prev == .bang or
        current == .ampersand_ampersand or current == .pipe_pipe or current == .bang)
    {
        return true;
    }

    return false;
}
