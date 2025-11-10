const std = @import("std");

const TokenKind = enum {
    eof,
    identifier,
    number,
    string,
    comma,
    colon,
    semicolon,
    equals,
    arrow,
    plus,
    minus,
    star,
    ampersand_ampersand,
    pipe_pipe,
    bang,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
};

const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    preceded_by_newline: bool,
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
};

const UnaryOp = enum {
    logical_not,
};

const Expression = union(enum) {
    integer: i64,
    boolean: bool,
    null_literal,
    identifier: []const u8,
    string_literal: []const u8,
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
    import_expr: ImportExpr,
};

const Lambda = struct {
    param: *Pattern,
    body: *Expression,
};

const Let = struct {
    pattern: *Pattern,
    value: *Expression,
    body: *Expression,
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

const ArrayLiteral = struct {
    elements: []*Expression,
};

const TupleLiteral = struct {
    elements: []*Expression,
};

const ObjectField = struct {
    key: []const u8,
    value: *Expression,
};

const ObjectLiteral = struct {
    fields: []ObjectField,
};

const ImportExpr = struct {
    path: []const u8,
};

const Pattern = union(enum) {
    identifier: []const u8,
    integer: i64,
    boolean: bool,
    null_literal,
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
};

const ObjectPattern = struct {
    fields: []ObjectPatternField,
};

const ObjectPatternField = struct {
    key: []const u8,
    pattern: *Pattern, // Either identifier for extraction or literal for matching
};

const Tokenizer = struct {
    source: []const u8,
    index: usize,
    last_whitespace_had_newline: bool,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source, .index = 0, .last_whitespace_had_newline = false };
    }

    fn next(self: *Tokenizer) TokenizerError!Token {
        const saw_newline = self.skipWhitespace();
        self.last_whitespace_had_newline = saw_newline;

        if (self.index >= self.source.len) {
            return .{
                .kind = .eof,
                .lexeme = self.source[self.source.len..self.source.len],
                .preceded_by_newline = saw_newline,
            };
        }

        const start = self.index;
        const char = self.source[self.index];

        switch (char) {
            '+' => {
                self.index += 1;
                return self.makeToken(.plus, start);
            },
            '-' => {
                self.index += 1;
                if (self.index < self.source.len and self.source[self.index] == '>') {
                    self.index += 1;
                    return self.makeToken(.arrow, start);
                }
                return self.makeToken(.minus, start);
            },
            '*' => {
                self.index += 1;
                return self.makeToken(.star, start);
            },
            '&' => {
                self.index += 1;
                if (self.index < self.source.len and self.source[self.index] == '&') {
                    self.index += 1;
                    return self.makeToken(.ampersand_ampersand, start);
                }
                return error.UnexpectedCharacter;
            },
            '|' => {
                self.index += 1;
                if (self.index < self.source.len and self.source[self.index] == '|') {
                    self.index += 1;
                    return self.makeToken(.pipe_pipe, start);
                }
                return error.UnexpectedCharacter;
            },
            '!' => {
                self.index += 1;
                return self.makeToken(.bang, start);
            },
            ',' => {
                self.index += 1;
                return self.makeToken(.comma, start);
            },
            ':' => {
                self.index += 1;
                return self.makeToken(.colon, start);
            },
            ';' => {
                self.index += 1;
                return self.makeToken(.semicolon, start);
            },
            '=' => {
                self.index += 1;
                return self.makeToken(.equals, start);
            },
            '(' => {
                self.index += 1;
                return self.makeToken(.l_paren, start);
            },
            ')' => {
                self.index += 1;
                return self.makeToken(.r_paren, start);
            },
            '[' => {
                self.index += 1;
                return self.makeToken(.l_bracket, start);
            },
            ']' => {
                self.index += 1;
                return self.makeToken(.r_bracket, start);
            },
            '{' => {
                self.index += 1;
                return self.makeToken(.l_brace, start);
            },
            '}' => {
                self.index += 1;
                return self.makeToken(.r_brace, start);
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
            else => return error.UnexpectedCharacter,
        }
    }

    fn consumeIdentifier(self: *Tokenizer) Token {
        const start = self.index;
        while (self.index < self.source.len) : (self.index += 1) {
            const c = self.source[self.index];
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => continue,
                else => break,
            }
        }
        return self.makeToken(.identifier, start);
    }

    fn consumeNumber(self: *Tokenizer) Token {
        const start = self.index;
        while (self.index < self.source.len) : (self.index += 1) {
            const c = self.source[self.index];
            switch (c) {
                '0'...'9' => continue,
                else => break,
            }
        }
        return self.makeToken(.number, start);
    }

    fn consumeString(self: *Tokenizer, quote_char: u8) TokenizerError!Token {
        self.index += 1; // skip opening quote
        const start_content = self.index;
        while (self.index < self.source.len) : (self.index += 1) {
            if (self.source[self.index] == quote_char) {
                const token = Token{
                    .kind = .string,
                    .lexeme = self.source[start_content..self.index],
                    .preceded_by_newline = self.last_whitespace_had_newline,
                };
                self.index += 1; // skip closing quote
                return token;
            }
        }
        return error.UnterminatedString;
    }

    fn skipWhitespace(self: *Tokenizer) bool {
        var saw_newline = false;
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            switch (c) {
                ' ', '\t' => {
                    self.index += 1;
                },
                '\r' => {
                    saw_newline = true;
                    self.index += 1;
                    if (self.index < self.source.len and self.source[self.index] == '\n') {
                        self.index += 1;
                    }
                },
                '\n' => {
                    saw_newline = true;
                    self.index += 1;
                },
                else => return saw_newline,
            }
        }
        return saw_newline;
    }

    fn makeToken(self: *Tokenizer, kind: TokenKind, start: usize) Token {
        return .{
            .kind = kind,
            .lexeme = self.source[start..self.index],
            .preceded_by_newline = self.last_whitespace_had_newline,
        };
    }
};

