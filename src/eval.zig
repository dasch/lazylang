const std = @import("std");
const error_reporter = @import("error_reporter.zig");
const error_context = @import("error_context.zig");

/// Thread-local storage for user crash messages
threadlocal var user_crash_message: ?[]const u8 = null;

pub fn setUserCrashMessage(message: []const u8) void {
    user_crash_message = message;
}

pub fn getUserCrashMessage() ?[]const u8 {
    return user_crash_message;
}

pub fn clearUserCrashMessage() void {
    if (user_crash_message) |msg| {
        std.heap.page_allocator.free(msg);
    }
    user_crash_message = null;
}

pub const TokenKind = enum {
    eof,
    identifier,
    number,
    string,
    symbol,
    comma,
    colon,
    semicolon,
    equals,
    arrow,
    backslash,
    plus,
    minus,
    star,
    ampersand,
    ampersand_ampersand,
    pipe_pipe,
    bang,
    equals_equals,
    bang_equals,
    less,
    greater,
    less_equals,
    greater_equals,
    dot,
    dot_dot_dot,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    preceded_by_newline: bool,
    line: usize, // 1-indexed line number
    column: usize, // 1-indexed column number
    offset: usize, // byte offset in source
};

const TokenizerError = error{
    UnexpectedCharacter,
    UnterminatedString,
};

const ParseError = TokenizerError || std.mem.Allocator.Error || std.fmt.ParseIntError || error{
    ExpectedExpression,
    UnexpectedToken,
};

const BinaryOp = enum {
    add,
    subtract,
    multiply,
    logical_and,
    logical_or,
    pipeline,
    equal,
    not_equal,
    less_than,
    greater_than,
    less_or_equal,
    greater_or_equal,
    merge,
};

const UnaryOp = enum {
    logical_not,
};

pub const Expression = union(enum) {
    integer: i64,
    boolean: bool,
    null_literal,
    symbol: []const u8,
    identifier: []const u8,
    string_literal: []const u8,
    string_interpolation: StringInterpolation,
    lambda: Lambda,
    let: Let,
    unary: Unary,
    binary: Binary,
    application: Application,
    if_expr: If,
    when_matches: WhenMatches,
    array: ArrayLiteral,
    tuple: TupleLiteral,
    object: ObjectLiteral,
    object_extend: ObjectExtend,
    import_expr: ImportExpr,
    array_comprehension: ArrayComprehension,
    object_comprehension: ObjectComprehension,
    field_access: FieldAccess,
    field_accessor: FieldAccessor,
    field_projection: FieldProjection,
};

const Lambda = struct {
    param: *Pattern,
    body: *Expression,
};

const Let = struct {
    pattern: *Pattern,
    value: *Expression,
    body: *Expression,
    doc: ?[]const u8, // Combined documentation comments
};

const Unary = struct {
    op: UnaryOp,
    operand: *Expression,
};

const Binary = struct {
    op: BinaryOp,
    left: *Expression,
    right: *Expression,
};

const Application = struct {
    function: *Expression,
    argument: *Expression,
};

const If = struct {
    condition: *Expression,
    then_expr: *Expression,
    else_expr: ?*Expression,
};

const WhenMatches = struct {
    value: *Expression,
    branches: []MatchBranch,
    otherwise: ?*Expression,
};

const MatchBranch = struct {
    pattern: *Pattern,
    expression: *Expression,
};

const ArrayElement = union(enum) {
    normal: *Expression,
    spread: *Expression,
};

const ArrayLiteral = struct {
    elements: []ArrayElement,
};

const TupleLiteral = struct {
    elements: []*Expression,
};

const ObjectField = struct {
    key: []const u8,
    value: *Expression,
    is_patch: bool, // true if no colon (merge), false if colon (overwrite)
    doc: ?[]const u8, // Combined documentation comments
};

const ObjectLiteral = struct {
    fields: []ObjectField,
};

const ObjectExtend = struct {
    base: *Expression,
    fields: []ObjectField,
};

const ImportExpr = struct {
    path: []const u8,
};

const StringInterpolation = struct {
    parts: []StringPart,
};

const StringPart = union(enum) {
    literal: []const u8,
    interpolation: *Expression,
};

const ForClause = struct {
    pattern: *Pattern,
    iterable: *Expression,
};

const ArrayComprehension = struct {
    body: *Expression,
    clauses: []ForClause,
    filter: ?*Expression,
};

const ObjectComprehension = struct {
    key: *Expression,
    value: *Expression,
    clauses: []ForClause,
    filter: ?*Expression,
};

const FieldAccess = struct {
    object: *Expression,
    field: []const u8,
};

const FieldAccessor = struct {
    fields: [][]const u8, // Chain of field names, e.g. ["user", "address"]
};

const FieldProjection = struct {
    object: *Expression,
    fields: [][]const u8, // List of fields to extract
};

pub const Pattern = union(enum) {
    identifier: []const u8,
    integer: i64,
    boolean: bool,
    null_literal,
    symbol: []const u8,
    string_literal: []const u8,
    tuple: TuplePattern,
    array: ArrayPattern,
    object: ObjectPattern,
};

const TuplePattern = struct {
    elements: []*Pattern,
};

const ArrayPattern = struct {
    elements: []*Pattern,
    rest: ?[]const u8, // Optional rest identifier (e.g., "tail" in [head, ...tail])
};

const ObjectPattern = struct {
    fields: []ObjectPatternField,
};

const ObjectPatternField = struct {
    key: []const u8,
    pattern: *Pattern, // Either identifier for extraction or literal for matching
};

