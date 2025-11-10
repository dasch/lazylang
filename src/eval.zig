const std = @import("std");

const TokenKind = enum {
    eof,
    identifier,
    number,
    string,
    comma,
    colon,
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
    unary: Unary,
    binary: Binary,
    application: Application,
    if_expr: If,
    array: ArrayLiteral,
    tuple: TupleLiteral,
    object: ObjectLiteral,
    import_expr: ImportExpr,
};

const Lambda = struct {
    param: []const u8,
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
        if (self.current.kind == .identifier and self.lookahead.kind == .arrow) {
            const param = self.current.lexeme;
            try self.advance();
            try self.expect(.arrow);
            const body = try self.parseLambda();
            const node = try self.allocateExpression();
            node.* = .{ .lambda = .{ .param = param, .body = body } };
            return node;
        }
        return self.parseBinary(0);
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
                        std.mem.eql(u8, self.current.lexeme, "else")) {
                        break;
                    }
                    const argument = try self.parsePrimary();
                    const node = try self.allocateExpression();
                    node.* = .{ .application = .{ .function = expr, .argument = argument } };
                    expr = node;
                },
                .number, .l_paren => {
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
    param: []const u8,
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
        .application => |application| blk: {
            const function_value = try evaluateExpression(arena, application.function, env, current_dir, ctx);
            const argument_value = try evaluateExpression(arena, application.argument, env, current_dir, ctx);

            const function_ptr = switch (function_value) {
                .function => |fn_ptr| fn_ptr,
                else => return error.ExpectedFunction,
            };

            const bound_env = try arena.create(Environment);
            bound_env.* = .{
                .parent = function_ptr.env,
                .name = function_ptr.param,
                .value = argument_value,
            };

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
