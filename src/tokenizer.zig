//! Lexical analyzer (tokenizer) for Lazylang.
//!
//! The tokenizer converts source code into a stream of tokens. It handles:
//! - Single and multi-character operators (e.g., ==, !=, &&, ||)
//! - Keywords and identifiers
//! - Literals (numbers, strings, symbols)
//! - Comments (regular // and doc comments ///)
//! - Whitespace tracking for layout-sensitive parsing
//!
//! The tokenizer maintains line and column information for error reporting
//! and accumulates documentation comments to attach to the following token.
//!
//! Example:
//!     var tokenizer = Tokenizer.init(source, arena);
//!     const token = try tokenizer.next();

const std = @import("std");
const ast = @import("ast.zig");
const error_context = @import("error_context.zig");

pub const TokenizerError = error{
    UnexpectedCharacter,
    UnterminatedString,
    OutOfMemory,
};

pub const Tokenizer = struct {
    source: []const u8,
    index: usize,
    last_whitespace_had_newline: bool,
    last_had_whitespace: bool,
    line: usize, // current line number (1-indexed)
    column: usize, // current column number (1-indexed)
    line_start: usize, // byte offset of the current line start
    pending_doc_comments: std.ArrayListUnmanaged([]const u8),
    arena: std.mem.Allocator,
    error_ctx: ?*error_context.ErrorContext,

    pub fn init(source: []const u8, arena: std.mem.Allocator) Tokenizer {
        return .{
            .source = source,
            .index = 0,
            .last_whitespace_had_newline = false,
            .last_had_whitespace = false,
            .line = 1,
            .column = 1,
            .line_start = 0,
            .pending_doc_comments = .{},
            .arena = arena,
            .error_ctx = null,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.pending_doc_comments.deinit(self.arena);
    }

    pub fn next(self: *Tokenizer) TokenizerError!ast.Token {
        const ws_info = self.skipWhitespace();
        self.last_whitespace_had_newline = ws_info.saw_newline;
        self.last_had_whitespace = ws_info.had_whitespace;

        if (self.index >= self.source.len) {
            return .{
                .kind = .eof,
                .lexeme = self.source[self.source.len..self.source.len],
                .preceded_by_newline = ws_info.saw_newline,
                .preceded_by_whitespace = ws_info.had_whitespace,
                .line = self.line,
                .column = self.column,
                .offset = self.index,
                .doc_comments = null,
            };
        }

        const start = self.index;
        const start_line = self.line;
        const start_column = self.column;
        const char = self.source[self.index];

        switch (char) {
            '+' => {
                self.advance();
                if (self.index < self.source.len and self.source[self.index] == '+') {
                    self.advance();
                    return self.makeToken(.plus_plus, start, start_line, start_column);
                }
                return self.makeToken(.plus, start, start_line, start_column);
            },
            '-' => {
                self.advance();
                if (self.index < self.source.len and self.source[self.index] == '>') {
                    self.advance();
                    return self.makeToken(.arrow, start, start_line, start_column);
                }
                return self.makeToken(.minus, start, start_line, start_column);
            },
            '*' => {
                self.advance();
                return self.makeToken(.star, start, start_line, start_column);
            },
            '/' => {
                self.advance();
                return self.makeToken(.slash, start, start_line, start_column);
            },
            '&' => {
                self.advance();
                if (self.index < self.source.len and self.source[self.index] == '&') {
                    self.advance();
                    return self.makeToken(.ampersand_ampersand, start, start_line, start_column);
                }
                return self.makeToken(.ampersand, start, start_line, start_column);
            },
            '|' => {
                self.advance();
                if (self.index < self.source.len and self.source[self.index] == '|') {
                    self.advance();
                    return self.makeToken(.pipe_pipe, start, start_line, start_column);
                }
                // Record error location for the unexpected single pipe character
                if (self.error_ctx) |ctx| {
                    ctx.setErrorLocation(start_line, start_column, start, 1);
                }
                return error.UnexpectedCharacter;
            },
            '!' => {
                self.advance();
                if (self.index < self.source.len and self.source[self.index] == '=') {
                    self.advance();
                    return self.makeToken(.bang_equals, start, start_line, start_column);
                }
                return self.makeToken(.bang, start, start_line, start_column);
            },
            ',' => {
                self.advance();
                return self.makeToken(.comma, start, start_line, start_column);
            },
            ':' => {
                self.advance();
                if (self.index < self.source.len and self.source[self.index] == ':') {
                    self.advance();
                    return self.makeToken(.colon_colon, start, start_line, start_column);
                }
                return self.makeToken(.colon, start, start_line, start_column);
            },
            ';' => {
                self.advance();
                return self.makeToken(.semicolon, start, start_line, start_column);
            },
            '=' => {
                self.advance();
                if (self.index < self.source.len and self.source[self.index] == '=') {
                    self.advance();
                    return self.makeToken(.equals_equals, start, start_line, start_column);
                }
                return self.makeToken(.equals, start, start_line, start_column);
            },
            '(' => {
                self.advance();
                return self.makeToken(.l_paren, start, start_line, start_column);
            },
            ')' => {
                self.advance();
                return self.makeToken(.r_paren, start, start_line, start_column);
            },
            '[' => {
                self.advance();
                return self.makeToken(.l_bracket, start, start_line, start_column);
            },
            ']' => {
                self.advance();
                return self.makeToken(.r_bracket, start, start_line, start_column);
            },
            '{' => {
                self.advance();
                return self.makeToken(.l_brace, start, start_line, start_column);
            },
            '}' => {
                self.advance();
                return self.makeToken(.r_brace, start, start_line, start_column);
            },
            '.' => {
                // Check for ... (spread operator / exclusive range)
                if (self.index + 2 < self.source.len and
                    self.source[self.index + 1] == '.' and
                    self.source[self.index + 2] == '.')
                {
                    self.advance();
                    self.advance();
                    self.advance();
                    return self.makeToken(.dot_dot_dot, start, start_line, start_column);
                }
                // Check for .. (inclusive range)
                if (self.index + 1 < self.source.len and
                    self.source[self.index + 1] == '.')
                {
                    self.advance();
                    self.advance();
                    return self.makeToken(.dot_dot, start, start_line, start_column);
                }
                // Single dot for field access
                self.advance();
                return self.makeToken(.dot, start, start_line, start_column);
            },
            'a'...'z', 'A'...'Z', '_' => {
                return self.consumeIdentifier();
            },
            '0'...'9' => {
                return self.consumeNumber();
            },
            '\'' => {
                // Check for triple-quote multiline text block '''
                if (self.index + 2 < self.source.len and
                    self.source[self.index + 1] == '\'' and
                    self.source[self.index + 2] == '\'')
                {
                    return self.consumeTextBlock(start, start_line, start_column);
                }
                return self.consumeString('\'');
            },
            '"' => {
                return self.consumeString('"');
            },
            '#' => {
                return self.consumeSymbol();
            },
            '<' => {
                self.advance();
                if (self.index < self.source.len and self.source[self.index] == '=') {
                    self.advance();
                    return self.makeToken(.less_equals, start, start_line, start_column);
                }
                return self.makeToken(.less, start, start_line, start_column);
            },
            '>' => {
                self.advance();
                if (self.index < self.source.len and self.source[self.index] == '=') {
                    self.advance();
                    return self.makeToken(.greater_equals, start, start_line, start_column);
                }
                return self.makeToken(.greater, start, start_line, start_column);
            },
            '\\' => {
                self.advance();
                return self.makeToken(.backslash, start, start_line, start_column);
            },
            else => {
                // Record error location for the unexpected character
                if (self.error_ctx) |ctx| {
                    ctx.setErrorLocation(start_line, start_column, start, 1);
                }
                return error.UnexpectedCharacter;
            },
        }
    }

    fn consumeIdentifier(self: *Tokenizer) ast.Token {
        const start = self.index;
        const start_line = self.line;
        const start_column = self.column;
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => self.advance(),
                else => break,
            }
        }
        const lexeme = self.source[start..self.index];
        const kind = keywordKind(lexeme) orelse .identifier;
        return self.makeToken(kind, start, start_line, start_column);
    }

    fn keywordKind(lexeme: []const u8) ?ast.TokenKind {
        const keywords = std.StaticStringMap(ast.TokenKind).initComptime(.{
            .{ "if", .keyword_if },
            .{ "then", .keyword_then },
            .{ "else", .keyword_else },
            .{ "when", .keyword_when },
            .{ "is", .keyword_is },
            .{ "for", .keyword_for },
            .{ "in", .keyword_in },
            .{ "where", .keyword_where },
            .{ "do", .keyword_do },
            .{ "otherwise", .keyword_otherwise },
            .{ "unless", .keyword_unless },
            .{ "matches", .keyword_matches },
            .{ "import", .keyword_import },
            .{ "assert", .keyword_assert },
            .{ "self", .keyword_self },
            .{ "super", .keyword_super },
            .{ "and", .keyword_and },
        });
        return keywords.get(lexeme);
    }

    fn consumeSymbol(self: *Tokenizer) ast.Token {
        const start = self.index;
        const start_line = self.line;
        const start_column = self.column;
        self.advance(); // skip '#'

        // Symbol must be followed by an identifier character
        if (self.index >= self.source.len) {
            return self.makeToken(.symbol, start, start_line, start_column);
        }

        const c = self.source[self.index];
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_')) {
            return self.makeToken(.symbol, start, start_line, start_column);
        }

        // Consume the identifier part
        while (self.index < self.source.len) {
            const ch = self.source[self.index];
            switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => self.advance(),
                else => break,
            }
        }
        return self.makeToken(.symbol, start, start_line, start_column);
    }

    fn consumeNumber(self: *Tokenizer) ast.Token {
        const start = self.index;
        const start_line = self.line;
        const start_column = self.column;

        // Consume integer part
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                '0'...'9' => self.advance(),
                else => break,
            }
        }

        // Check for decimal point followed by digits
        if (self.index < self.source.len and self.source[self.index] == '.') {
            // Look ahead to ensure there's a digit after the dot
            // This prevents treating "foo.bar" as "foo" followed by ".bar"
            if (self.index + 1 < self.source.len) {
                const next_char = self.source[self.index + 1];
                if (next_char >= '0' and next_char <= '9') {
                    self.advance(); // consume '.'
                    // Consume fractional part
                    while (self.index < self.source.len) {
                        const c = self.source[self.index];
                        switch (c) {
                            '0'...'9' => self.advance(),
                            else => break,
                        }
                    }
                }
            }
        }

        return self.makeToken(.number, start, start_line, start_column);
    }

    fn consumeString(self: *Tokenizer, quote_char: u8) TokenizerError!ast.Token {
        const start_line = self.line;
        const start_column = self.column;
        const process_escapes = quote_char == '"';
        self.advance(); // skip opening quote
        const start_content = self.index;

        // First pass: check if any escapes exist (only for double-quoted strings)
        var has_escapes = false;
        if (process_escapes) {
            var scan = self.index;
            while (scan < self.source.len and self.source[scan] != quote_char) {
                if (self.source[scan] == '\\') {
                    has_escapes = true;
                    break;
                }
                scan += 1;
            }
        }

        if (!has_escapes) {
            // No escapes: return a slice of the source (original behavior)
            while (self.index < self.source.len) {
                if (self.source[self.index] == quote_char) {
                    const token = ast.Token{
                        .kind = .string,
                        .lexeme = self.source[start_content..self.index],
                        .preceded_by_newline = self.last_whitespace_had_newline,
                        .preceded_by_whitespace = self.last_had_whitespace,
                        .line = start_line,
                        .column = start_column,
                        .offset = start_content - 1, // include the opening quote
                        .doc_comments = null,
                    };
                    self.advance(); // skip closing quote
                    return token;
                }
                self.advance();
            }
        } else {
            // Has escapes: build a new string with processed escape sequences
            var result = std.ArrayList(u8){};
            while (self.index < self.source.len) {
                if (self.source[self.index] == quote_char) {
                    const content = result.toOwnedSlice(self.arena) catch return error.OutOfMemory;
                    const token = ast.Token{
                        .kind = .string,
                        .lexeme = content,
                        .preceded_by_newline = self.last_whitespace_had_newline,
                        .preceded_by_whitespace = self.last_had_whitespace,
                        .line = start_line,
                        .column = start_column,
                        .offset = start_content - 1, // include the opening quote
                        .doc_comments = null,
                    };
                    self.advance(); // skip closing quote
                    return token;
                }
                if (self.source[self.index] == '\\' and self.index + 1 < self.source.len) {
                    self.advance(); // skip backslash
                    const escaped = switch (self.source[self.index]) {
                        'n' => @as(u8, '\n'),
                        't' => @as(u8, '\t'),
                        'r' => @as(u8, '\r'),
                        '\\' => @as(u8, '\\'),
                        '"' => @as(u8, '"'),
                        else => {
                            // Unknown escape: keep backslash and character as-is
                            result.append(self.arena, '\\') catch return error.OutOfMemory;
                            result.append(self.arena, self.source[self.index]) catch return error.OutOfMemory;
                            self.advance();
                            continue;
                        },
                    };
                    result.append(self.arena, escaped) catch return error.OutOfMemory;
                    self.advance();
                    continue;
                }
                result.append(self.arena, self.source[self.index]) catch return error.OutOfMemory;
                self.advance();
            }
        }

        // Record error location for unterminated string
        if (self.error_ctx) |ctx| {
            ctx.setErrorLocation(start_line, start_column, start_content - 1, 1);
        }
        return error.UnterminatedString;
    }

    fn consumeTextBlock(self: *Tokenizer, start: usize, start_line: usize, start_column: usize) TokenizerError!ast.Token {
        _ = start;
        // Skip the opening '''
        self.advance();
        self.advance();
        self.advance();

        // Skip the rest of the opening line (including newline)
        while (self.index < self.source.len and self.source[self.index] != '\n') {
            self.advance();
        }
        if (self.index < self.source.len) {
            self.advance(); // skip newline
        }

        // Collect content lines until we find a line that is just ''' (with optional leading whitespace)
        const content_start = self.index;
        var closing_start: usize = self.index;
        var found_closing = false;

        while (self.index < self.source.len) {
            const line_start = self.index;

            // Skip whitespace at start of line
            while (self.index < self.source.len and (self.source[self.index] == ' ' or self.source[self.index] == '\t')) {
                self.advance();
            }

            // Check if this line starts with '''
            if (self.index + 2 < self.source.len and
                self.source[self.index] == '\'' and
                self.source[self.index + 1] == '\'' and
                self.source[self.index + 2] == '\'')
            {
                closing_start = line_start;
                found_closing = true;
                // Skip the closing '''
                self.advance();
                self.advance();
                self.advance();
                break;
            }

            // Not the closing line — skip to end of line
            while (self.index < self.source.len and self.source[self.index] != '\n') {
                self.advance();
            }
            if (self.index < self.source.len) {
                self.advance(); // skip newline
            }
        }

        if (!found_closing) {
            if (self.error_ctx) |ctx| {
                ctx.setErrorLocation(start_line, start_column, content_start, 3);
            }
            return error.UnterminatedString;
        }

        const raw_content = self.source[content_start..closing_start];

        // Dedent: find minimum indentation across all non-empty lines
        var min_indent: usize = std.math.maxInt(usize);
        var lines_iter = std.mem.splitScalar(u8, raw_content, '\n');
        while (lines_iter.next()) |line| {
            if (line.len == 0) continue; // skip empty lines for indent calculation
            var indent: usize = 0;
            for (line) |c| {
                if (c == ' ') {
                    indent += 1;
                } else if (c == '\t') {
                    indent += 1;
                } else {
                    break;
                }
            }
            if (indent < min_indent) {
                min_indent = indent;
            }
        }
        if (min_indent == std.math.maxInt(usize)) {
            min_indent = 0;
        }

        // Build dedented string
        var result = std.ArrayList(u8){};
        var lines_iter2 = std.mem.splitScalar(u8, raw_content, '\n');
        var first = true;
        while (lines_iter2.next()) |line| {
            // Skip trailing empty line (the one before ''')
            if (lines_iter2.peek() == null and line.len == 0) break;

            if (!first) {
                result.append(self.arena, '\n') catch return error.OutOfMemory;
            }
            first = false;

            if (line.len == 0) {
                // Preserve empty lines
                continue;
            }

            const stripped = if (min_indent <= line.len) line[min_indent..] else line;
            result.appendSlice(self.arena, stripped) catch return error.OutOfMemory;
        }

        const content = result.toOwnedSlice(self.arena) catch return error.OutOfMemory;

        return ast.Token{
            .kind = .string,
            .lexeme = content,
            .preceded_by_newline = self.last_whitespace_had_newline,
            .preceded_by_whitespace = self.last_had_whitespace,
            .line = start_line,
            .column = start_column,
            .offset = content_start,
            .doc_comments = null,
        };
    }

    fn advance(self: *Tokenizer) void {
        if (self.index < self.source.len) {
            if (self.source[self.index] == '\n') {
                self.line += 1;
                self.column = 1;
                self.line_start = self.index + 1;
            } else {
                self.column += 1;
            }
            self.index += 1;
        }
    }

    const WhitespaceInfo = struct {
        had_whitespace: bool,
        saw_newline: bool,
    };

    fn skipWhitespace(self: *Tokenizer) WhitespaceInfo {
        var saw_newline = false;
        var had_whitespace = false;

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                ' ', '\t' => {
                    had_whitespace = true;
                    self.advance();
                },
                '\r' => {
                    had_whitespace = true;
                    saw_newline = true;
                    self.advance();
                    if (self.index < self.source.len and self.source[self.index] == '\n') {
                        self.advance();
                    }
                },
                '\n' => {
                    had_whitespace = true;
                    saw_newline = true;
                    self.advance();
                },
                '/' => {
                    // Check for comments
                    if (self.index + 1 < self.source.len and self.source[self.index + 1] == '/') {
                        // Check if it's a doc comment (///)
                        if (self.index + 2 < self.source.len and self.source[self.index + 2] == '/') {
                            // Documentation comment
                            had_whitespace = true;
                            self.index += 3; // skip '///'

                            // Skip exactly one space if present (common prefix)
                            if (self.index < self.source.len and self.source[self.index] == ' ') {
                                self.index += 1;
                            }

                            const content_start = self.index;

                            // Find end of line
                            while (self.index < self.source.len and self.source[self.index] != '\n' and self.source[self.index] != '\r') {
                                self.index += 1;
                            }

                            const comment_content = self.source[content_start..self.index];
                            self.pending_doc_comments.append(self.arena, comment_content) catch {};

                            // The newline will be handled in the next iteration
                            continue;
                        } else {
                            // Regular comment - skip to end of line
                            had_whitespace = true;
                            self.index += 2; // skip '//'
                            while (self.index < self.source.len and self.source[self.index] != '\n' and self.source[self.index] != '\r') {
                                self.index += 1;
                            }
                            // The newline will be handled in the next iteration
                            continue;
                        }
                    }
                    return .{ .had_whitespace = had_whitespace, .saw_newline = saw_newline };
                },
                else => return .{ .had_whitespace = had_whitespace, .saw_newline = saw_newline },
            }
        }
        return .{ .had_whitespace = had_whitespace, .saw_newline = saw_newline };
    }

    fn makeToken(self: *Tokenizer, kind: ast.TokenKind, start: usize, start_line: usize, start_column: usize) ast.Token {
        // Automatically consume pending doc comments and attach to this token
        const docs = self.consumeDocComments();

        return .{
            .kind = kind,
            .lexeme = self.source[start..self.index],
            .preceded_by_newline = self.last_whitespace_had_newline,
            .preceded_by_whitespace = self.last_had_whitespace,
            .line = start_line,
            .column = start_column,
            .offset = start,
            .doc_comments = docs,
        };
    }

    pub fn consumeDocComments(self: *Tokenizer) ?[]const u8 {
        if (self.pending_doc_comments.items.len == 0) {
            return null;
        }

        // Safety check: if we have way too many comments, something is wrong
        if (self.pending_doc_comments.items.len > 1000) {
            self.pending_doc_comments.clearRetainingCapacity();
            return null;
        }

        // Join all doc comments with newlines
        var total_len: usize = 0;
        for (self.pending_doc_comments.items) |comment| {
            const separator_len: usize = if (total_len > 0) 1 else 0;
            const new_len = total_len +% comment.len +% separator_len; // Use wrapping addition
            // Check for overflow
            if (new_len < total_len or new_len < comment.len) {
                self.pending_doc_comments.clearRetainingCapacity();
                return null;
            }
            total_len = new_len;
        }

        if (total_len == 0) {
            self.pending_doc_comments.clearRetainingCapacity();
            return null;
        }

        var result = self.arena.alloc(u8, total_len) catch return null;
        var offset: usize = 0;
        for (self.pending_doc_comments.items, 0..) |comment, i| {
            if (i > 0) {
                result[offset] = '\n';
                offset += 1;
            }
            @memcpy(result[offset .. offset + comment.len], comment);
            offset += comment.len;
        }

        self.pending_doc_comments.clearRetainingCapacity();
        return result;
    }

    pub fn clearDocComments(self: *Tokenizer) void {
        self.pending_doc_comments.clearRetainingCapacity();
    }

};