pub const Tokenizer = struct {
    source: []const u8,
    index: usize,
    last_whitespace_had_newline: bool,
    line: usize, // current line number (1-indexed)
    column: usize, // current column number (1-indexed)
    line_start: usize, // byte offset of the current line start
    pending_doc_comments: std.ArrayListUnmanaged([]const u8),
    arena: std.mem.Allocator,

    pub fn init(source: []const u8, arena: std.mem.Allocator) Tokenizer {
        return .{
            .source = source,
            .index = 0,
            .last_whitespace_had_newline = false,
            .line = 1,
            .column = 1,
            .line_start = 0,
            .pending_doc_comments = .{},
            .arena = arena,
        };
    }

    pub fn next(self: *Tokenizer) TokenizerError!Token {
        const saw_newline = self.skipWhitespace();
        self.last_whitespace_had_newline = saw_newline;

        if (self.index >= self.source.len) {
            return .{
                .kind = .eof,
                .lexeme = self.source[self.source.len..self.source.len],
                .preceded_by_newline = saw_newline,
                .line = self.line,
                .column = self.column,
                .offset = self.index,
            };
        }

        const start = self.index;
        const start_line = self.line;
        const start_column = self.column;
        const char = self.source[self.index];

        switch (char) {
            '+' => {
                self.advance();
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
                // Check for ... (spread operator)
                if (self.index + 2 < self.source.len and
                    self.source[self.index + 1] == '.' and
                    self.source[self.index + 2] == '.')
                {
                    self.advance();
                    self.advance();
                    self.advance();
                    return self.makeToken(.dot_dot_dot, start, start_line, start_column);
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
            else => return error.UnexpectedCharacter,
        }
    }

    fn consumeIdentifier(self: *Tokenizer) Token {
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
        return self.makeToken(.identifier, start, start_line, start_column);
    }

    fn consumeSymbol(self: *Tokenizer) Token {
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

    fn consumeNumber(self: *Tokenizer) Token {
        const start = self.index;
        const start_line = self.line;
        const start_column = self.column;
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                '0'...'9' => self.advance(),
                else => break,
            }
        }
        return self.makeToken(.number, start, start_line, start_column);
    }

    fn consumeString(self: *Tokenizer, quote_char: u8) TokenizerError!Token {
        const start_line = self.line;
        const start_column = self.column;
        self.advance(); // skip opening quote
        const start_content = self.index;
        while (self.index < self.source.len) {
            if (self.source[self.index] == quote_char) {
                const token = Token{
                    .kind = .string,
                    .lexeme = self.source[start_content..self.index],
                    .preceded_by_newline = self.last_whitespace_had_newline,
                    .line = start_line,
                    .column = start_column,
                    .offset = start_content - 1, // include the opening quote
                };
                self.advance(); // skip closing quote
                return token;
            }
            self.advance();
        }
        return error.UnterminatedString;
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

    fn skipWhitespace(self: *Tokenizer) bool {
        var saw_newline = false;
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                ' ', '\t' => {
                    self.advance();
                },
                '\r' => {
                    saw_newline = true;
                    self.advance();
                    if (self.index < self.source.len and self.source[self.index] == '\n') {
                        self.advance();
                    }
                },
                '\n' => {
                    saw_newline = true;
                    self.advance();
                },
                '/' => {
                    // Check for comments
                    if (self.index + 1 < self.source.len and self.source[self.index + 1] == '/') {
                        // Check if it's a doc comment (///)
                        if (self.index + 2 < self.source.len and self.source[self.index + 2] == '/') {
                            // Documentation comment
                            self.index += 3; // skip '///'

                            // Skip leading whitespace in the comment
                            while (self.index < self.source.len and (self.source[self.index] == ' ' or self.source[self.index] == '\t')) {
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
                            self.index += 2; // skip '//'
                            while (self.index < self.source.len and self.source[self.index] != '\n' and self.source[self.index] != '\r') {
                                self.index += 1;
                            }
                            // The newline will be handled in the next iteration
                            continue;
                        }
                    }
                    return saw_newline;
                },
                else => return saw_newline,
            }
        }
        return saw_newline;
    }

    fn makeToken(self: *Tokenizer, kind: TokenKind, start: usize, start_line: usize, start_column: usize) Token {
        return .{
            .kind = kind,
            .lexeme = self.source[start..self.index],
            .preceded_by_newline = self.last_whitespace_had_newline,
            .line = start_line,
            .column = start_column,
            .offset = start,
        };
    }

    fn consumeDocComments(self: *Tokenizer) ?[]const u8 {
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

    fn clearDocComments(self: *Tokenizer) void {
        self.pending_doc_comments.clearRetainingCapacity();
    }
};

pub const Parser = struct {
    arena: std.mem.Allocator,
    tokenizer: Tokenizer,
    current: Token,
    lookahead: Token,
    source: []const u8,
    error_ctx: ?*error_context.ErrorContext,

    pub fn init(arena: std.mem.Allocator, source: []const u8) ParseError!Parser {
        var tokenizer = Tokenizer.init(source, arena);
        const first = try tokenizer.next();
        const second = try tokenizer.next();
        return .{
            .arena = arena,
            .tokenizer = tokenizer,
            .current = first,
            .lookahead = second,
            .source = source,
            .error_ctx = null,
        };
    }

    fn setErrorContext(self: *Parser, ctx: *error_context.ErrorContext) void {
        self.error_ctx = ctx;
    }

    fn recordError(self: *Parser) void {
        if (self.error_ctx) |ctx| {
            ctx.setErrorLocation(
                self.current.line,
                self.current.column,
                self.current.offset,
                self.current.lexeme.len,
            );
            ctx.setErrorToken(self.current.lexeme);
        }
    }

    pub fn parse(self: *Parser) ParseError!*Expression {
        if (self.current.kind == .eof) {
            self.recordError();
            return error.ExpectedExpression;
        }
        const expr = try self.parseLambda();
        if (self.current.kind != .eof) {
            self.recordError();
            return error.UnexpectedToken;
        }
        return expr;
    }

    fn parseLambda(self: *Parser) ParseError!*Expression {
        // Check for let binding with pattern: pattern = expression
        const is_let_binding = switch (self.current.kind) {
            .identifier => self.lookahead.kind == .equals,
            .l_paren, .l_bracket, .l_brace => blk: {
                // Look ahead to see if this is a pattern binding
                // We need to scan ahead to find if there's an equals sign
                break :blk self.isPatternBinding();
            },
            else => false,
        };

        if (is_let_binding) {
            const doc = self.tokenizer.consumeDocComments();
            const pattern = try self.parsePattern();
            try self.expect(.equals);
            const value = try self.parseLambda();

            // Check for semicolon or newline separator
            if (self.current.kind == .semicolon) {
                try self.advance();
            } else if (!self.current.preceded_by_newline and self.current.kind != .eof) {
                return error.UnexpectedToken;
            }

            // If we're at EOF or closing delimiter, return just the value
            if (self.current.kind == .eof or self.current.kind == .r_paren) {
                return value;
            }

            const body = try self.parseLambda();
            const node = try self.allocateExpression();
            node.* = .{ .let = .{ .pattern = pattern, .value = value, .body = body, .doc = doc } };
            return node;
        }

        // Check for lambda: pattern -> expression
        const is_lambda = switch (self.current.kind) {
            .identifier => self.lookahead.kind == .arrow,
            .l_paren, .l_bracket, .l_brace => blk: {
                // Look ahead to see if this is a lambda with pattern parameter
                break :blk self.isLambdaPattern();
            },
            else => false,
        };

        if (is_lambda) {
            const param = try self.parsePattern();
            try self.expect(.arrow);
            const body = try self.parseLambda();
            const node = try self.allocateExpression();
            node.* = .{ .lambda = .{ .param = param, .body = body } };
            return node;
        }

        var expr = try self.parseBinary(0);

        // Check for 'where' clause
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "where")) {
            try self.advance();

            // Parse bindings: collect them into a list
            var bindings = std.ArrayListUnmanaged(struct { pattern: *Pattern, value: *Expression, doc: ?[]const u8 }){};

            while (true) {
                // Check if we're done
                if (self.current.kind == .eof) break;
                if (self.current.kind == .r_paren) break; // Could be inside parentheses
                if (self.current.kind == .r_bracket) break;
                if (self.current.kind == .r_brace) break;

                // Check if next token starts a binding
                const is_binding = switch (self.current.kind) {
                    .identifier => self.lookahead.kind == .equals,
                    .l_paren, .l_bracket, .l_brace => self.isPatternBinding(),
                    else => false,
                };

                if (!is_binding) break;

                const doc = self.tokenizer.consumeDocComments();
                const pattern = try self.parsePattern();
                try self.expect(.equals);
                const value = try self.parseBinary(0);

                try bindings.append(self.arena, .{ .pattern = pattern, .value = value, .doc = doc });

                // Check for separator
                if (self.current.kind == .semicolon) {
                    try self.advance();
                } else if (!self.current.preceded_by_newline and self.current.kind != .eof and
                          self.current.kind != .r_paren and self.current.kind != .r_bracket and
                          self.current.kind != .r_brace) {
                    break;
                }
            }

            // Wrap expr in nested let expressions (in reverse order to maintain dependency order)
            const binding_slice = try bindings.toOwnedSlice(self.arena);
            var i = binding_slice.len;
            while (i > 0) {
                i -= 1;
                const binding = binding_slice[i];
                const let_node = try self.allocateExpression();
                let_node.* = .{ .let = .{ .pattern = binding.pattern, .value = binding.value, .body = expr, .doc = binding.doc } };
                expr = let_node;
            }
        }

        return expr;
    }

    fn isLambdaPattern(self: *Parser) bool {
        // Similar to isPatternBinding, but looks for '->' instead of '='
        const saved_tokenizer = self.tokenizer;
        const saved_current = self.current;
        const saved_lookahead = self.lookahead;
        defer {
            self.tokenizer = saved_tokenizer;
            self.current = saved_current;
            self.lookahead = saved_lookahead;
        }

        var depth: usize = 0;
        const open_kind = self.current.kind;
        const close_kind = switch (open_kind) {
            .l_paren => TokenKind.r_paren,
            .l_bracket => TokenKind.r_bracket,
            .l_brace => TokenKind.r_brace,
            else => return false,
        };

        // Advance past opening delimiter
        self.advance() catch return false;
        depth = 1;

        // Scan forward looking for matching close and then '->'
        while (depth > 0) {
            if (self.current.kind == .eof) return false;
            if (self.current.kind == open_kind) depth += 1;
            if (self.current.kind == close_kind) {
                depth -= 1;
                if (depth == 0) break;
            }
            self.advance() catch return false;
        }

        // Now check if next token is '->'
        self.advance() catch return false;
        return self.current.kind == .arrow;
    }

    fn isPatternBinding(self: *Parser) bool {
        // Simple heuristic: if we see an opening delimiter, count depth and look for '='
        // Save parser state before lookahead
        const saved_index = self.tokenizer.index;
        const saved_last_newline = self.tokenizer.last_whitespace_had_newline;
        const saved_current = self.current;
        const saved_lookahead = self.lookahead;
        // Save doc comments length - we'll truncate back to this after lookahead
        const saved_doc_comments_len = self.tokenizer.pending_doc_comments.items.len;

        defer {
            // Restore parser state
            self.tokenizer.index = saved_index;
            self.tokenizer.last_whitespace_had_newline = saved_last_newline;
            self.current = saved_current;
            self.lookahead = saved_lookahead;
            // Discard any doc comments accumulated during lookahead
            self.tokenizer.pending_doc_comments.items.len = saved_doc_comments_len;
        }

        var depth: usize = 0;
        const open_kind = self.current.kind;
        const close_kind = switch (open_kind) {
            .l_paren => TokenKind.r_paren,
            .l_bracket => TokenKind.r_bracket,
            .l_brace => TokenKind.r_brace,
            else => return false,
        };

        // Advance past opening delimiter
        self.advance() catch return false;
        depth = 1;

        // Scan forward looking for matching close and then '='
        while (depth > 0) {
            if (self.current.kind == .eof) return false;
            if (self.current.kind == open_kind) depth += 1;
            if (self.current.kind == close_kind) {
                depth -= 1;
                if (depth == 0) break;
            }
            self.advance() catch return false;
        }

        // Now check if next token is '='
        self.advance() catch return false;
        return self.current.kind == .equals;
    }

    fn parseBinary(self: *Parser, min_precedence: u32) ParseError!*Expression {
        var left = try self.parseUnary();

        while (true) {
            const precedence = getPrecedence(self.current.kind) orelse break;
            if (precedence < min_precedence) break;

            const op_token = self.current;
            try self.advance();

            // For pipeline operator, allow lambdas on the right side
            // Check if the right side is a lambda pattern
            const right = if (op_token.kind == .backslash and self.isLambdaPattern())
                blk: {
                    const param = try self.parsePattern();
                    try self.expect(.arrow);
                    const body = try self.parseLambda();
                    const lambda_node = try self.allocateExpression();
                    lambda_node.* = .{ .lambda = .{ .param = param, .body = body } };
                    break :blk lambda_node;
                }
            else
                try self.parseBinary(precedence + 1);

            const node = try self.allocateExpression();
            node.* = .{ .binary = .{
                .op = switch (op_token.kind) {
                    .plus => .add,
                    .minus => .subtract,
                    .star => .multiply,
                    .ampersand => .merge,
                    .ampersand_ampersand => .logical_and,
                    .pipe_pipe => .logical_or,
                    .backslash => .pipeline,
                    .equals_equals => .equal,
                    .bang_equals => .not_equal,
                    .less => .less_than,
                    .greater => .greater_than,
                    .less_equals => .less_or_equal,
                    .greater_equals => .greater_or_equal,
                    else => unreachable,
                },
                .left = left,
                .right = right,
            } };
            left = node;
        }

        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*Expression {
        if (self.current.kind == .bang) {
            try self.advance();
            const operand = try self.parseUnary();
            const node = try self.allocateExpression();
            node.* = .{ .unary = .{
                .op = .logical_not,
                .operand = operand,
            } };
            return node;
        }
        return self.parseApplication();
    }

    fn parseApplication(self: *Parser) ParseError!*Expression {
        var expr = try self.parsePrimary();

        while (true) {
            if (self.current.preceded_by_newline) break;
            switch (self.current.kind) {
                .identifier => {
                    // Handle 'do' keyword specially - it introduces a block argument
                    if (std.mem.eql(u8, self.current.lexeme, "do")) {
                        try self.advance();
                        // Parse the following expression(s) as a block
                        const argument = try self.parseLambda();
                        const node = try self.allocateExpression();
                        node.* = .{ .application = .{ .function = expr, .argument = argument } };
                        expr = node;
                        // After a 'do' block, stop looking for more arguments
                        break;
                    }

                    // Don't consume keywords as function arguments
                    if (std.mem.eql(u8, self.current.lexeme, "then") or
                        std.mem.eql(u8, self.current.lexeme, "else") or
                        std.mem.eql(u8, self.current.lexeme, "matches") or
                        std.mem.eql(u8, self.current.lexeme, "otherwise") or
                        std.mem.eql(u8, self.current.lexeme, "where") or
                        std.mem.eql(u8, self.current.lexeme, "for") or
                        std.mem.eql(u8, self.current.lexeme, "in") or
                        std.mem.eql(u8, self.current.lexeme, "when"))
                    {
                        break;
                    }
                    const argument = try self.parsePrimary();
                    const node = try self.allocateExpression();
                    node.* = .{ .application = .{ .function = expr, .argument = argument } };
                    expr = node;
                },
                .dot => {
                    try self.advance();

                    // Check for field projection: .{ field1, field2 }
                    if (self.current.kind == .l_brace) {
                        try self.advance();
                        var field_list = std.ArrayList([]const u8){};
                        defer field_list.deinit(self.arena);

                        while (self.current.kind != .r_brace) {
                            if (self.current.kind != .identifier) {
                                return error.UnexpectedToken;
                            }
                            try field_list.append(self.arena, self.current.lexeme);
                            try self.advance();

                            if (self.current.kind == .comma) {
                                try self.advance();
                            }
                        }

                        try self.expect(.r_brace);

                        const node = try self.allocateExpression();
                        node.* = .{ .field_projection = .{
                            .object = expr,
                            .fields = try field_list.toOwnedSlice(self.arena),
                        } };
                        expr = node;
                    } else if (self.current.kind == .identifier) {
                        // Regular field access: expr.field
                        const field_name = self.current.lexeme;
                        try self.advance();

                        const node = try self.allocateExpression();
                        node.* = .{ .field_access = .{
                            .object = expr,
                            .field = field_name,
                        } };
                        expr = node;
                    } else {
                        return error.UnexpectedToken;
                    }
                },
                .l_brace => {
                    // Object extension: expr { fields }
                    const object_expr = try self.parseObject();

                    // Extract the fields from the parsed object
                    const fields = switch (object_expr.*) {
                        .object => |obj| obj.fields,
                        else => return error.UnexpectedToken,
                    };

                    const node = try self.allocateExpression();
                    node.* = .{ .object_extend = .{ .base = expr, .fields = fields } };
                    expr = node;
                },
                .number, .string, .symbol, .l_paren, .l_bracket => {
                    const argument = try self.parsePrimary();
                    const node = try self.allocateExpression();
                    node.* = .{ .application = .{ .function = expr, .argument = argument } };
                    expr = node;
                },
                else => break,
            }
        }

        return expr;
    }

    fn parsePrimary(self: *Parser) ParseError!*Expression {
        switch (self.current.kind) {
            .number => {
                const lexeme = self.current.lexeme;
                const value = try std.fmt.parseInt(i64, lexeme, 10);
                try self.advance();
                const node = try self.allocateExpression();
                node.* = .{ .integer = value };
                return node;
            },
            .identifier => {
                if (std.mem.eql(u8, self.current.lexeme, "import")) {
                    try self.advance();
                    if (self.current.kind != .string) return error.ExpectedExpression;
                    const path = self.current.lexeme;
                    try self.advance();
                    const node = try self.allocateExpression();
                    node.* = .{ .import_expr = .{ .path = path } };
                    return node;
                }
                if (std.mem.eql(u8, self.current.lexeme, "true")) {
                    try self.advance();
                    const node = try self.allocateExpression();
                    node.* = .{ .boolean = true };
                    return node;
                }
                if (std.mem.eql(u8, self.current.lexeme, "false")) {
                    try self.advance();
                    const node = try self.allocateExpression();
                    node.* = .{ .boolean = false };
                    return node;
                }
                if (std.mem.eql(u8, self.current.lexeme, "null")) {
                    try self.advance();
                    const node = try self.allocateExpression();
                    node.* = .null_literal;
                    return node;
                }
                if (std.mem.eql(u8, self.current.lexeme, "if")) {
                    try self.advance();
                    const condition = try self.parseBinary(0);

                    if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "then")) {
                        return error.UnexpectedToken;
                    }
                    try self.advance();

                    const then_expr = try self.parseBinary(0);

                    var else_expr: ?*Expression = null;
                    if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "else")) {
                        try self.advance();
                        else_expr = try self.parseBinary(0);
                    }

                    const node = try self.allocateExpression();
                    node.* = .{ .if_expr = .{
                        .condition = condition,
                        .then_expr = then_expr,
                        .else_expr = else_expr,
                    } };
                    return node;
                }
                if (std.mem.eql(u8, self.current.lexeme, "when")) {
                    try self.advance();
                    const value = try self.parseBinary(0);

                    if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "matches")) {
                        return error.UnexpectedToken;
                    }
                    try self.advance();

                    var branches = std.ArrayListUnmanaged(MatchBranch){};
                    var otherwise_expr: ?*Expression = null;

                    while (true) {
                        // Check for "otherwise"
                        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "otherwise")) {
                            try self.advance();
                            otherwise_expr = try self.parseBinary(0);
                            break;
                        }

                        // Check if we're done (EOF or semicolon)
                        if (self.current.kind == .eof or self.current.kind == .semicolon) {
                            break;
                        }

                        // Parse pattern
                        const pattern = try self.parsePattern();

                        // Expect "then"
                        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "then")) {
                            return error.UnexpectedToken;
                        }
                        try self.advance();

                        // Parse expression
                        const branch_expr = try self.parseBinary(0);

                        try branches.append(self.arena, .{
                            .pattern = pattern,
                            .expression = branch_expr,
                        });
                    }

                    const node = try self.allocateExpression();
                    node.* = .{ .when_matches = .{
                        .value = value,
                        .branches = try branches.toOwnedSlice(self.arena),
                        .otherwise = otherwise_expr,
                    } };
                    return node;
                }
                const name = self.current.lexeme;
                try self.advance();
                const node = try self.allocateExpression();
                node.* = .{ .identifier = name };
                return node;
            },
            .string => {
                const value = self.current.lexeme;
                try self.advance();

                // Check if the string contains interpolation
                const parts = try self.parseStringInterpolation(value);

                if (parts.len == 1 and parts[0] == .literal) {
                    // Simple string with no interpolation
                    const node = try self.allocateExpression();
                    node.* = .{ .string_literal = parts[0].literal };
                    return node;
                } else {
                    // String with interpolation
                    const node = try self.allocateExpression();
                    node.* = .{ .string_interpolation = .{ .parts = parts } };
                    return node;
                }
            },
            .symbol => {
                const value = self.current.lexeme;
                try self.advance();
                const node = try self.allocateExpression();
                node.* = .{ .symbol = value };
                return node;
            },
            .l_paren => return self.parseTupleOrParenthesized(),
            .l_bracket => return self.parseArray(),
            .l_brace => return self.parseObject(),
            .dot => {
                // Field accessor function: .field or .field1.field2
                try self.advance();

                var field_list = std.ArrayList([]const u8){};
                defer field_list.deinit(self.arena);

                // First field is required
                if (self.current.kind != .identifier) {
                    return error.UnexpectedToken;
                }
                try field_list.append(self.arena, self.current.lexeme);
                try self.advance();

                // Parse chained fields
                while (self.current.kind == .dot and !self.current.preceded_by_newline) {
                    try self.advance();
                    if (self.current.kind != .identifier) {
                        return error.UnexpectedToken;
                    }
                    try field_list.append(self.arena, self.current.lexeme);
                    try self.advance();
                }

                const node = try self.allocateExpression();
                node.* = .{ .field_accessor = .{
                    .fields = try field_list.toOwnedSlice(self.arena),
                } };
                return node;
            },
            else => {
                self.recordError();
                return error.ExpectedExpression;
            },
        }
    }

    fn parseArray(self: *Parser) ParseError!*Expression {
        try self.expect(.l_bracket);

        // Empty array
        if (self.current.kind == .r_bracket) {
            try self.advance();
            const node = try self.allocateExpression();
            node.* = .{ .array = .{ .elements = &[_]ArrayElement{} } };
            return node;
        }

        // Check if first element is a spread
        const is_first_spread = self.current.kind == .dot_dot_dot;
        if (is_first_spread) {
            try self.advance(); // consume ...
        }

        // Parse first element
        const first_element = try self.parseLambda();

        // Check if this is a comprehension by looking for 'for' keyword (only if not a spread)
        const is_comprehension = !is_first_spread and self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "for");

        if (is_comprehension) {
            return self.parseArrayComprehension(first_element);
        }

        // Regular array: continue parsing elements
        var elements = std.ArrayListUnmanaged(ArrayElement){};
        if (is_first_spread) {
            try elements.append(self.arena, .{ .spread = first_element });
        } else {
            try elements.append(self.arena, .{ .normal = first_element });
        }

        while (self.current.kind != .r_bracket) {
            if (self.current.kind == .comma) {
                try self.advance();
                if (self.current.kind == .r_bracket) break;
            } else if (self.current.preceded_by_newline) {
                // Allow newline-separated elements
            } else {
                return error.UnexpectedToken;
            }

            // Check for spread operator
            const is_spread = self.current.kind == .dot_dot_dot;
            if (is_spread) {
                try self.advance(); // consume ...
            }

            const element = try self.parseLambda();
            if (is_spread) {
                try elements.append(self.arena, .{ .spread = element });
            } else {
                try elements.append(self.arena, .{ .normal = element });
            }
        }

        try self.expect(.r_bracket);

        const slice = try elements.toOwnedSlice(self.arena);
        const node = try self.allocateExpression();
        node.* = .{ .array = .{ .elements = slice } };
        return node;
    }

    fn parseArrayComprehension(self: *Parser, body: *Expression) ParseError!*Expression {
        var clauses = std.ArrayListUnmanaged(ForClause){};

        // Parse for clauses
        while (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "for")) {
            try self.advance(); // consume 'for'

            // Parse pattern
            const pattern = try self.parsePattern();

            // Expect 'in'
            if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "in")) {
                self.recordError();
                return error.UnexpectedToken;
            }
            try self.advance(); // consume 'in'

            // Parse iterable expression
            const iterable = try self.parseBinary(0);

            try clauses.append(self.arena, .{ .pattern = pattern, .iterable = iterable });
        }

        // Parse optional 'when' filter
        var filter: ?*Expression = null;
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "when")) {
            try self.advance(); // consume 'when'
            filter = try self.parseBinary(0);
        }

        try self.expect(.r_bracket);

        const node = try self.allocateExpression();
        node.* = .{ .array_comprehension = .{
            .body = body,
            .clauses = try clauses.toOwnedSlice(self.arena),
            .filter = filter,
        } };
        return node;
    }

    fn parseObject(self: *Parser) ParseError!*Expression {
        try self.expect(.l_brace);

        // Empty object
        if (self.current.kind == .r_brace) {
            try self.advance();
            const node = try self.allocateExpression();
            node.* = .{ .object = .{ .fields = &[_]ObjectField{} } };
            return node;
        }

        // Check for object comprehension with dynamic field syntax: { [key]: value for ... }
        if (self.current.kind == .l_bracket) {
            try self.advance(); // consume '['
            const key_expr = try self.parseLambda();
            try self.expect(.r_bracket);
            try self.expect(.colon);
            const value_expr = try self.parseLambda();

            // Check if this is a comprehension
            const is_comprehension = self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "for");

            if (is_comprehension) {
                return self.parseObjectComprehension(key_expr, value_expr);
            }

            // TODO: Support dynamic fields in regular objects
            // For now, just return an error
            self.recordError();
            return error.UnexpectedToken;
        }

        // Consume doc comments that were accumulated during lookahead tokenization
        // These will be for the first field (if there is one)
        const first_field_doc = self.tokenizer.consumeDocComments();

        var fields = std.ArrayListUnmanaged(ObjectField){};
        var is_first_field = true;

        while (self.current.kind != .r_brace) {
            if (self.current.kind != .identifier) {
                // Clear any pending doc comments if we don't find an identifier
                self.tokenizer.clearDocComments();
                return error.UnexpectedToken;
            }

            // Use the doc comments we saved for the first field,
            // or consume fresh ones for subsequent fields
            const doc = if (is_first_field) blk: {
                is_first_field = false;
                break :blk first_field_doc;
            } else self.tokenizer.consumeDocComments();

            const key = self.current.lexeme;
            try self.advance();

            // Check for three forms:
            // 1. Long form with colon: `field: value` (is_patch = false)
            // 2. Patch form: `field { ... }` (is_patch = true)
            // 3. Short form: `field` (is_patch = false, expands to `field: field`)
            var is_patch = false;
            const value_expr = if (self.current.kind == .colon) blk: {
                try self.advance();
                break :blk try self.parseLambda();
            } else if (self.current.kind == .l_brace and !self.current.preceded_by_newline) blk: {
                // Patch form: field followed by object
                is_patch = true;
                break :blk try self.parseObject();
            } else blk: {
                // Short form: create an identifier reference with the same name as the key
                const node = try self.allocateExpression();
                node.* = .{ .identifier = key };
                break :blk node;
            };

            try fields.append(self.arena, .{ .key = key, .value = value_expr, .is_patch = is_patch, .doc = doc });

            if (self.current.kind == .comma) {
                try self.advance();
                if (self.current.kind == .r_brace) break;
                continue;
            }

            if (self.current.kind == .r_brace) break;

            if (self.current.preceded_by_newline) {
                continue;
            }

            return error.UnexpectedToken;
        }

        try self.expect(.r_brace);

        const slice = try fields.toOwnedSlice(self.arena);
        const node = try self.allocateExpression();
        node.* = .{ .object = .{ .fields = slice } };
        return node;
    }

    fn parseObjectComprehension(self: *Parser, key: *Expression, value: *Expression) ParseError!*Expression {
        var clauses = std.ArrayListUnmanaged(ForClause){};

        // Parse for clauses
        while (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "for")) {
            try self.advance(); // consume 'for'

            // Parse pattern
            const pattern = try self.parsePattern();

            // Expect 'in'
            if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "in")) {
                self.recordError();
                return error.UnexpectedToken;
            }
            try self.advance(); // consume 'in'

            // Parse iterable expression
            const iterable = try self.parseBinary(0);

            try clauses.append(self.arena, .{ .pattern = pattern, .iterable = iterable });
        }

        // Parse optional 'when' filter
        var filter: ?*Expression = null;
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "when")) {
            try self.advance(); // consume 'when'
            filter = try self.parseBinary(0);
        }

        try self.expect(.r_brace);

        const node = try self.allocateExpression();
        node.* = .{ .object_comprehension = .{
            .key = key,
            .value = value,
            .clauses = try clauses.toOwnedSlice(self.arena),
            .filter = filter,
        } };
        return node;
    }

    fn parseTupleOrParenthesized(self: *Parser) ParseError!*Expression {
        try self.expect(.l_paren);

        // Empty tuple: ()
        if (self.current.kind == .r_paren) {
            try self.advance();
            const node = try self.allocateExpression();
            node.* = .{ .tuple = .{ .elements = &[_]*Expression{} } };
            return node;
        }

        // Parse first element
        const first = try self.parseLambda();

        // If no comma follows, it's a parenthesized expression
        if (self.current.kind != .comma) {
            try self.expect(.r_paren);
            return first;
        }

        // It's a tuple - collect all elements
        var elements = std.ArrayListUnmanaged(*Expression){};
        try elements.append(self.arena, first);

        while (self.current.kind == .comma) {
            try self.advance();
            // Allow trailing comma
            if (self.current.kind == .r_paren) break;

            const element = try self.parseLambda();
            try elements.append(self.arena, element);
        }

        try self.expect(.r_paren);

        const slice = try elements.toOwnedSlice(self.arena);
        const node = try self.allocateExpression();
        node.* = .{ .tuple = .{ .elements = slice } };
        return node;
    }

    fn parsePattern(self: *Parser) ParseError!*Pattern {
        switch (self.current.kind) {
            .number => {
                const lexeme = self.current.lexeme;
                const value = try std.fmt.parseInt(i64, lexeme, 10);
                try self.advance();
                const pattern = try self.arena.create(Pattern);
                pattern.* = .{ .integer = value };
                return pattern;
            },
            .string => {
                const value = self.current.lexeme;
                try self.advance();
                const pattern = try self.arena.create(Pattern);
                pattern.* = .{ .string_literal = value };
                return pattern;
            },
            .symbol => {
                const value = self.current.lexeme;
                try self.advance();
                const pattern = try self.arena.create(Pattern);
                pattern.* = .{ .symbol = value };
                return pattern;
            },
            .identifier => {
                const name = self.current.lexeme;

                // Check for boolean and null literals
                if (std.mem.eql(u8, name, "true")) {
                    try self.advance();
                    const pattern = try self.arena.create(Pattern);
                    pattern.* = .{ .boolean = true };
                    return pattern;
                }
                if (std.mem.eql(u8, name, "false")) {
                    try self.advance();
                    const pattern = try self.arena.create(Pattern);
                    pattern.* = .{ .boolean = false };
                    return pattern;
                }
                if (std.mem.eql(u8, name, "null")) {
                    try self.advance();
                    const pattern = try self.arena.create(Pattern);
                    pattern.* = .null_literal;
                    return pattern;
                }

                // Regular identifier pattern
                try self.advance();
                const pattern = try self.arena.create(Pattern);
                pattern.* = .{ .identifier = name };
                return pattern;
            },
            .l_paren => return self.parseTuplePattern(),
            .l_bracket => return self.parseArrayPattern(),
            .l_brace => return self.parseObjectPattern(),
            else => return error.UnexpectedToken,
        }
    }

    fn parseTuplePattern(self: *Parser) ParseError!*Pattern {
        try self.expect(.l_paren);

        var elements = std.ArrayListUnmanaged(*Pattern){};

        while (self.current.kind != .r_paren) {
            const element = try self.parsePattern();
            try elements.append(self.arena, element);

            if (self.current.kind == .comma) {
                try self.advance();
                if (self.current.kind == .r_paren) break;
                continue;
            }

            if (self.current.kind == .r_paren) break;
            return error.UnexpectedToken;
        }

        try self.expect(.r_paren);

        const slice = try elements.toOwnedSlice(self.arena);
        const pattern = try self.arena.create(Pattern);
        pattern.* = .{ .tuple = .{ .elements = slice } };
        return pattern;
    }

    fn parseArrayPattern(self: *Parser) ParseError!*Pattern {
        try self.expect(.l_bracket);

        var elements = std.ArrayListUnmanaged(*Pattern){};
        var rest: ?[]const u8 = null;

        while (self.current.kind != .r_bracket) {
            // Check for spread operator
            if (self.current.kind == .dot_dot_dot) {
                try self.advance();
                // Expect an identifier after ...
                if (self.current.kind != .identifier) {
                    return error.UnexpectedToken;
                }
                rest = self.current.lexeme;
                try self.advance();
                // After spread, we should only see the closing bracket
                break;
            }

            const element = try self.parsePattern();
            try elements.append(self.arena, element);

            if (self.current.kind == .comma) {
                try self.advance();
                if (self.current.kind == .r_bracket) break;
                continue;
            }

            if (self.current.kind == .r_bracket) break;
            return error.UnexpectedToken;
        }

        try self.expect(.r_bracket);

        const slice = try elements.toOwnedSlice(self.arena);
        const pattern = try self.arena.create(Pattern);
        pattern.* = .{ .array = .{ .elements = slice, .rest = rest } };
        return pattern;
    }

    fn parseObjectPattern(self: *Parser) ParseError!*Pattern {
        try self.expect(.l_brace);

        var fields = std.ArrayListUnmanaged(ObjectPatternField){};

        while (self.current.kind != .r_brace) {
            if (self.current.kind != .identifier) return error.UnexpectedToken;
            const field_name = self.current.lexeme;
            try self.advance();

            // Check if there's a colon (field with pattern) or not (field extraction)
            if (self.current.kind == .colon) {
                // Parse field pattern: { key: pattern }
                try self.advance();
                const field_pattern = try self.parsePattern();
                try fields.append(self.arena, .{
                    .key = field_name,
                    .pattern = field_pattern,
                });
            } else {
                // Field extraction: { key } is short for { key: key }
                const field_pattern = try self.arena.create(Pattern);
                field_pattern.* = .{ .identifier = field_name };
                try fields.append(self.arena, .{
                    .key = field_name,
                    .pattern = field_pattern,
                });
            }

            if (self.current.kind == .comma) {
                try self.advance();
                if (self.current.kind == .r_brace) break;
                continue;
            }

            if (self.current.kind == .r_brace) break;
            return error.UnexpectedToken;
        }

        try self.expect(.r_brace);

        const slice = try fields.toOwnedSlice(self.arena);
        const pattern = try self.arena.create(Pattern);
        pattern.* = .{ .object = .{ .fields = slice } };
        return pattern;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!void {
        if (self.current.kind != kind) {
            self.recordError();
            return error.UnexpectedToken;
        }
        try self.advance();
    }

    fn advance(self: *Parser) ParseError!void {
        self.current = self.lookahead;
        self.lookahead = try self.tokenizer.next();
    }

    fn parseStringInterpolation(self: *Parser, string_content: []const u8) ParseError![]StringPart {
        var parts = std.ArrayListUnmanaged(StringPart){};
        var i: usize = 0;
        var literal_start: usize = 0;

        while (i < string_content.len) {
            if (string_content[i] == '$') {
                // Add any literal part before the interpolation
                if (i > literal_start) {
                    try parts.append(self.arena, .{ .literal = string_content[literal_start..i] });
                }

                i += 1; // skip '$'

                if (i < string_content.len and string_content[i] == '{') {
                    // Complex interpolation: ${expression}
                    i += 1; // skip '{'

                    // Find the matching '}'
                    var brace_depth: usize = 1;
                    const expr_start = i;
                    while (i < string_content.len and brace_depth > 0) {
                        if (string_content[i] == '{') {
                            brace_depth += 1;
                        } else if (string_content[i] == '}') {
                            brace_depth -= 1;
                        }
                        if (brace_depth > 0) i += 1;
                    }

                    if (brace_depth != 0) {
                        return error.UnterminatedString;
                    }

                    // Parse the expression inside ${}
                    const expr_source = string_content[expr_start..i];
                    var expr_parser = try Parser.init(self.arena, expr_source);
                    const expr = try expr_parser.parseLambda();

                    try parts.append(self.arena, .{ .interpolation = expr });

                    i += 1; // skip '}'
                    literal_start = i;
                } else {
                    // Simple interpolation: $identifier
                    const ident_start = i;
                    while (i < string_content.len and (std.ascii.isAlphanumeric(string_content[i]) or string_content[i] == '_')) {
                        i += 1;
                    }

                    if (i == ident_start) {
                        // Just a '$' with no identifier following
                        try parts.append(self.arena, .{ .literal = "$" });
                    } else {
                        const ident = string_content[ident_start..i];
                        const expr = try self.allocateExpression();
                        expr.* = .{ .identifier = ident };
                        try parts.append(self.arena, .{ .interpolation = expr });
                    }

                    literal_start = i;
                }
            } else {
                i += 1;
            }
        }

        // Add any remaining literal part
        if (literal_start < string_content.len) {
            try parts.append(self.arena, .{ .literal = string_content[literal_start..] });
        }

        // If no parts were added, return a single empty literal
        if (parts.items.len == 0) {
            try parts.append(self.arena, .{ .literal = "" });
        }

        return try parts.toOwnedSlice(self.arena);
    }

    fn allocateExpression(self: *Parser) ParseError!*Expression {
        return try self.arena.create(Expression);
    }
};