const Parser = struct {
    arena: std.mem.Allocator,
    tokenizer: Tokenizer,
    current: Token,
    lookahead: Token,

    fn init(arena: std.mem.Allocator, source: []const u8) ParseError!Parser {
        var tokenizer = Tokenizer.init(source);
        const first = try tokenizer.next();
        const second = try tokenizer.next();
        return .{
            .arena = arena,
            .tokenizer = tokenizer,
            .current = first,
            .lookahead = second,
        };
    }

    fn parse(self: *Parser) ParseError!*Expression {
        if (self.current.kind == .eof) return error.ExpectedExpression;
        const expr = try self.parseLambda();
        if (self.current.kind != .eof) return error.UnexpectedToken;
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
            node.* = .{ .let = .{ .pattern = pattern, .value = value, .body = body } };
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

        return self.parseBinary(0);
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
            const right = try self.parseBinary(precedence + 1);

            const node = try self.allocateExpression();
            node.* = .{ .binary = .{
                .op = switch (op_token.kind) {
                    .plus => .add,
                    .minus => .subtract,
                    .star => .multiply,
                    .ampersand_ampersand => .logical_and,
                    .pipe_pipe => .logical_or,
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
                    // Don't consume keywords as function arguments
                    if (std.mem.eql(u8, self.current.lexeme, "then") or
                        std.mem.eql(u8, self.current.lexeme, "else") or
                        std.mem.eql(u8, self.current.lexeme, "matches") or
                        std.mem.eql(u8, self.current.lexeme, "otherwise")) {
                        break;
                    }
                    const argument = try self.parsePrimary();
                    const node = try self.allocateExpression();
                    node.* = .{ .application = .{ .function = expr, .argument = argument } };
                    expr = node;
                },
                .number, .l_paren, .l_bracket, .l_brace => {
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
                const node = try self.allocateExpression();
                node.* = .{ .string_literal = value };
                return node;
            },
            .l_paren => return self.parseTupleOrParenthesized(),
            .l_bracket => return self.parseArray(),
            .l_brace => return self.parseObject(),
            else => return error.ExpectedExpression,
        }
    }

    fn parseArray(self: *Parser) ParseError!*Expression {
        try self.expect(.l_bracket);

        var elements = std.ArrayListUnmanaged(*Expression){};

        while (self.current.kind != .r_bracket) {
            const element = try self.parseLambda();
            try elements.append(self.arena, element);

            if (self.current.kind == .comma) {
                try self.advance();
                if (self.current.kind == .r_bracket) break;
                continue;
            }

            if (self.current.kind == .r_bracket) break;

            if (self.current.preceded_by_newline) {
                continue;
            }

            return error.UnexpectedToken;
        }

        try self.expect(.r_bracket);

        const slice = try elements.toOwnedSlice(self.arena);
        const node = try self.allocateExpression();
        node.* = .{ .array = .{ .elements = slice } };
        return node;
    }

    fn parseObject(self: *Parser) ParseError!*Expression {
        try self.expect(.l_brace);

        var fields = std.ArrayListUnmanaged(ObjectField){};

        while (self.current.kind != .r_brace) {
            if (self.current.kind != .identifier) return error.UnexpectedToken;
            const key = self.current.lexeme;
            try self.advance();

            try self.expect(.colon);
            const value_expr = try self.parseLambda();
            try fields.append(self.arena, .{ .key = key, .value = value_expr });

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

        while (self.current.kind != .r_bracket) {
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
        pattern.* = .{ .array = .{ .elements = slice } };
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
        if (self.current.kind != kind) return error.UnexpectedToken;
        try self.advance();
    }

    fn advance(self: *Parser) ParseError!void {
        self.current = self.lookahead;
        self.lookahead = try self.tokenizer.next();
    }

    fn allocateExpression(self: *Parser) ParseError!*Expression {
        return try self.arena.create(Expression);
    }
};

fn getPrecedence(kind: TokenKind) ?u32 {
    return switch (kind) {
        .pipe_pipe => 3,
        .ampersand_ampersand => 4,
        .plus, .minus => 5,
        .star => 6,
        else => null,
    };
}

const Environment = struct {
    parent: ?*Environment,
    name: []const u8,
    value: Value,
};

const FunctionValue = struct {
    param: *Pattern,
    body: *Expression,
    env: ?*Environment,
};

const Value = union(enum) {
    integer: i64,
    boolean: bool,
    null_value,
    function: *FunctionValue,
    array: ArrayValue,
    tuple: TupleValue,
    object: ObjectValue,
    string: []const u8,
};

const ArrayValue = struct {
    elements: []Value,
};

const TupleValue = struct {
    elements: []Value,
};

const ObjectFieldValue = struct {
    key: []const u8,
    value: Value,
};

const ObjectValue = struct {
    fields: []ObjectFieldValue,
};

const EvalError = ParseError || std.mem.Allocator.Error || std.process.GetEnvVarOwnedError || std.fs.File.OpenError || std.fs.File.ReadError || error{
    UnknownIdentifier,
    TypeMismatch,
    ExpectedFunction,
    ModuleNotFound,
    Overflow,
    FileTooBig,
};

const EvalContext = struct {
    allocator: std.mem.Allocator,
    lazy_paths: [][]const u8,
};

const ModuleFile = struct {
    path: []u8,
    file: std.fs.File,
};

fn collectLazyPaths(arena: std.mem.Allocator) EvalError![][]const u8 {
    var list = std.ArrayList([]const u8){};
    defer list.deinit(arena);

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

fn matchPattern(
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

            if (array_pattern.elements.len != array_value.elements.len) {
                return error.TypeMismatch;
            }

            var current_env = base_env;
            for (array_pattern.elements, 0..) |elem_pattern, i| {
                current_env = try matchPattern(arena, elem_pattern, array_value.elements[i], current_env);
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
                        // Match the field's pattern against the field's value
                        current_env = try matchPattern(arena, pattern_field.pattern, value_field.value, current_env);
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

fn evaluateExpression(
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
        .identifier => |name| blk: {
            const resolved = lookup(env, name) orelse return error.UnknownIdentifier;
            break :blk resolved;
        },
        .string_literal => |value| .{ .string = value },
        .lambda => |lambda| blk: {
            const function = try arena.create(FunctionValue);
            function.* = .{ .param = lambda.param, .body = lambda.body, .env = env };
            break :blk Value{ .function = function };
        },
        .let => |let_expr| blk: {
            const value = try evaluateExpression(arena, let_expr.value, env, current_dir, ctx);
            const new_env = try matchPattern(arena, let_expr.pattern, value, env);
            break :blk try evaluateExpression(arena, let_expr.body, new_env, current_dir, ctx);
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

            const function_ptr = switch (function_value) {
                .function => |fn_ptr| fn_ptr,
                else => return error.ExpectedFunction,
            };

            const bound_env = try matchPattern(arena, function_ptr.param, argument_value, function_ptr.env);

            break :blk try evaluateExpression(arena, function_ptr.body, bound_env, current_dir, ctx);
        },
        .array => |array| blk: {
            const values = try arena.alloc(Value, array.elements.len);
            for (array.elements, 0..) |element, i| {
                values[i] = try evaluateExpression(arena, element, env, current_dir, ctx);
            }
            break :blk Value{ .array = .{ .elements = values } };
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
                fields[i] = .{ .key = field.key, .value = try evaluateExpression(arena, field.value, env, current_dir, ctx) };
            }
            break :blk Value{ .object = .{ .fields = fields } };
        },
        .import_expr => |import_expr| try importModule(arena, import_expr.path, current_dir, ctx),
    };
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

    const module_dir = std.fs.path.dirname(module_file.path);
    return evaluateExpression(arena, expression, null, module_dir, ctx);
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

fn formatValue(allocator: std.mem.Allocator, value: Value) ![]u8 {
    return switch (value) {
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .boolean => |v| try std.fmt.allocPrint(allocator, "{s}", .{if (v) "true" else "false"}),
        .null_value => try std.fmt.allocPrint(allocator, "null", .{}),
        .function => try std.fmt.allocPrint(allocator, "<function>", .{}),
        .array => |arr| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '[');
            for (arr.elements, 0..) |element, i| {
                if (i != 0) try builder.appendSlice(allocator, ", ");
                const formatted = try formatValue(allocator, element);
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
                const formatted = try formatValue(allocator, element);
                defer allocator.free(formatted);
                try builder.appendSlice(allocator, formatted);
            }
            try builder.append(allocator, ')');

            break :blk try builder.toOwnedSlice(allocator);
        },
        .object => |obj| blk: {
            var builder = std.ArrayList(u8){};
            errdefer builder.deinit(allocator);

            try builder.append(allocator, '{');
            for (obj.fields, 0..) |field, i| {
                if (i != 0) try builder.appendSlice(allocator, ", ");
                try builder.appendSlice(allocator, field.key);
                try builder.appendSlice(allocator, ": ");
                const formatted = try formatValue(allocator, field.value);
                defer allocator.free(formatted);
                try builder.appendSlice(allocator, formatted);
            }
            try builder.append(allocator, '}');

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

fn evalSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    current_dir: ?[]const u8,
) EvalError!EvalOutput {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const lazy_paths = try collectLazyPaths(arena.allocator());
    const context = EvalContext{ .allocator = allocator, .lazy_paths = lazy_paths };

    var parser = try Parser.init(arena.allocator(), source);
    const expression = try parser.parse();

    const value = try evaluateExpression(arena.allocator(), expression, null, current_dir, &context);
    const formatted = try formatValue(allocator, value);

    return .{
        .allocator = allocator,
        .text = formatted,
    };
}

pub fn evalInline(allocator: std.mem.Allocator, source: []const u8) EvalError!EvalOutput {
    return try evalSource(allocator, source, null);
}

pub fn evalFile(allocator: std.mem.Allocator, path: []const u8) EvalError!EvalOutput {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    const directory = std.fs.path.dirname(path);
    return try evalSource(allocator, contents, directory);
}
