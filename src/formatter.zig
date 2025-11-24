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
    // Create an arena for tokenizer allocations (doc comments, etc.)
    var tokenizer_arena = std.heap.ArenaAllocator.init(allocator);
    defer tokenizer_arena.deinit();

    // First pass: collect all tokens with their source positions
    var tokens = std.ArrayList(TokenInfo){};
    defer tokens.deinit(allocator);

    var tokenizer = evaluator.Tokenizer.init(source, tokenizer_arena.allocator());
    defer tokenizer.deinit();

    while (true) {
        const token = tokenizer.next() catch {
            return FormatterError.ParseError;
        };
        if (token.kind == .eof) break;

        // Use token's offset for accurate source position tracking
        const tok_start = token.offset;
        var tok_end = tok_start + token.lexeme.len;
        if (token.kind == .string) {
            tok_end += 2; // Account for quotes
        }

        try tokens.append(allocator, .{
            .token = token,
            .source_start = tok_start,
            .source_end = tok_end,
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

                // For multi-line brackets/braces in comprehensions, ensure closing bracket/brace is on new line
                if ((brace_info.brace_type == .bracket or brace_info.brace_type == .brace) and !brace_info.is_single_line and !token.preceded_by_newline) {
                    // Check if we recently saw a 'for' keyword (likely a comprehension)
                    if (i > 0 and prev_token == .identifier) {
                        try output.appendSlice(allocator, "\n");
                        at_line_start = true;
                    }
                }

                _ = brace_stack.pop();
                if (!brace_info.is_single_line and indent_level > 0) {
                    indent_level -= 1;
                }
                // Reset do_indent_level when exiting bracket/brace blocks
                if (!brace_info.is_single_line) {
                    do_indent_level = 0;
                }
            }
        }

        // Special handling for 'for' keyword in multi-line comprehensions
        // If we're in a multi-line bracket/brace and see 'for', it should be on its own line
        if (token.kind == .identifier and std.mem.eql(u8, token.lexeme, "for")) {
            var in_multiline_comprehension = false;
            for (brace_stack.items) |brace_info| {
                if ((brace_info.brace_type == .bracket or brace_info.brace_type == .brace) and !brace_info.is_single_line) {
                    in_multiline_comprehension = true;
                    break;
                }
            }

            if (in_multiline_comprehension and !token.preceded_by_newline) {
                // Add a newline before 'for' in multi-line comprehensions
                try output.appendSlice(allocator, "\n");
                at_line_start = true;
            }
        }

        // Handle newlines
        if (token.preceded_by_newline) {
            // Check if previous token was `do`, `where`, `matches`, or `->` to increase indent
            if (i > 0) {
                const prev_tok = tokens.items[i - 1].token;
                if (prev_tok.kind == .arrow) {
                    do_indent_level += 1;
                } else if (prev_tok.kind == .identifier and
                    (std.mem.eql(u8, prev_tok.lexeme, "do") or
                     std.mem.eql(u8, prev_tok.lexeme, "where") or
                     std.mem.eql(u8, prev_tok.lexeme, "matches"))) {
                    do_indent_level += 1;
                }
            }

            // Count newlines between previous token and this one
            var newline_count: usize = 1;
            if (i > 0) {
                const prev_info = tokens.items[i - 1];
                const between = source[prev_info.source_end..info.source_start];
                const raw_newline_count = countNewlines(between);

                // If this token has doc comments, the space between includes those doc comment lines.
                // We only want to preserve blank lines, not count doc comment lines.
                // So limit to 2 newlines (one blank line max) when doc comments are present.
                if (token.doc_comments != null) {
                    newline_count = @min(raw_newline_count, 2);
                } else {
                    newline_count = raw_newline_count;
                    // Still limit excessive blank lines to 2 (meaning 3 newlines)
                    if (newline_count > 3) newline_count = 3;
                }

                // Output the appropriate number of newlines
                for (0..newline_count) |_| {
                    try output.appendSlice(allocator, "\n");
                }
                at_line_start = true;
            } else {
                // First token - don't output newlines before it if it has doc comments
                if (token.doc_comments == null) {
                    for (0..newline_count) |_| {
                        try output.appendSlice(allocator, "\n");
                    }
                }
                at_line_start = true;
            }
        }

        // Calculate if we need space before this token
        // Get the token before prev_token for unary operator detection
        var token_before_prev: ?evaluator.TokenKind = null;
        if (i >= 2) {
            token_before_prev = tokens.items[i - 2].token.kind;
        }
        const needs_space_before = !at_line_start and prev_token != null and
            needsSpaceBefore(token_before_prev, prev_token.?, token.kind, brace_stack.items);

        // Reset do_indent_level if we're starting a new statement at array level
        if (at_line_start and token.kind == .identifier and do_indent_level > 0) {
            // Keywords that start new statements
            if (std.mem.eql(u8, token.lexeme, "it") or
                std.mem.eql(u8, token.lexeme, "describe")) {
                do_indent_level = 0;
            }
        }

        // Output doc comments before the token
        if (token.doc_comments) |docs| {
            // Split doc comments by newlines and output each line with proper indentation
            var lines = std.mem.splitScalar(u8, docs, '\n');
            while (lines.next()) |line| {
                // Write indentation if at line start
                if (at_line_start) {
                    const total_indent = indent_level + do_indent_level;
                    for (0..total_indent) |_| {
                        try output.appendSlice(allocator, "  ");
                    }
                }
                // Trim trailing whitespace from doc comment line
                const trimmed_line = std.mem.trimRight(u8, line, " \t");
                if (trimmed_line.len > 0) {
                    try output.appendSlice(allocator, "/// ");
                    try output.appendSlice(allocator, trimmed_line);
                } else {
                    // Empty line - just output ///
                    try output.appendSlice(allocator, "///");
                }
                try output.appendSlice(allocator, "\n");
                at_line_start = true;
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
        // For object projections (e.g., obj.{ x, y }), also add spaces
        // NOTE: If the brace has doc comments, it should always be treated as multi-line
        if (token.kind == .l_brace) {
            const has_docs = token.doc_comments != null;
            if (!has_docs) {
                if (brace_is_single_line.get(i)) |is_single| {
                    if (is_single) {
                        try output.appendSlice(allocator, "{ ");
                        try brace_stack.append(allocator, BraceInfo{ .brace_type = .brace, .is_single_line = true });
                        prev_token = token.kind;
                        continue;
                    }
                }
            }
        }

        // Skip semicolons in multi-line parenthesized blocks
        // (They're used for sequencing in let-bindings but shouldn't appear in formatted output)
        if (token.kind == .semicolon) {
            // Check if we're in a multi-line paren block
            var in_multiline_paren = false;
            for (brace_stack.items) |brace_info| {
                if (brace_info.brace_type == .paren and !brace_info.is_single_line) {
                    in_multiline_paren = true;
                    break;
                }
            }

            if (in_multiline_paren) {
                prev_token = token.kind;
                continue; // Skip this semicolon
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
            const is_single = brace_is_single_line.get(i) orelse true;
            try brace_stack.append(allocator, BraceInfo{ .brace_type = .paren, .is_single_line = is_single });
            if (!is_single) {
                indent_level += 1;
            }
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

/// Analyze which braces/brackets/parens are single-line
fn analyzeBraces(tokens: []const evaluator.Token, map: *std.AutoHashMap(usize, bool)) !void {
    var stack = std.ArrayList(usize){};
    defer stack.deinit(map.allocator);

    for (tokens, 0..) |token, i| {
        if (token.kind == .l_brace or token.kind == .l_bracket or token.kind == .l_paren) {
            try stack.append(map.allocator, i);
        } else if (token.kind == .r_brace or token.kind == .r_bracket or token.kind == .r_paren) {
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

fn needsSpaceBefore(token_before_prev: ?evaluator.TokenKind, prev: evaluator.TokenKind, current: evaluator.TokenKind, brace_stack: []const BraceInfo) bool {
    _ = brace_stack; // Not currently used, but may be needed for future rules

    // Space before opening paren after number/identifier/symbol (function call)
    if (current == .l_paren and (prev == .number or prev == .identifier or prev == .symbol)) {
        return true;
    }

    // No space after opening brackets/parens
    if (prev == .l_paren or prev == .l_bracket) {
        return false;
    }

    // Space before opening bracket after identifier/string/symbol/r_paren
    if (current == .l_bracket and (prev == .identifier or prev == .string or prev == .symbol or prev == .r_paren)) {
        return true;
    }

    // Space before opening brace after identifier/string/symbol/r_paren/r_bracket
    if (current == .l_brace and (prev == .identifier or prev == .string or prev == .symbol or prev == .r_paren or prev == .r_bracket)) {
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

    // Unary operators: no space after ! or - when used as unary
    // Unary context: after =, (, [, ,, or other operators
    const prev_is_unary_context = if (token_before_prev) |before|
        before == .equals or before == .l_paren or before == .l_bracket or
            before == .comma or before == .l_brace or
            before == .plus or before == .minus or before == .star or before == .slash or
            before == .ampersand_ampersand or before == .pipe_pipe
    else
        true; // At start of expression, treat as unary context

    // No space after unary ! or -
    if (prev_is_unary_context and (prev == .bang or prev == .minus)) {
        return false;
    }

    // Space around arithmetic operators (binary)
    if (prev == .plus or prev == .minus or prev == .star or prev == .slash or
        current == .plus or current == .minus or current == .star or current == .slash)
    {
        return true;
    }

    // Space around comparison operators
    if (prev == .less or prev == .greater or prev == .less_equals or prev == .greater_equals or
        prev == .equals_equals or prev == .bang_equals or
        current == .less or current == .greater or current == .less_equals or current == .greater_equals or
        current == .equals_equals or current == .bang_equals)
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