fn getPrecedence(kind: TokenKind) ?u32 {
    return switch (kind) {
        .backslash => 2,
        .pipe_pipe => 3,
        .ampersand_ampersand => 4,
        .equals_equals, .bang_equals, .less, .greater, .less_equals, .greater_equals => 5,
        .ampersand => 6, // Object merge operator
        .plus, .minus => 7,
        .star => 8,
        else => null,
    };
}

pub const Environment = struct {
    parent: ?*Environment,
    name: []const u8,
    value: Value,
};

pub const FunctionValue = struct {
    param: *Pattern,
    body: *Expression,
    env: ?*Environment,
};

pub const NativeFn = *const fn (arena: std.mem.Allocator, args: []const Value) EvalError!Value;

pub const ThunkState = union(enum) {
    unevaluated,
    evaluating, // For cycle detection
    evaluated: Value,
};

pub const Thunk = struct {
    expr: *Expression,
    env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
    state: ThunkState,
};

pub const Value = union(enum) {
    integer: i64,
    boolean: bool,
    null_value,
    symbol: []const u8,
    function: *FunctionValue,
    native_fn: NativeFn,
    array: ArrayValue,
    tuple: TupleValue,
    object: ObjectValue,
    string: []const u8,
    thunk: *Thunk,
};

pub const ArrayValue = struct {
    elements: []Value,
};

