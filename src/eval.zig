const std = @import("std");

const TokenKind = enum {
    eof,
    identifier,
    number,
    comma,
    colon,
    arrow,
    plus,
    minus,
    star,
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
    array: ArrayLiteral,
    object: ObjectLiteral,
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

const ArrayLiteral = struct {
    elements: []*Expression,
};

const ObjectField = struct {
    key: []const u8,
    value: *Expression,
};

const ObjectLiteral = struct {
    fields: []ObjectField,
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
            if (self.current.preceded_by_newline) break;
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
    array: ArrayValue,
    object: ObjectValue,
};

const ArrayValue = struct {
    elements: []Value,
};

const ObjectFieldValue = struct {
    key: []const u8,
    value: Value,
};

const ObjectValue = struct {
    fields: []ObjectFieldValue,
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
        .array => |array| blk: {
            const values = try arena.alloc(Value, array.elements.len);
            for (array.elements, 0..) |element, i| {
                values[i] = try evaluateExpression(arena, element, env);
            }
            break :blk Value{ .array = .{ .elements = values } };
        },
        .object => |object| blk: {
            const fields = try arena.alloc(ObjectFieldValue, object.fields.len);
            for (object.fields, 0..) |field, i| {
                fields[i] = .{ .key = field.key, .value = try evaluateExpression(arena, field.value, env) };
            }
            break :blk Value{ .object = .{ .fields = fields } };
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
        .array => |arr| blk: {
            var builder = std.ArrayList(u8).init(allocator);
            errdefer builder.deinit();

            try builder.append('[');
            for (arr.elements, 0..) |element, i| {
                if (i != 0) try builder.appendSlice(", ");
                const formatted = try formatValue(allocator, element);
                defer allocator.free(formatted);
                try builder.appendSlice(formatted);
            }
            try builder.append(']');

            break :blk try builder.toOwnedSlice();
        },
        .object => |obj| blk: {
            var builder = std.ArrayList(u8).init(allocator);
            errdefer builder.deinit();

            try builder.append('{');
            for (obj.fields, 0..) |field, i| {
                if (i != 0) try builder.appendSlice(", ");
                try builder.appendSlice(field.key);
                try builder.appendSlice(": ");
                const formatted = try formatValue(allocator, field.value);
                defer allocator.free(formatted);
                try builder.appendSlice(formatted);
            }
            try builder.append('}');

            break :blk try builder.toOwnedSlice();
        },
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
