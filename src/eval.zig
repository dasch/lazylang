const std = @import("std");

const TokenKind = enum {
    eof,
    identifier,
    number,
    arrow,
    plus,
    minus,
    star,
    l_paren,
    r_paren,
};

const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
};

const TokenizerError = error{
    UnexpectedCharacter,
};

const ParseError = TokenizerError || std.mem.Allocator.Error || std.fmt.ParseIntError || error{
    ExpectedExpression,
    UnexpectedToken,
};

const BinaryOp = enum {
    add,
    subtract,
    multiply,
};

const Expression = union(enum) {
    integer: i64,
    identifier: []const u8,
    lambda: Lambda,
    binary: Binary,
    application: Application,
};

const Lambda = struct {
    param: []const u8,
    body: *Expression,
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

const Tokenizer = struct {
    source: []const u8,
    index: usize,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source, .index = 0 };
    }

    fn next(self: *Tokenizer) TokenizerError!Token {
        self.skipWhitespace();

        if (self.index >= self.source.len) {
            return .{ .kind = .eof, .lexeme = self.source[self.source.len..self.source.len] };
        }

        const start = self.index;
        const char = self.source[self.index];

        switch (char) {
            '+' => {
                self.index += 1;
                return .{ .kind = .plus, .lexeme = self.source[start..self.index] };
            },
            '-' => {
                self.index += 1;
                if (self.index < self.source.len and self.source[self.index] == '>') {
                    self.index += 1;
                    return .{ .kind = .arrow, .lexeme = self.source[start..self.index] };
                }
                return .{ .kind = .minus, .lexeme = self.source[start..self.index] };
            },
            '*' => {
                self.index += 1;
                return .{ .kind = .star, .lexeme = self.source[start..self.index] };
            },
            '(' => {
                self.index += 1;
                return .{ .kind = .l_paren, .lexeme = self.source[start..self.index] };
            },
            ')' => {
                self.index += 1;
                return .{ .kind = .r_paren, .lexeme = self.source[start..self.index] };
            },
            'a'...'z', 'A'...'Z', '_' => {
                return self.consumeIdentifier();
            },
            '0'...'9' => {
                return self.consumeNumber();
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
        return .{ .kind = .identifier, .lexeme = self.source[start..self.index] };
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
        return .{ .kind = .number, .lexeme = self.source[start..self.index] };
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.index < self.source.len) : (self.index += 1) {
            const c = self.source[self.index];
            switch (c) {
                ' ', '\t', '\n', '\r' => continue,
                else => return,
            }
        }
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
        var left = try self.parseApplication();

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
                    else => unreachable,
                },
                .left = left,
                .right = right,
            } };
            left = node;
        }

        return left;
    }

    fn parseApplication(self: *Parser) ParseError!*Expression {
        var expr = try self.parsePrimary();

        while (true) {
            switch (self.current.kind) {
                .identifier, .number, .l_paren => {
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
                const name = self.current.lexeme;
                try self.advance();
                const node = try self.allocateExpression();
                node.* = .{ .identifier = name };
                return node;
            },
            .l_paren => {
                try self.advance();
                const inner = try self.parseLambda();
                try self.expect(.r_paren);
                return inner;
            },
            else => return error.ExpectedExpression,
        }
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
        .plus, .minus => 1,
        .star => 2,
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
    function: *FunctionValue,
};

fn evaluateExpression(arena: std.mem.Allocator, expr: *Expression, env: ?*Environment) !Value {
    return switch (expr.*) {
        .integer => |value| .{ .integer = value },
        .identifier => |name| blk: {
            const resolved = lookup(env, name) orelse return error.UnknownIdentifier;
            break :blk resolved;
        },
        .lambda => |lambda| blk: {
            const function = try arena.create(FunctionValue);
            function.* = .{ .param = lambda.param, .body = lambda.body, .env = env };
            break :blk Value{ .function = function };
        },
        .binary => |binary| blk: {
            const left_value = try evaluateExpression(arena, binary.left, env);
            const right_value = try evaluateExpression(arena, binary.right, env);
            const left_int = switch (left_value) {
                .integer => |v| v,
                else => return error.TypeMismatch,
            };
            const right_int = switch (right_value) {
                .integer => |v| v,
                else => return error.TypeMismatch,
            };

            const result = switch (binary.op) {
                .add => try std.math.add(i64, left_int, right_int),
                .subtract => try std.math.sub(i64, left_int, right_int),
                .multiply => try std.math.mul(i64, left_int, right_int),
            };
            break :blk Value{ .integer = result };
        },
        .application => |application| blk: {
            const function_value = try evaluateExpression(arena, application.function, env);
            const argument_value = try evaluateExpression(arena, application.argument, env);

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

            break :blk try evaluateExpression(arena, function_ptr.body, bound_env);
        },
    };
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
        .function => try std.fmt.allocPrint(allocator, "<function>", .{}),
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

pub fn evalInline(allocator: std.mem.Allocator, source: []const u8) !EvalOutput {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = try Parser.init(arena.allocator(), source);
    const expression = try parser.parse();

    const value = try evaluateExpression(arena.allocator(), expression, null);
    const formatted = try formatValue(allocator, value);

    return .{
        .allocator = allocator,
        .text = formatted,
    };
}

pub fn evalFile(allocator: std.mem.Allocator, path: []const u8) !EvalOutput {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    return try evalInline(allocator, contents);
}