pub const TupleValue = struct {
    elements: []Value,
};

pub const ObjectFieldValue = struct {
    key: []const u8,
    value: Value,
};

pub const ObjectValue = struct {
    fields: []ObjectFieldValue,
};

fn valuesEqual(a: Value, b: Value) bool {
    return switch (a) {
        .integer => |av| switch (b) {
            .integer => |bv| av == bv,
            else => false,
        },
        .boolean => |av| switch (b) {
            .boolean => |bv| av == bv,
            else => false,
        },
        .null_value => switch (b) {
            .null_value => true,
            else => false,
        },
        .symbol => |av| switch (b) {
            .symbol => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .string => |av| switch (b) {
            .string => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .function => false, // Functions are not comparable
        .native_fn => false, // Native functions are not comparable
        .thunk => false, // Thunks should be forced before comparison
        .array => |av| switch (b) {
            .array => |bv| blk: {
                if (av.elements.len != bv.elements.len) break :blk false;
                for (av.elements, 0..) |elem, i| {
                    if (!valuesEqual(elem, bv.elements[i])) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .tuple => |av| switch (b) {
            .tuple => |bv| blk: {
                if (av.elements.len != bv.elements.len) break :blk false;
                for (av.elements, 0..) |elem, i| {
                    if (!valuesEqual(elem, bv.elements[i])) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |av| switch (b) {
            .object => |bv| blk: {
                if (av.fields.len != bv.fields.len) break :blk false;
                for (av.fields) |afield| {
                    var found = false;
                    for (bv.fields) |bfield| {
                        if (std.mem.eql(u8, afield.key, bfield.key)) {
                            if (!valuesEqual(afield.value, bfield.value)) break :blk false;
                            found = true;
                            break;
                        }
                    }
                    if (!found) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
    };
}

pub const EvalError = ParseError || std.mem.Allocator.Error || std.process.GetEnvVarOwnedError || std.fs.File.OpenError || std.fs.File.ReadError || error{
    UnknownIdentifier,
    TypeMismatch,
    ExpectedFunction,
    ModuleNotFound,
    Overflow,
    FileTooBig,
    WrongNumberOfArguments,
    InvalidArgument,
    UnknownField,
    UserCrash,
    CyclicReference,
};

pub const EvalContext = struct {
    allocator: std.mem.Allocator,
    lazy_paths: [][]const u8,
    error_ctx: ?*error_context.ErrorContext = null,
};

const ModuleFile = struct {
    path: []u8,
    file: std.fs.File,
};

fn collectLazyPaths(arena: std.mem.Allocator) EvalError![][]const u8 {
    var list = std.ArrayList([]const u8){};
    defer list.deinit(arena);

    // Always include ./stdlib/lib as a default search path
    const default_lib = try arena.dupe(u8, "stdlib/lib");
    try list.append(arena, default_lib);

    const env_value = std.process.getEnvVarOwned(arena, "LAZYLANG_PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return try list.toOwnedSlice(arena),
        else => return err,
    };

    if (env_value.len == 0) {
        return try list.toOwnedSlice(arena);
    }

    var parts = std.mem.splitScalar(u8, env_value, std.fs.path.delimiter);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const copy = try arena.dupe(u8, part);
        try list.append(arena, copy);
    }

    return try list.toOwnedSlice(arena);
}

fn normalizedImportPath(allocator: std.mem.Allocator, import_path: []const u8) ![]u8 {
    if (std.fs.path.extension(import_path).len == 0) {
        return try std.fmt.allocPrint(allocator, "{s}.lazy", .{import_path});
    }
    return try allocator.dupe(u8, import_path);
}

fn openImportFile(ctx: *const EvalContext, import_path: []const u8, current_dir: ?[]const u8) EvalError!ModuleFile {
    const normalized = try normalizedImportPath(ctx.allocator, import_path);
    errdefer ctx.allocator.free(normalized);

    if (current_dir) |dir| {
        const candidate = try std.fs.path.join(ctx.allocator, &.{ dir, normalized });
        const maybe_file = std.fs.cwd().openFile(candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (maybe_file) |file| {
            ctx.allocator.free(normalized);
            return .{ .path = candidate, .file = file };
        }
        ctx.allocator.free(candidate);
    }

    const relative_file = std.fs.cwd().openFile(normalized, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (relative_file) |file| {
        return .{ .path = normalized, .file = file };
    }

    for (ctx.lazy_paths) |base| {
        const candidate = try std.fs.path.join(ctx.allocator, &.{ base, normalized });
        const maybe_file = std.fs.cwd().openFile(candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (maybe_file) |file| {
            ctx.allocator.free(normalized);
            return .{ .path = candidate, .file = file };
        }
        ctx.allocator.free(candidate);
    }

    return error.ModuleNotFound;
}

pub fn matchPattern(
    arena: std.mem.Allocator,
    pattern: *Pattern,
    value: Value,
    base_env: ?*Environment,
) EvalError!?*Environment {
    return switch (pattern.*) {
        .identifier => |name| blk: {
            const new_env = try arena.create(Environment);
            new_env.* = .{
                .parent = base_env,
                .name = name,
                .value = value,
            };
            break :blk new_env;
        },
        .integer => |expected| blk: {
            const actual = switch (value) {
                .integer => |v| v,
                else => return error.TypeMismatch,
            };
            if (expected != actual) return error.TypeMismatch;
            break :blk base_env;
        },
        .boolean => |expected| blk: {
            const actual = switch (value) {
                .boolean => |v| v,
                else => return error.TypeMismatch,
            };
            if (expected != actual) return error.TypeMismatch;
            break :blk base_env;
        },
        .null_literal => blk: {
            switch (value) {
                .null_value => {},
                else => return error.TypeMismatch,
            }
            break :blk base_env;
        },
        .string_literal => |expected| blk: {
            const actual = switch (value) {
                .string => |v| v,
                else => return error.TypeMismatch,
            };
            if (!std.mem.eql(u8, expected, actual)) return error.TypeMismatch;
            break :blk base_env;
        },
        .symbol => |expected| blk: {
            const actual = switch (value) {
                .symbol => |v| v,
                else => return error.TypeMismatch,
            };
            if (!std.mem.eql(u8, expected, actual)) return error.TypeMismatch;
            break :blk base_env;
        },
        .tuple => |tuple_pattern| blk: {
            const tuple_value = switch (value) {
                .tuple => |t| t,
                else => return error.TypeMismatch,
            };

            if (tuple_pattern.elements.len != tuple_value.elements.len) {
                return error.TypeMismatch;
            }

            var current_env = base_env;
            for (tuple_pattern.elements, 0..) |elem_pattern, i| {
                current_env = try matchPattern(arena, elem_pattern, tuple_value.elements[i], current_env);
            }
            break :blk current_env;
        },
        .array => |array_pattern| blk: {
            const array_value = switch (value) {
                .array => |a| a,
                else => return error.TypeMismatch,
            };

            // If there's no rest pattern, lengths must match exactly
            if (array_pattern.rest == null) {
                if (array_pattern.elements.len != array_value.elements.len) {
                    return error.TypeMismatch;
                }
            } else {
                // With rest pattern, array must have at least as many elements as fixed patterns
                if (array_value.elements.len < array_pattern.elements.len) {
                    return error.TypeMismatch;
                }
            }

            var current_env = base_env;

            // Match fixed elements
            for (array_pattern.elements, 0..) |elem_pattern, i| {
                current_env = try matchPattern(arena, elem_pattern, array_value.elements[i], current_env);
            }

            // If there's a rest pattern, bind remaining elements to it
            if (array_pattern.rest) |rest_name| {
                const remaining_count = array_value.elements.len - array_pattern.elements.len;
                const remaining_elements = try arena.alloc(Value, remaining_count);
                for (0..remaining_count) |i| {
                    remaining_elements[i] = array_value.elements[array_pattern.elements.len + i];
                }
                const rest_array = Value{ .array = .{ .elements = remaining_elements } };
                const new_env = try arena.create(Environment);
                new_env.* = .{
                    .parent = current_env,
                    .name = rest_name,
                    .value = rest_array,
                };
                current_env = new_env;
            }

            break :blk current_env;
        },
        .object => |object_pattern| blk: {
            const object_value = switch (value) {
                .object => |o| o,
                else => return error.TypeMismatch,
            };

            var current_env = base_env;
            for (object_pattern.fields) |pattern_field| {
                // Find the field in the object value
                var found = false;
                for (object_value.fields) |value_field| {
                    if (std.mem.eql(u8, value_field.key, pattern_field.key)) {
                        // Force the field value if it's a thunk, then match the pattern
                        const forced_value = try force(arena, value_field.value);
                        current_env = try matchPattern(arena, pattern_field.pattern, forced_value, current_env);
                        found = true;
                        break;
                    }
                }
                if (!found) return error.TypeMismatch;
            }
            break :blk current_env;
        },
    };
}

fn findObjectField(obj: ObjectValue, key: []const u8) ?Value {
    for (obj.fields) |field| {
        if (std.mem.eql(u8, field.key, key)) {
            return field.value;
        }
    }
    return null;
}

fn mergeObjects(arena: std.mem.Allocator, base: ObjectValue, extension: ObjectValue) EvalError!Value {
    // Create a map to track which keys we've seen
    var result_fields = std.ArrayListUnmanaged(ObjectFieldValue){};

    // First, add all fields from base
    for (base.fields) |base_field| {
        // Check if this field is overridden in extension
        var found_override = false;
        for (extension.fields) |ext_field| {
            if (std.mem.eql(u8, base_field.key, ext_field.key)) {
                found_override = true;
                // Use the extension value (it overrides the base)
                const key_copy = try arena.dupe(u8, ext_field.key);
                try result_fields.append(arena, .{ .key = key_copy, .value = ext_field.value });
                break;
            }
        }
        if (!found_override) {
            // No override, keep the base field
            const key_copy = try arena.dupe(u8, base_field.key);
            try result_fields.append(arena, .{ .key = key_copy, .value = base_field.value });
        }
    }

    // Then, add fields from extension that are not in base
    for (extension.fields) |ext_field| {
        var found_in_base = false;
        for (base.fields) |base_field| {
            if (std.mem.eql(u8, base_field.key, ext_field.key)) {
                found_in_base = true;
                break;
            }
        }
        if (!found_in_base) {
            const key_copy = try arena.dupe(u8, ext_field.key);
            try result_fields.append(arena, .{ .key = key_copy, .value = ext_field.value });
        }
    }

    return Value{ .object = .{ .fields = try result_fields.toOwnedSlice(arena) } };
}

/// Force evaluation of a thunk if needed
pub fn force(arena: std.mem.Allocator, value: Value) EvalError!Value {
    return switch (value) {
        .thunk => |thunk| {
            switch (thunk.state) {
                .evaluated => |v| return v,
                .evaluating => return error.CyclicReference,
                .unevaluated => {
                    thunk.state = .evaluating;
                    const result = try evaluateExpression(arena, thunk.expr, thunk.env, thunk.current_dir, thunk.ctx);
                    thunk.state = .{ .evaluated = result };
                    return result;
                },
            }
        },
        else => value,
    };
}

pub fn evaluateExpression(
    arena: std.mem.Allocator,
    expr: *Expression,
    env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!Value {
    return switch (expr.*) {
        .integer => |value| .{ .integer = value },
        .boolean => |value| .{ .boolean = value },
        .null_literal => .null_value,
        .symbol => |value| .{ .symbol = try arena.dupe(u8, value) },
        .identifier => |name| blk: {
            const resolved = lookup(env, name) orelse return error.UnknownIdentifier;
            break :blk resolved;
        },
        .string_literal => |value| .{ .string = try arena.dupe(u8, value) },
        .string_interpolation => |interp| blk: {
            var result = std.ArrayListUnmanaged(u8){};
            for (interp.parts) |part| {
                switch (part) {
                    .literal => |lit| {
                        try result.appendSlice(arena, lit);
                    },
                    .interpolation => |interp_expr| {
                        const interp_value = try evaluateExpression(arena, interp_expr, env, current_dir, ctx);
                        const str_value = try valueToString(arena, interp_value);
                        try result.appendSlice(arena, str_value);
                    },
                }
            }
            break :blk .{ .string = try result.toOwnedSlice(arena) };
        },
        .lambda => |lambda| blk: {
            const function = try arena.create(FunctionValue);
            function.* = .{ .param = lambda.param, .body = lambda.body, .env = env };
            break :blk Value{ .function = function };
        },
        .let => |let_expr| blk: {
            // For recursive definitions, if the pattern is a simple identifier,
            // we create the environment binding before evaluating the value
            const is_recursive = switch (let_expr.pattern.*) {
                .identifier => true,
                else => false,
            };

            if (is_recursive) {
                const identifier = let_expr.pattern.identifier;
                // Create environment entry with placeholder value
                const recursive_env = try arena.create(Environment);
                recursive_env.* = .{
                    .parent = env,
                    .name = identifier,
                    .value = .null_value, // Placeholder
                };

                // Evaluate value with recursive environment
                const value = try evaluateExpression(arena, let_expr.value, recursive_env, current_dir, ctx);

                // Update the environment entry with the actual value
                recursive_env.value = value;

                // Evaluate body with the recursive environment
                break :blk try evaluateExpression(arena, let_expr.body, recursive_env, current_dir, ctx);
            } else {
                // Non-recursive case: evaluate value first, then pattern match
                const value = try evaluateExpression(arena, let_expr.value, env, current_dir, ctx);
                const new_env = try matchPattern(arena, let_expr.pattern, value, env);
                break :blk try evaluateExpression(arena, let_expr.body, new_env, current_dir, ctx);
            }
        },
        .unary => |unary| blk: {
            const operand_value = try evaluateExpression(arena, unary.operand, env, current_dir, ctx);
            const result = switch (unary.op) {
                .logical_not => blk2: {
                    const bool_val = switch (operand_value) {
                        .boolean => |v| v,
                        else => return error.TypeMismatch,
                    };
                    break :blk2 Value{ .boolean = !bool_val };
                },
            };
            break :blk result;
        },
        .binary => |binary| blk: {
            const left_value = try evaluateExpression(arena, binary.left, env, current_dir, ctx);
            const right_value = try evaluateExpression(arena, binary.right, env, current_dir, ctx);

            const result = switch (binary.op) {
                .add, .subtract, .multiply => blk2: {
                    const left_int = switch (left_value) {
                        .integer => |v| v,
                        else => return error.TypeMismatch,
                    };
                    const right_int = switch (right_value) {
                        .integer => |v| v,
                        else => return error.TypeMismatch,
                    };

                    const int_result = switch (binary.op) {
                        .add => try std.math.add(i64, left_int, right_int),
                        .subtract => try std.math.sub(i64, left_int, right_int),
                        .multiply => try std.math.mul(i64, left_int, right_int),
                        else => unreachable,
                    };
                    break :blk2 Value{ .integer = int_result };
                },
                .logical_and => blk2: {
                    const left_bool = switch (left_value) {
                        .boolean => |v| v,
                        else => return error.TypeMismatch,
                    };
                    const right_bool = switch (right_value) {
                        .boolean => |v| v,
                        else => return error.TypeMismatch,
                    };
                    break :blk2 Value{ .boolean = left_bool and right_bool };
                },
                .logical_or => blk2: {
                    const left_bool = switch (left_value) {
                        .boolean => |v| v,
                        else => return error.TypeMismatch,
                    };
                    const right_bool = switch (right_value) {
                        .boolean => |v| v,
                        else => return error.TypeMismatch,
                    };
                    break :blk2 Value{ .boolean = left_bool or right_bool };
                },
                .equal, .not_equal => blk2: {
                    const bool_result = switch (binary.op) {
                        .equal => valuesEqual(left_value, right_value),
                        .not_equal => !valuesEqual(left_value, right_value),
                        else => unreachable,
                    };
                    break :blk2 Value{ .boolean = bool_result };
                },
                .less_than, .greater_than, .less_or_equal, .greater_or_equal => blk2: {
                    const left_int = switch (left_value) {
                        .integer => |v| v,
                        else => return error.TypeMismatch,
                    };
                    const right_int = switch (right_value) {
                        .integer => |v| v,
                        else => return error.TypeMismatch,
                    };

                    const bool_result = switch (binary.op) {
                        .less_than => left_int < right_int,
                        .greater_than => left_int > right_int,
                        .less_or_equal => left_int <= right_int,
                        .greater_or_equal => left_int >= right_int,
                        else => unreachable,
                    };
                    break :blk2 Value{ .boolean = bool_result };
                },
                .pipeline => blk2: {
                    // Pipeline operator: x \ f evaluates to f(x)
                    // The left side is the value, the right side is the function
                    switch (right_value) {
                        .function => |function_ptr| {
                            const bound_env = try matchPattern(arena, function_ptr.param, left_value, function_ptr.env);
                            break :blk2 try evaluateExpression(arena, function_ptr.body, bound_env, current_dir, ctx);
                        },
                        .native_fn => |native_fn| {
                            const args = [_]Value{left_value};
                            break :blk2 try native_fn(arena, &args);
                        },
                        else => return error.ExpectedFunction,
                    }
                },
                .merge => blk2: {
                    // Object merge operator: obj1 & obj2
                    const left_obj = switch (left_value) {
                        .object => |o| o,
                        else => return error.TypeMismatch,
                    };
                    const right_obj = switch (right_value) {
                        .object => |o| o,
                        else => return error.TypeMismatch,
                    };

                    // Merge the two objects
                    break :blk2 try mergeObjects(arena, left_obj, right_obj);
                },
            };
            break :blk result;
        },
        .if_expr => |if_expr| blk: {
            const condition_value = try evaluateExpression(arena, if_expr.condition, env, current_dir, ctx);
            const condition_bool = switch (condition_value) {
                .boolean => |v| v,
                else => return error.TypeMismatch,
            };

            if (condition_bool) {
                break :blk try evaluateExpression(arena, if_expr.then_expr, env, current_dir, ctx);
            } else if (if_expr.else_expr) |else_expr| {
                break :blk try evaluateExpression(arena, else_expr, env, current_dir, ctx);
            } else {
                break :blk .null_value;
            }
        },
        .when_matches => |when_matches| blk: {
            const value = try evaluateExpression(arena, when_matches.value, env, current_dir, ctx);

            // Try each pattern branch
            for (when_matches.branches) |branch| {
                // Try to match the pattern
                const match_env = matchPattern(arena, branch.pattern, value, env) catch |err| {
                    // If pattern doesn't match, try next branch
                    if (err == error.TypeMismatch) continue;
                    return err;
                };

                // Pattern matched, evaluate the expression
                break :blk try evaluateExpression(arena, branch.expression, match_env, current_dir, ctx);
            }

            // No pattern matched, check for otherwise clause
            if (when_matches.otherwise) |otherwise_expr| {
                break :blk try evaluateExpression(arena, otherwise_expr, env, current_dir, ctx);
            }

            // No pattern matched and no otherwise clause - error
            return error.TypeMismatch;
        },
        .application => |application| blk: {
            const function_value = try evaluateExpression(arena, application.function, env, current_dir, ctx);
            const argument_value = try evaluateExpression(arena, application.argument, env, current_dir, ctx);

            switch (function_value) {
                .function => |function_ptr| {
                    const bound_env = try matchPattern(arena, function_ptr.param, argument_value, function_ptr.env);
                    break :blk try evaluateExpression(arena, function_ptr.body, bound_env, current_dir, ctx);
                },
                .native_fn => |native_fn| {
                    // Native functions receive a single argument (could be a tuple for multiple args)
                    const args = [_]Value{argument_value};
                    break :blk try native_fn(arena, &args);
                },
                else => return error.ExpectedFunction,
            }
        },
        .array => |array| blk: {
            // First pass: evaluate all elements and count total size
            var temp_values = std.ArrayList(Value){};
            defer temp_values.deinit(arena);

            for (array.elements) |element| {
                switch (element) {
                    .normal => |elem_expr| {
                        const value = try evaluateExpression(arena, elem_expr, env, current_dir, ctx);
                        try temp_values.append(arena, value);
                    },
                    .spread => |spread_expr| {
                        const value = try evaluateExpression(arena, spread_expr, env, current_dir, ctx);
                        const spread_array = switch (value) {
                            .array => |a| a,
                            else => return error.TypeMismatch,
                        };
                        for (spread_array.elements) |spread_elem| {
                            try temp_values.append(arena, spread_elem);
                        }
                    },
                }
            }

            break :blk Value{ .array = .{ .elements = try temp_values.toOwnedSlice(arena) } };
        },
        .tuple => |tuple| blk: {
            const values = try arena.alloc(Value, tuple.elements.len);
            for (tuple.elements, 0..) |element, i| {
                values[i] = try evaluateExpression(arena, element, env, current_dir, ctx);
            }
            break :blk Value{ .tuple = .{ .elements = values } };
        },
        .object => |object| blk: {
            const fields = try arena.alloc(ObjectFieldValue, object.fields.len);
            for (object.fields, 0..) |field, i| {
                const key_copy = try arena.dupe(u8, field.key);
                // Wrap field value in a thunk for lazy evaluation
                const thunk = try arena.create(Thunk);
                thunk.* = .{
                    .expr = field.value,
                    .env = env,
                    .current_dir = current_dir,
                    .ctx = ctx,
                    .state = .unevaluated,
                };
                fields[i] = .{ .key = key_copy, .value = .{ .thunk = thunk } };
            }
            break :blk Value{ .object = .{ .fields = fields } };
        },
        .object_extend => |extend| blk: {
            // Evaluate the base expression
            const base_value = try evaluateExpression(arena, extend.base, env, current_dir, ctx);

            // Check if base is a function - if so, treat this as function application
            switch (base_value) {
                .function => |function_ptr| {
                    // Build an object from the extension fields and apply the function
                    const fields = try arena.alloc(ObjectFieldValue, extend.fields.len);
                    for (extend.fields, 0..) |field, i| {
                        const key_copy = try arena.dupe(u8, field.key);
                        fields[i] = .{ .key = key_copy, .value = try evaluateExpression(arena, field.value, env, current_dir, ctx) };
                    }
                    const obj_arg = Value{ .object = .{ .fields = fields } };
                    const bound_env = try matchPattern(arena, function_ptr.param, obj_arg, function_ptr.env);
                    break :blk try evaluateExpression(arena, function_ptr.body, bound_env, current_dir, ctx);
                },
                .native_fn => |native_fn| {
                    // Build an object from the extension fields and call native function
                    const fields = try arena.alloc(ObjectFieldValue, extend.fields.len);
                    for (extend.fields, 0..) |field, i| {
                        const key_copy = try arena.dupe(u8, field.key);
                        fields[i] = .{ .key = key_copy, .value = try evaluateExpression(arena, field.value, env, current_dir, ctx) };
                    }
                    const obj_arg = Value{ .object = .{ .fields = fields } };
                    const args = [_]Value{obj_arg};
                    break :blk try native_fn(arena, &args);
                },
                .object => |base_obj| {
                    // Build the extension object with proper handling of is_patch
                    var extension_fields = std.ArrayListUnmanaged(ObjectFieldValue){};
                    for (extend.fields) |field| {
                        const key_copy = try arena.dupe(u8, field.key);
                        const value = try evaluateExpression(arena, field.value, env, current_dir, ctx);

                        if (field.is_patch) {
                            // Patch: merge with existing field if it exists and is an object
                            const existing_value = findObjectField(base_obj, field.key);
                            if (existing_value) |existing| {
                                // Force the existing value if it's a thunk
                                const forced_existing = try force(arena, existing);
                                const existing_obj = switch (forced_existing) {
                                    .object => |o| o,
                                    else => return error.TypeMismatch,
                                };
                                const value_obj = switch (value) {
                                    .object => |o| o,
                                    else => return error.TypeMismatch,
                                };
                                const merged = try mergeObjects(arena, existing_obj, value_obj);
                                try extension_fields.append(arena, .{ .key = key_copy, .value = merged });
                            } else {
                                // Field doesn't exist in base, just add it
                                try extension_fields.append(arena, .{ .key = key_copy, .value = value });
                            }
                        } else {
                            // Overwrite: just use the new value
                            try extension_fields.append(arena, .{ .key = key_copy, .value = value });
                        }
                    }

                    // Merge base with extension
                    const extension_obj = ObjectValue{ .fields = try extension_fields.toOwnedSlice(arena) };
                    break :blk try mergeObjects(arena, base_obj, extension_obj);
                },
                else => return error.TypeMismatch,
            }
        },
        .array_comprehension => |comp| blk: {
            var result_list = std.ArrayListUnmanaged(Value){};
            try evaluateArrayComprehension(arena, &result_list, comp, 0, env, current_dir, ctx);
            break :blk Value{ .array = .{ .elements = try result_list.toOwnedSlice(arena) } };
        },
        .object_comprehension => |comp| blk: {
            var result_fields = std.ArrayListUnmanaged(ObjectFieldValue){};
            try evaluateObjectComprehension(arena, &result_fields, comp, 0, env, current_dir, ctx);
            break :blk Value{ .object = .{ .fields = try result_fields.toOwnedSlice(arena) } };
        },
        .import_expr => |import_expr| try importModule(arena, import_expr.path, current_dir, ctx),
        .field_access => |field_access| blk: {
            const object_value = try evaluateExpression(arena, field_access.object, env, current_dir, ctx);
            break :blk try accessField(arena, object_value, field_access.field);
        },
        .field_accessor => |field_accessor| blk: {
            // Create a function that accesses the specified fields
            const param = try arena.create(Pattern);
            param.* = .{ .identifier = "__obj" };

            // Build the body expression: __obj.field1.field2...
            var body_expr = try arena.create(Expression);
            body_expr.* = .{ .identifier = "__obj" };

            for (field_accessor.fields) |field_name| {
                const field_access_expr = try arena.create(Expression);
                field_access_expr.* = .{ .field_access = .{
                    .object = body_expr,
                    .field = field_name,
                } };
                body_expr = field_access_expr;
            }

            const func_value = try arena.create(FunctionValue);
            func_value.* = .{
                .param = param,
                .body = body_expr,
                .env = env,
            };

            break :blk Value{ .function = func_value };
        },
        .field_projection => |field_projection| blk: {
            const object_value = try evaluateExpression(arena, field_projection.object, env, current_dir, ctx);

            // Verify it's an object
            _ = switch (object_value) {
                .object => |obj| obj,
                else => return error.TypeMismatch,
            };

            // Create new object with only the specified fields
            const new_fields = try arena.alloc(ObjectFieldValue, field_projection.fields.len);
            for (field_projection.fields, 0..) |field_name, i| {
                const field_value = try accessField(arena, object_value, field_name);
                new_fields[i] = .{
                    .key = try arena.dupe(u8, field_name),
                    .value = field_value,
                };
            }

            break :blk Value{ .object = .{ .fields = new_fields } };
        },
    };
}

fn accessField(arena: std.mem.Allocator, object_value: Value, field_name: []const u8) EvalError!Value {
    const object = switch (object_value) {
        .object => |obj| obj,
        else => return error.TypeMismatch,
    };

    // Look for the field
    for (object.fields) |field| {
        if (std.mem.eql(u8, field.key, field_name)) {
            // Force the thunk if the value is a thunk
            return try force(arena, field.value);
        }
    }

    // Field not found - provide "did you mean" suggestions (TODO: implement)
    return error.UnknownField;
}

fn evaluateArrayComprehension(
    arena: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(Value),
    comp: ArrayComprehension,
    clause_index: usize,
    env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!void {
    // Base case: all for clauses have been processed
    if (clause_index >= comp.clauses.len) {
        // Check the filter condition if present
        if (comp.filter) |filter| {
            const filter_value = try evaluateExpression(arena, filter, env, current_dir, ctx);
            const filter_bool = switch (filter_value) {
                .boolean => |b| b,
                else => return error.TypeMismatch,
            };
            if (!filter_bool) return; // Skip this iteration
        }

        // Evaluate and add the body to the result
        const value = try evaluateExpression(arena, comp.body, env, current_dir, ctx);
        try result.append(arena, value);
        return;
    }

    // Process current for clause
    const clause = comp.clauses[clause_index];
    const iterable_value = try evaluateExpression(arena, clause.iterable, env, current_dir, ctx);

    switch (iterable_value) {
        .array => |arr| {
            for (arr.elements) |element| {
                const new_env = try matchPattern(arena, clause.pattern, element, env);
                try evaluateArrayComprehension(arena, result, comp, clause_index + 1, new_env, current_dir, ctx);
            }
        },
        else => return error.TypeMismatch,
    }
}

fn evaluateObjectComprehension(
    arena: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(ObjectFieldValue),
    comp: ObjectComprehension,
    clause_index: usize,
    env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!void {
    // Base case: all for clauses have been processed
    if (clause_index >= comp.clauses.len) {
        // Check the filter condition if present
        if (comp.filter) |filter| {
            const filter_value = try evaluateExpression(arena, filter, env, current_dir, ctx);
            const filter_bool = switch (filter_value) {
                .boolean => |b| b,
                else => return error.TypeMismatch,
            };
            if (!filter_bool) return; // Skip this iteration
        }

        // Evaluate key and value
        const key_value = try evaluateExpression(arena, comp.key, env, current_dir, ctx);
        const value_value = try evaluateExpression(arena, comp.value, env, current_dir, ctx);

        // Convert key to string
        const key_string = switch (key_value) {
            .string => |s| try arena.dupe(u8, s),
            .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
            .symbol => |s| try arena.dupe(u8, s),
            else => return error.TypeMismatch,
        };

        try result.append(arena, .{ .key = key_string, .value = value_value });
        return;
    }

    // Process current for clause
    const clause = comp.clauses[clause_index];
    const iterable_value = try evaluateExpression(arena, clause.iterable, env, current_dir, ctx);

    switch (iterable_value) {
        .array => |arr| {
            for (arr.elements) |element| {
                const new_env = try matchPattern(arena, clause.pattern, element, env);
                try evaluateObjectComprehension(arena, result, comp, clause_index + 1, new_env, current_dir, ctx);
            }
        },
        .object => |obj| {
            for (obj.fields) |field| {
                // Create a tuple (key, value) for object iteration
                const tuple_elements = try arena.alloc(Value, 2);
                tuple_elements[0] = .{ .string = try arena.dupe(u8, field.key) };
                // Force the thunk if the value is a thunk
                tuple_elements[1] = try force(arena, field.value);
                const tuple_value = Value{ .tuple = .{ .elements = tuple_elements } };

                const new_env = try matchPattern(arena, clause.pattern, tuple_value, env);
                try evaluateObjectComprehension(arena, result, comp, clause_index + 1, new_env, current_dir, ctx);
            }
        },
        else => return error.TypeMismatch,
    }
}

fn importModule(
    arena: std.mem.Allocator,
    import_path: []const u8,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!Value {
    var module_file = try openImportFile(ctx, import_path, current_dir);
    defer module_file.file.close();
    defer ctx.allocator.free(module_file.path);

    const contents = try module_file.file.readToEndAlloc(arena, std.math.maxInt(usize));

    var parser = try Parser.init(arena, contents);
    const expression = try parser.parse();

    const builtin_env = try createBuiltinEnvironment(arena);
    const module_dir = std.fs.path.dirname(module_file.path);
    return evaluateExpression(arena, expression, builtin_env, module_dir, ctx);
}

pub fn createBuiltinEnvironment(arena: std.mem.Allocator) !?*Environment {
    const builtins = @import("builtins.zig");

    var env: ?*Environment = null;

    // Array builtins
    env = try addBuiltin(arena, env, "__array_length", builtins.arrayLength);
    env = try addBuiltin(arena, env, "__array_get", builtins.arrayGet);
    env = try addBuiltin(arena, env, "__array_reverse", builtins.arrayReverse);
    env = try addBuiltin(arena, env, "__array_fold", builtins.arrayFold);
    env = try addBuiltin(arena, env, "__array_concat_all", builtins.arrayConcatAll);

    // String builtins
    env = try addBuiltin(arena, env, "__string_length", builtins.stringLength);
    env = try addBuiltin(arena, env, "__string_concat", builtins.stringConcat);
    env = try addBuiltin(arena, env, "__string_split", builtins.stringSplit);
    env = try addBuiltin(arena, env, "__string_to_upper", builtins.stringToUpper);
    env = try addBuiltin(arena, env, "__string_to_lower", builtins.stringToLower);
    env = try addBuiltin(arena, env, "__string_chars", builtins.stringChars);
    env = try addBuiltin(arena, env, "__string_trim", builtins.stringTrim);
    env = try addBuiltin(arena, env, "__string_starts_with", builtins.stringStartsWith);
    env = try addBuiltin(arena, env, "__string_ends_with", builtins.stringEndsWith);
    env = try addBuiltin(arena, env, "__string_contains", builtins.stringContains);

    // Math builtins
    env = try addBuiltin(arena, env, "__math_max", builtins.mathMax);
    env = try addBuiltin(arena, env, "__math_min", builtins.mathMin);
    env = try addBuiltin(arena, env, "__math_abs", builtins.mathAbs);
    env = try addBuiltin(arena, env, "__math_pow", builtins.mathPow);
    env = try addBuiltin(arena, env, "__math_sqrt", builtins.mathSqrt);
    env = try addBuiltin(arena, env, "__math_floor", builtins.mathFloor);
    env = try addBuiltin(arena, env, "__math_ceil", builtins.mathCeil);
    env = try addBuiltin(arena, env, "__math_round", builtins.mathRound);
    env = try addBuiltin(arena, env, "__math_log", builtins.mathLog);
    env = try addBuiltin(arena, env, "__math_exp", builtins.mathExp);

    // Object builtins
    env = try addBuiltin(arena, env, "__object_keys", builtins.objectKeys);
    env = try addBuiltin(arena, env, "__object_values", builtins.objectValues);
    env = try addBuiltin(arena, env, "__object_get", builtins.objectGet);

    // Error handling builtins
    env = try addBuiltin(arena, env, "crash", builtins.crash);

    return env;
}

fn addBuiltin(arena: std.mem.Allocator, parent: ?*Environment, name: []const u8, function: NativeFn) !?*Environment {
    const new_env = try arena.create(Environment);
    new_env.* = .{
        .parent = parent,
        .name = name,
        .value = Value{ .native_fn = function },
    };
    return new_env;
}

fn lookup(env: ?*Environment, name: []const u8) ?Value {
    var current = env;
    while (current) |scope| {
        if (std.mem.eql(u8, scope.name, name)) {
            return scope.value;
        }
        current = scope.parent;
    }
    return null;
}

fn valueToString(allocator: std.mem.Allocator, value: Value) ![]u8 {
    return switch (value) {
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .boolean => |v| try std.fmt.allocPrint(allocator, "{s}", .{if (v) "true" else "false"}),
        .null_value => try std.fmt.allocPrint(allocator, "null", .{}),
        .symbol => |s| try allocator.dupe(u8, s),
        .string => |str| try allocator.dupe(u8, str),
        else => try formatValue(allocator, value),
    };
}

pub fn formatValue(allocator: std.mem.Allocator, value: Value) ![]u8 {
    return formatValueWithArena(allocator, allocator, value);
}

fn formatValueWithArena(allocator: std.mem.Allocator, arena: std.mem.Allocator, value: Value) error{OutOfMemory}![]u8 {
    return switch (value) {
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .boolean => |v| try std.fmt.allocPrint(allocator, "{s}", .{if (v) "true" else "false"}),
        .null_value => try std.fmt.allocPrint(allocator, "null", .{}),
        .symbol => |s| try std.fmt.allocPrint(allocator, "{s}", .{s}),
        .function => try std.fmt.allocPrint(allocator, "<function>", .{}),
        .native_fn => try std.fmt.allocPrint(allocator, "<native function>", .{}),
        .thunk => blk: {
            // Force the thunk and format the result
            const forced = force(arena, value) catch break :blk try std.fmt.allocPrint(allocator, "<thunk error>", .{});
            break :blk try formatValueWithArena(allocator, arena, forced);
        },
        .array => |arr| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '[');
            for (arr.elements, 0..) |element, i| {
                if (i != 0) try builder.appendSlice(allocator, ", ");
                const formatted = try formatValueWithArena(allocator, arena, element);
                defer allocator.free(formatted);
                try builder.appendSlice(allocator, formatted);
            }
            try builder.append(allocator, ']');

            break :blk try builder.toOwnedSlice(allocator);
        },
        .tuple => |tup| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '(');
            for (tup.elements, 0..) |element, i| {
                if (i != 0) try builder.appendSlice(allocator, ", ");
                const formatted = try formatValueWithArena(allocator, arena, element);
                defer allocator.free(formatted);
                try builder.appendSlice(allocator, formatted);
            }
            try builder.append(allocator, ')');

            break :blk try builder.toOwnedSlice(allocator);
        },
        .object => |obj| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            if (obj.fields.len == 0) {
                try builder.appendSlice(allocator, "{}");
            } else {
                try builder.appendSlice(allocator, "{ ");
                for (obj.fields, 0..) |field, i| {
                    if (i != 0) try builder.appendSlice(allocator, ", ");
                    try builder.appendSlice(allocator, field.key);
                    try builder.appendSlice(allocator, ": ");
                    const formatted = try formatValueWithArena(allocator, arena, field.value);
                    defer allocator.free(formatted);
                    try builder.appendSlice(allocator, formatted);
                }
                try builder.appendSlice(allocator, " }");
            }

            break :blk try builder.toOwnedSlice(allocator);
        },
        .string => |str| try std.fmt.allocPrint(allocator, "\"{s}\"", .{str}),
    };
}

pub const EvalOutput = struct {
    allocator: std.mem.Allocator,
    text: []u8,

    pub fn deinit(self: *EvalOutput) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }
};

/// Extended eval output that includes error context
pub const EvalResult = struct {
    output: ?EvalOutput,
    error_ctx: error_context.ErrorContext,

    pub fn deinit(self: *EvalResult) void {
        if (self.output) |*out| {
            out.deinit();
        }
        self.error_ctx.deinit();
    }
};

fn evalSourceWithContext(
    allocator: std.mem.Allocator,
    source: []const u8,
    current_dir: ?[]const u8,
) EvalError!EvalResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const lazy_paths = try collectLazyPaths(arena.allocator());
    var err_ctx = error_context.ErrorContext.init(allocator);
    err_ctx.setSource(source);

    const context = EvalContext{
        .allocator = allocator,
        .lazy_paths = lazy_paths,
        .error_ctx = &err_ctx,
    };

    var parser = try Parser.init(arena.allocator(), source);
    parser.setErrorContext(&err_ctx);
    const expression = parser.parse() catch {
        arena.deinit();
        return EvalResult{
            .output = null,
            .error_ctx = err_ctx,
        };
    };

    const builtin_env = try createBuiltinEnvironment(arena.allocator());
    const value = evaluateExpression(arena.allocator(), expression, builtin_env, current_dir, &context) catch {
        arena.deinit();
        return EvalResult{
            .output = null,
            .error_ctx = err_ctx,
        };
    };
    const formatted = try formatValueWithArena(allocator, arena.allocator(), value);

    arena.deinit();
    return EvalResult{
        .output = .{
            .allocator = allocator,
            .text = formatted,
        },
        .error_ctx = err_ctx,
    };
}

fn evalSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    current_dir: ?[]const u8,
) EvalError!EvalOutput {
    var result = try evalSourceWithContext(allocator, source, current_dir);
    defer result.error_ctx.deinit();

    if (result.output) |output| {
        return output;
    } else {
        // This shouldn't happen since we catch errors in evalSourceWithContext
        return error.UnknownIdentifier;
    }
}

pub fn evalInline(allocator: std.mem.Allocator, source: []const u8) EvalError!EvalOutput {
    return try evalSource(allocator, source, null);
}

pub fn evalInlineWithContext(allocator: std.mem.Allocator, source: []const u8) EvalError!EvalResult {
    return try evalSourceWithContext(allocator, source, null);
}

pub fn evalFileWithContext(allocator: std.mem.Allocator, path: []const u8) EvalError!EvalResult {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    const directory = std.fs.path.dirname(path);
    return try evalSourceWithContext(allocator, contents, directory);
}

pub fn evalFile(allocator: std.mem.Allocator, path: []const u8) EvalError!EvalOutput {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    const directory = std.fs.path.dirname(path);
    return try evalSource(allocator, contents, directory);
}

pub fn evalFileValue(
    arena: std.mem.Allocator,
    allocator: std.mem.Allocator,
    path: []const u8,
) EvalError!Value {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    const lazy_paths = try collectLazyPaths(arena);
    const context = EvalContext{ .allocator = allocator, .lazy_paths = lazy_paths };

    var parser = try Parser.init(arena, contents);
    const expression = try parser.parse();

    const builtin_env = try createBuiltinEnvironment(arena);
    const directory = std.fs.path.dirname(path);
    return try evaluateExpression(arena, expression, builtin_env, directory, &context);
}
