const std = @import("std");
const evaluator = @import("eval.zig");

pub const TokenClass = enum {
    keyword,
    identifier,
    number,
    string,
    symbol,
    operator,
    comment,
    punctuation,

    pub fn toCssClass(self: TokenClass) []const u8 {
        return switch (self) {
            .keyword => "keyword",
            .identifier => "identifier",
            .number => "number",
            .string => "string",
            .symbol => "symbol",
            .operator => "operator",
            .comment => "comment",
            .punctuation => "punctuation",
        };
    }
};

pub const HighlightedToken = struct {
    text: []const u8,
    class: TokenClass,
};

/// Returns true if the identifier is a keyword
fn isKeyword(text: []const u8) bool {
    const keywords = &[_][]const u8{
        "if",      "then",   "else",     "when",  "matches",
        "otherwise", "for",    "in",       "when",  "import",
        "do",      "where",  "true",     "false", "null",
    };

    for (keywords) |keyword| {
        if (std.mem.eql(u8, text, keyword)) {
            return true;
        }
    }
    return false;
}

fn getTokenClass(kind: evaluator.TokenKind, lexeme: []const u8) TokenClass {
    return switch (kind) {
        .identifier => if (isKeyword(lexeme)) .keyword else .identifier,
        .number => .number,
        .string => .string,
        .symbol => .symbol,
        .comma, .semicolon => .punctuation,
        .colon, .equals, .arrow, .backslash, .dot, .dot_dot_dot => .operator,
        .plus, .minus, .star, .ampersand, .ampersand_ampersand => .operator,
        .pipe_pipe, .bang, .equals_equals, .bang_equals => .operator,
        .less, .greater, .less_equals, .greater_equals => .operator,
        .l_paren, .r_paren, .l_bracket, .r_bracket, .l_brace, .r_brace => .punctuation,
        .eof => .punctuation,
    };
}

/// Tokenize source code and return highlighted tokens
pub fn highlightCode(allocator: std.mem.Allocator, source: []const u8) ![]HighlightedToken {
    var result = std.ArrayList(HighlightedToken){};
    errdefer result.deinit(allocator);

    var tokenizer = evaluator.Tokenizer.init(source, allocator);

    var last_offset: usize = 0;

    while (true) {
        const token = tokenizer.next() catch |err| {
            // On error, include remaining text as plain identifier
            std.log.warn("Tokenizer error: {}", .{err});
            if (last_offset < source.len) {
                try result.append(allocator, .{
                    .text = source[last_offset..],
                    .class = .identifier,
                });
            }
            break;
        };

        if (token.kind == .eof) break;

        // Use token.offset which includes delimiters for strings
        const token_offset = token.offset;
        const token_end = if (token.kind == .string)
            // For strings, offset points to opening quote, lexeme is content, so end = offset + len + 2 quotes
            token_offset + token.lexeme.len + 2
        else
            token_offset + token.lexeme.len;

        // Add any whitespace/text between tokens as plain text
        if (token_offset > last_offset) {
            try result.append(allocator, .{
                .text = source[last_offset..token_offset],
                .class = .identifier, // Use identifier for whitespace (won't be styled)
            });
        }

        // Add the token (with quotes for strings)
        const token_text = if (token.kind == .string)
            source[token_offset..token_end]
        else
            token.lexeme;

        try result.append(allocator, .{
            .text = token_text,
            .class = getTokenClass(token.kind, token.lexeme),
        });

        last_offset = token_end;
    }

    // Add any remaining text
    if (last_offset < source.len) {
        try result.append(allocator, .{
            .text = source[last_offset..],
            .class = .identifier,
        });
    }

    return result.toOwnedSlice(allocator);
}

/// Convert highlighted tokens to HTML
pub fn toHtml(allocator: std.mem.Allocator, tokens: []const HighlightedToken) ![]const u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    for (tokens) |token| {
        // Check if this is just whitespace/plain text
        const is_plain = token.class == .identifier and (token.text.len == 0 or
            (std.mem.indexOfNone(u8, token.text, " \t\n\r") == null));

        if (is_plain) {
            // Escape HTML but don't wrap in span
            for (token.text) |c| {
                switch (c) {
                    '<' => try result.appendSlice(allocator, "&lt;"),
                    '>' => try result.appendSlice(allocator, "&gt;"),
                    '&' => try result.appendSlice(allocator, "&amp;"),
                    '"' => try result.appendSlice(allocator, "&quot;"),
                    else => try result.append(allocator, c),
                }
            }
        } else {
            // Wrap in span with class
            try result.appendSlice(allocator, "<span class=\"");
            try result.appendSlice(allocator, token.class.toCssClass());
            try result.appendSlice(allocator, "\">");

            // Escape HTML
            for (token.text) |c| {
                switch (c) {
                    '<' => try result.appendSlice(allocator, "&lt;"),
                    '>' => try result.appendSlice(allocator, "&gt;"),
                    '&' => try result.appendSlice(allocator, "&amp;"),
                    '"' => try result.appendSlice(allocator, "&quot;"),
                    else => try result.append(allocator, c),
                }
            }

            try result.appendSlice(allocator, "</span>");
        }
    }

    return result.toOwnedSlice(allocator);
}
