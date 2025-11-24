//! Recursive descent parser for Lazylang.
//!
//! This module implements a recursive descent parser with operator precedence
//! climbing. It converts a stream of tokens from the tokenizer into an Abstract
//! Syntax Tree (AST) suitable for evaluation.
//!
//! Key features:
//! - Two-token lookahead for disambiguation
//! - Operator precedence climbing for binary expressions  
//! - Pattern parsing for destructuring (tuples, arrays, objects)
//! - String interpolation with nested expressions
//! - Array and object comprehensions
//! - Documentation comment preservation
//!
//! The parser maintains error context for helpful error messages, tracking:
//! - Source locations (line, column, offset)
//! - Current token information
//! - Expected vs actual tokens

const std = @import("std");
const ast = @import("ast.zig");
const tokenizer_mod = @import("tokenizer.zig");
const error_context = @import("error_context.zig");

// Import types for convenience
const Token = ast.Token;
const TokenKind = ast.TokenKind;
const Expression = ast.Expression;
const ExpressionData = ast.ExpressionData;
const Pattern = ast.Pattern;
const PatternData = ast.PatternData;
const BinaryOp = ast.BinaryOp;
const UnaryOp = ast.UnaryOp;
const WhereBinding = ast.WhereBinding;
const MatchBranch = ast.MatchBranch;
const ArrayElement = ast.ArrayElement;
const ForClause = ast.ForClause;
const ObjectField = ast.ObjectField;
const ObjectPatternField = ast.ObjectPatternField;
const StringPart = ast.StringPart;
const Tokenizer = tokenizer_mod.Tokenizer;
const TokenizerError = tokenizer_mod.TokenizerError;

pub const ParseError = TokenizerError || std.mem.Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError || error{
    ExpectedExpression,
    UnexpectedToken,
};

pub const Parser = struct {
    arena: std.mem.Allocator,
    tokenizer: Tokenizer,
    current: Token,
    lookahead: Token,
    source: []const u8,
    error_ctx: ?*error_context.ErrorContext,

    pub fn init(arena: std.mem.Allocator, source: []const u8) ParseError!Parser {
        return initWithContext(arena, source, null);
    }

    pub fn initWithContext(arena: std.mem.Allocator, source: []const u8, err_ctx: ?*error_context.ErrorContext) ParseError!Parser {
        var tokenizer = Tokenizer.init(source, arena);
        tokenizer.error_ctx = err_ctx;

        const first = tokenizer.next() catch |err| {
            // Error context already set by tokenizer if available
            return err;
        };

        const second = tokenizer.next() catch |err| {
            // Error context already set by tokenizer if available
            return err;
        };

        return .{
            .arena = arena,
            .tokenizer = tokenizer,
            .current = first,
            .lookahead = second,
            .source = source,
            .error_ctx = err_ctx,
        };
    }

    pub fn setErrorContext(self: *Parser, ctx: *error_context.ErrorContext) void {
        self.error_ctx = ctx;
        self.tokenizer.error_ctx = ctx;
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

    fn friendlyTokenName(kind: TokenKind) []const u8 {
        return switch (kind) {
            .l_paren => "'('",
            .r_paren => "')'",
            .l_bracket => "'['",
            .r_bracket => "']'",
            .l_brace => "'{'",
            .r_brace => "'}'",
            .comma => "','",
            .colon => "':'",
            .semicolon => "';'",
            .equals => "'='",
            .arrow => "'->'",
            .dot => "'.'",
            .dot_dot => "'..'",
            .plus => "'+'",
            .minus => "'-'",
            .star => "'*'",
            .slash => "'/'",
            .ampersand => "'&'",
            .bang => "'!'",
            .less => "'<'",
            .greater => "'>'",
            .less_equals => "'<='",
            .greater_equals => "'>='",
            .equals_equals => "'=='",
            .bang_equals => "'!='",
            .ampersand_ampersand => "'&&'",
            .pipe_pipe => "'||'",
            .backslash => "'\\'",
            .dot_dot_dot => "'...'",
            .identifier => "identifier",
            .number => "number",
            .symbol => "symbol",
            .string => "string",
            .eof => "end of file",
        };
    }

    fn expectToken(self: *Parser, expected: TokenKind, context: []const u8) ParseError!void {
        if (self.current.kind != expected) {
            self.recordError();
            if (self.error_ctx) |ctx| {
                const expected_name = friendlyTokenName(expected);
                const owned_expected = ctx.allocator.dupe(u8, expected_name) catch expected_name;
                const owned_context = ctx.allocator.dupe(u8, context) catch context;
                ctx.setErrorData(.{
                    .unexpected_token = .{
                        .expected = owned_expected,
                        .context = owned_context,
                    },
                });
            }
            return error.UnexpectedToken;
        }
        try self.advance();
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
            const start_token = self.current; // Capture start for location
            const doc = start_token.doc_comments; // Doc comments are already on the token
            const pattern = try self.parsePattern();
            try self.expectToken(.equals, "in let binding");
            const value = try self.parseLambda();

            // Check for semicolon or newline separator
            if (self.current.kind == .semicolon) {
                try self.advance();
            } else if (!self.current.preceded_by_newline and self.current.kind != .eof) {
                self.recordError();
                return error.UnexpectedToken;
            }

            // If we're at EOF or closing delimiter, return just the value
            if (self.current.kind == .eof or self.current.kind == .r_paren) {
                return value;
            }

            const body = try self.parseLambda();
            return try self.makeExpression(.{ .let = .{ .pattern = pattern, .value = value, .body = body, .doc = doc } }, start_token);
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
            const start_token = self.current; // Capture start for location
            const param = try self.parsePattern();
            try self.expect(.arrow);
            const body = try self.parseLambda();
            return try self.makeExpression(.{ .lambda = .{ .param = param, .body = body } }, start_token);
        }

        var expr = try self.parseBinary(0);

        // Check for 'where' clause
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "where")) {
            const where_token = self.current; // Capture for location
            try self.advance();

            // Parse bindings: collect them into a list
            var bindings = std.ArrayListUnmanaged(WhereBinding){};

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

                const doc = self.current.doc_comments;
                const pattern = try self.parsePattern();
                try self.expectToken(.equals, "in where binding");
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

            // Create a WhereExpr with all bindings
            const binding_slice = try bindings.toOwnedSlice(self.arena);
            const where_node = try self.allocateExpression();
            where_node.* = .{
                .data = .{ .where_expr = .{ .expr = expr, .bindings = binding_slice } },
                .location = .{
                    .line = where_token.line,
                    .column = where_token.column,
                    .offset = where_token.offset,
                    .length = where_token.lexeme.len,
                },
            };
            expr = where_node;
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
                    const lambda_start = self.current; // Capture start for lambda location
                    const param = try self.parsePattern();
                    try self.expect(.arrow);
                    const body = try self.parseLambda();
                    const lambda_node = try self.allocateExpression();
                    lambda_node.* = .{
                        .data = .{ .lambda = .{ .param = param, .body = body } },
                        .location = .{
                            .line = lambda_start.line,
                            .column = lambda_start.column,
                            .offset = lambda_start.offset,
                            .length = lambda_start.lexeme.len,
                        },
                    };
                    break :blk lambda_node;
                }
            else
                try self.parseBinary(precedence + 1);

            // Handle range operators specially
            if (op_token.kind == .dot_dot or op_token.kind == .dot_dot_dot) {
                const start_ptr = try self.arena.create(Expression);
                const end_ptr = try self.arena.create(Expression);
                start_ptr.* = left.*;
                end_ptr.* = right.*;

                const range_data = ast.Range{
                    .start = start_ptr,
                    .end = end_ptr,
                    .inclusive = op_token.kind == .dot_dot,
                };
                const node = try self.allocateExpression();
                node.* = .{
                    .data = .{ .range = range_data },
                    .location = left.location,
                };
                left = node;
                continue;
            }

            const node = try self.allocateExpression();
            node.* = .{
                .data = .{ .binary = .{
                    .op = switch (op_token.kind) {
                        .plus => .add,
                        .minus => .subtract,
                        .star => .multiply,
                        .slash => .divide,
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
                } },
                .location = left.location, // Use left expression's location for the binary operator
            };
            left = node;
        }

        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*Expression {
        if (self.current.kind == .bang) {
            const bang_token = self.current; // Capture for location
            try self.advance();
            const operand = try self.parseUnary();
            const node = try self.allocateExpression();
            node.* = .{
                .data = .{ .unary = .{
                    .op = .logical_not,
                    .operand = operand,
                } },
                .location = .{
                    .line = bang_token.line,
                    .column = bang_token.column,
                    .offset = bang_token.offset,
                    .length = bang_token.lexeme.len,
                },
            };
            return node;
        }
        return self.parseApplication();
    }

    fn parseApplication(self: *Parser) ParseError!*Expression {
        var expr = try self.parsePrimary();
        var just_applied = false; // Track if we just parsed a function application

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
                        node.* = .{
                            .data = .{ .application = .{ .function = expr, .argument = argument } },
                            .location = expr.location, // Use function's location
                        };
                        expr = node;
                        just_applied = true;
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
                        std.mem.eql(u8, self.current.lexeme, "when") or
                        std.mem.eql(u8, self.current.lexeme, "if") or
                        std.mem.eql(u8, self.current.lexeme, "unless"))
                    {
                        break;
                    }
                    const argument = try self.parsePrimary();
                    const node = try self.allocateExpression();
                    node.* = .{
                        .data = .{ .application = .{ .function = expr, .argument = argument } },
                        .location = expr.location,
                    };
                    expr = node;
                    just_applied = true;
                },
                .dot => {
                    // Disambiguate between field access chains and field accessor arguments using whitespace:
                    // - `obj.field` (no space before dot) = field access chain
                    // - `map .field people` (space before dot) = field accessor as argument
                    const dot_preceded_by_space = self.current.preceded_by_whitespace;

                    if (dot_preceded_by_space and self.lookahead.kind == .identifier) {
                        // Parse as field accessor function argument
                        const argument = try self.parsePrimary();
                        const node = try self.allocateExpression();
                        node.* = .{
                            .data = .{ .application = .{ .function = expr, .argument = argument } },
                            .location = expr.location,
                        };
                        expr = node;
                        just_applied = true;
                        continue;
                    }

                    // Otherwise, handle field access and field projection
                    try self.advance();

                    // Check for field projection: .{ field1, field2 }
                    if (self.current.kind == .l_brace) {
                        try self.advance();
                        var field_list = std.ArrayList([]const u8){};
                        defer field_list.deinit(self.arena);

                        while (self.current.kind != .r_brace) {
                            if (self.current.kind != .identifier) {
                                self.recordError();
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
                        node.* = .{
                            .data = .{ .field_projection = .{
                                .object = expr,
                                .fields = try field_list.toOwnedSlice(self.arena),
                            } },
                            .location = expr.location,
                        };
                        expr = node;
                        just_applied = false;
                    } else if (self.current.kind == .identifier) {
                        // Regular field access: expr.field
                        const field_name = self.current.lexeme;
                        const field_token = self.current;
                        try self.advance();

                        const node = try self.allocateExpression();
                        node.* = .{
                            .data = .{ .field_access = .{
                                .object = expr,
                                .field = field_name,
                                .field_location = .{
                                    .line = field_token.line,
                                    .column = field_token.column,
                                    .offset = field_token.offset,
                                    .length = field_token.lexeme.len,
                                },
                            } },
                            .location = expr.location,
                        };
                        expr = node;
                        just_applied = false;
                    } else {
                        self.recordError();
                        return error.UnexpectedToken;
                    }
                },
                .l_brace => {
                    // Object extension: expr { fields }
                    const object_expr = try self.parseObject();

                    // Extract the fields from the parsed object
                    const fields = switch (object_expr.data) {
                        .object => |obj| obj.fields,
                        else => {
                            self.recordError();
                            return error.UnexpectedToken;
                        },
                    };

                    const node = try self.allocateExpression();
                    node.* = .{
                        .data = .{ .object_extend = .{ .base = expr, .fields = fields } },
                        .location = expr.location,
                    };
                    expr = node;
                    just_applied = false;
                },
                .l_bracket => {
                    // Bracket indexing: expr[index]
                    // Must NOT be preceded by whitespace to distinguish from function application
                    if (self.current.preceded_by_whitespace) {
                        // This is function application with array argument
                        const argument = try self.parsePrimary();
                        const node = try self.allocateExpression();
                        node.* = .{
                            .data = .{ .application = .{ .function = expr, .argument = argument } },
                            .location = expr.location,
                        };
                        expr = node;
                        just_applied = true;
                    } else {
                        // This is indexing: obj[key]
                        try self.advance(); // consume '['
                        const index_expr = try self.parseLambda(); // Parse the index expression
                        try self.expect(.r_bracket);

                        const node = try self.allocateExpression();
                        node.* = .{
                            .data = .{ .index = .{
                                .object = expr,
                                .index = index_expr,
                            } },
                            .location = expr.location,
                        };
                        expr = node;
                        just_applied = false;
                    }
                },
                .number, .string, .symbol, .l_paren => {
                    const argument = try self.parsePrimary();
                    const node = try self.allocateExpression();
                    node.* = .{
                        .data = .{ .application = .{ .function = expr, .argument = argument } },
                        .location = expr.location,
                    };
                    expr = node;
                    just_applied = true;
                },
                else => break,
            }
        }

        return expr;
    }

    fn parsePrimary(self: *Parser) ParseError!*Expression {
        switch (self.current.kind) {
            .number => {
                const num_token = self.current; // Capture for location
                const lexeme = self.current.lexeme;
                // Check if the number contains a decimal point
                const has_decimal_point = std.mem.indexOfScalar(u8, lexeme, '.') != null;
                try self.advance();
                const node = try self.allocateExpression();
                if (has_decimal_point) {
                    const value = try std.fmt.parseFloat(f64, lexeme);
                    node.* = .{
                        .data = .{ .float = value },
                        .location = .{
                            .line = num_token.line,
                            .column = num_token.column,
                            .offset = num_token.offset,
                            .length = num_token.lexeme.len,
                        },
                    };
                } else {
                    const value = try std.fmt.parseInt(i64, lexeme, 10);
                    node.* = .{
                        .data = .{ .integer = value },
                        .location = .{
                            .line = num_token.line,
                            .column = num_token.column,
                            .offset = num_token.offset,
                            .length = num_token.lexeme.len,
                        },
                    };
                }
                return node;
            },
            .identifier => {
                if (std.mem.eql(u8, self.current.lexeme, "import")) {
                    const import_token = self.current; // Capture for location
                    try self.advance();
                    if (self.current.kind != .string) return error.ExpectedExpression;
                    const path = self.current.lexeme;
                    const path_token = self.current; // Capture string location
                    try self.advance();
                    return try self.makeExpression(.{ .import_expr = .{
                        .path = path,
                        .path_location = .{
                            .line = path_token.line,
                            .column = path_token.column,
                            .offset = path_token.offset,
                            .length = path_token.lexeme.len,
                        },
                    } }, import_token);
                }
                if (std.mem.eql(u8, self.current.lexeme, "true")) {
                    const token = self.current;
                    try self.advance();
                    return try self.makeExpression(.{ .boolean = true }, token);
                }
                if (std.mem.eql(u8, self.current.lexeme, "false")) {
                    const token = self.current;
                    try self.advance();
                    return try self.makeExpression(.{ .boolean = false }, token);
                }
                if (std.mem.eql(u8, self.current.lexeme, "null")) {
                    const token = self.current;
                    try self.advance();
                    return try self.makeExpression(.null_literal, token);
                }
                if (std.mem.eql(u8, self.current.lexeme, "if")) {
                    const if_token = self.current; // Capture for location
                    try self.advance();
                    const condition = try self.parseBinary(0);

                    if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "then")) {
                        self.recordError();
                        return error.UnexpectedToken;
                    }
                    try self.advance();

                    const then_expr = try self.parseBinary(0);

                    var else_expr: ?*Expression = null;
                    if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "else")) {
                        try self.advance();
                        else_expr = try self.parseBinary(0);
                    }

                    return try self.makeExpression(.{ .if_expr = .{
                        .condition = condition,
                        .then_expr = then_expr,
                        .else_expr = else_expr,
                    } }, if_token);
                }
                if (std.mem.eql(u8, self.current.lexeme, "when")) {
                    const when_token = self.current; // Capture for location
                    try self.advance();
                    const value = try self.parseBinary(0);

                    if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "matches")) {
                        self.recordError();
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
                            self.recordError();
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

                    return try self.makeExpression(.{ .when_matches = .{
                        .value = value,
                        .branches = try branches.toOwnedSlice(self.arena),
                        .otherwise = otherwise_expr,
                    } }, when_token);
                }
                const ident_token = self.current; // Capture for location
                const name = self.current.lexeme;
                try self.advance();
                return try self.makeExpression(.{ .identifier = name }, ident_token);
            },
            .string => {
                const string_token = self.current; // Capture for location
                const value = self.current.lexeme;
                try self.advance();

                // Check if the string contains interpolation
                const parts = try self.parseStringInterpolation(value);

                if (parts.len == 1 and parts[0] == .literal) {
                    // Simple string with no interpolation
                    return try self.makeExpression(.{ .string_literal = parts[0].literal }, string_token);
                } else {
                    // String with interpolation
                    return try self.makeExpression(.{ .string_interpolation = .{ .parts = parts } }, string_token);
                }
            },
            .symbol => {
                const symbol_token = self.current; // Capture for location
                const value = self.current.lexeme;
                try self.advance();
                return try self.makeExpression(.{ .symbol = value }, symbol_token);
            },
            .l_paren => return self.parseTupleOrParenthesized(),
            .l_bracket => return self.parseArray(),
            .l_brace => return self.parseObject(),
            .dot => {
                // Field accessor function: .field or .field1.field2
                const dot_token = self.current; // Capture for location
                try self.advance();

                var field_list = std.ArrayList([]const u8){};
                defer field_list.deinit(self.arena);

                // First field is required
                if (self.current.kind != .identifier) {
                    self.recordError();
                    return error.UnexpectedToken;
                }
                try field_list.append(self.arena, self.current.lexeme);
                try self.advance();

                // Parse chained fields
                while (self.current.kind == .dot and !self.current.preceded_by_newline) {
                    try self.advance();
                    if (self.current.kind != .identifier) {
                        self.recordError();
                        return error.UnexpectedToken;
                    }
                    try field_list.append(self.arena, self.current.lexeme);
                    try self.advance();
                }

                return try self.makeExpression(.{ .field_accessor = .{
                    .fields = try field_list.toOwnedSlice(self.arena),
                } }, dot_token);
            },
            else => {
                self.recordError();
                return error.ExpectedExpression;
            },
        }
    }

    fn parseArray(self: *Parser) ParseError!*Expression {
        const bracket_token = self.current; // Capture opening bracket for location
        try self.expect(.l_bracket);

        // Empty array
        if (self.current.kind == .r_bracket) {
            try self.advance();
            return try self.makeExpression(.{ .array = .{ .elements = &[_]ArrayElement{} } }, bracket_token);
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

        // Check for trailing if/unless on first element
        if (!is_first_spread and self.current.kind == .identifier) {
            if (std.mem.eql(u8, self.current.lexeme, "if")) {
                try self.advance(); // consume 'if'
                const condition = try self.parseBinary(0);
                try elements.append(self.arena, .{ .conditional_if = .{
                    .expr = first_element,
                    .condition = condition,
                } });
            } else if (std.mem.eql(u8, self.current.lexeme, "unless")) {
                try self.advance(); // consume 'unless'
                const condition = try self.parseBinary(0);
                try elements.append(self.arena, .{ .conditional_unless = .{
                    .expr = first_element,
                    .condition = condition,
                } });
            } else {
                try elements.append(self.arena, .{ .normal = first_element });
            }
        } else if (is_first_spread) {
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
                self.recordError();
                return error.UnexpectedToken;
            }

            // Check for spread operator
            const is_spread = self.current.kind == .dot_dot_dot;
            if (is_spread) {
                try self.advance(); // consume ...
            }

            const element = try self.parseLambda();

            // Check for trailing if/unless
            if (!is_spread and self.current.kind == .identifier) {
                if (std.mem.eql(u8, self.current.lexeme, "if")) {
                    try self.advance(); // consume 'if'
                    const condition = try self.parseBinary(0);
                    try elements.append(self.arena, .{ .conditional_if = .{
                        .expr = element,
                        .condition = condition,
                    } });
                } else if (std.mem.eql(u8, self.current.lexeme, "unless")) {
                    try self.advance(); // consume 'unless'
                    const condition = try self.parseBinary(0);
                    try elements.append(self.arena, .{ .conditional_unless = .{
                        .expr = element,
                        .condition = condition,
                    } });
                } else {
                    try elements.append(self.arena, .{ .normal = element });
                }
            } else if (is_spread) {
                try elements.append(self.arena, .{ .spread = element });
            } else {
                try elements.append(self.arena, .{ .normal = element });
            }
        }

        try self.expect(.r_bracket);

        const slice = try elements.toOwnedSlice(self.arena);
        return try self.makeExpression(.{ .array = .{ .elements = slice } }, bracket_token);
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

        // Use the body expression's location as the start of the comprehension
        const node = try self.allocateExpression();
        node.* = .{
            .data = .{ .array_comprehension = .{
                .body = body,
                .clauses = try clauses.toOwnedSlice(self.arena),
                .filter = filter,
            } },
            .location = body.location,
        };
        return node;
    }

    fn parseObject(self: *Parser) ParseError!*Expression {
        // Consume module-level doc comments (up to --- separator)
        // Due to parser lookahead, the tokenizer has accumulated both module docs
        // and first field docs. We split at the --- separator.
        const module_doc = self.tokenizer.consumeModuleLevelDocComments();

        const brace_token = self.current; // Capture opening brace for location
        try self.expect(.l_brace);

        // Empty object
        if (self.current.kind == .r_brace) {
            try self.advance();
            return try self.makeExpression(.{ .object = .{ .fields = &[_]ObjectField{}, .module_doc = module_doc } }, brace_token);
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

            // Regular object with dynamic field - parse remaining fields
            var fields = std.ArrayListUnmanaged(ObjectField){};
            try fields.append(self.arena, .{
                .key = .{ .dynamic = key_expr },
                .value = value_expr,
                .is_patch = false,
                .doc = null,
                .key_location = key_expr.location,
            });

            // Continue parsing remaining fields if any
            while (self.current.kind == .comma or self.current.preceded_by_newline) {
                if (self.current.kind == .comma) {
                    try self.advance();
                    if (self.current.kind == .r_brace) break;
                }
                if (self.current.kind == .r_brace) break;

                // Parse next field (could be static or dynamic)
                if (self.current.kind == .l_bracket) {
                    // Another dynamic field
                    try self.advance(); // consume '['
                    const next_key_expr = try self.parseLambda();
                    try self.expect(.r_bracket);
                    try self.expect(.colon);
                    const next_value_expr = try self.parseLambda();
                    try fields.append(self.arena, .{
                        .key = .{ .dynamic = next_key_expr },
                        .value = next_value_expr,
                        .is_patch = false,
                        .doc = null,
                        .key_location = next_key_expr.location,
                    });
                } else if (self.current.kind == .identifier) {
                    // Static field
                    const field_token = self.current; // Capture for location
                    const doc = self.current.doc_comments;
                    const static_key = self.current.lexeme;
                    try self.advance();

                    var is_patch = false;
                    const static_value_expr = if (self.current.kind == .colon) blk: {
                        try self.advance();
                        break :blk try self.parseLambda();
                    } else if (self.current.kind == .l_brace and !self.current.preceded_by_newline) blk: {
                        is_patch = true;
                        break :blk try self.parseObject();
                    } else blk: {
                        break :blk try self.makeExpression(.{ .identifier = static_key }, field_token);
                    };

                    try fields.append(self.arena, .{
                        .key = .{ .static = static_key },
                        .value = static_value_expr,
                        .is_patch = is_patch,
                        .doc = doc,
                        .key_location = .{
                            .line = field_token.line,
                            .column = field_token.column,
                            .offset = field_token.offset,
                            .length = field_token.lexeme.len,
                        },
                    });
                } else {
                    break;
                }
            }

            try self.expect(.r_brace);
            const slice = try fields.toOwnedSlice(self.arena);
            return try self.makeExpression(.{ .object = .{ .fields = slice, .module_doc = module_doc } }, brace_token);
        }

        var fields = std.ArrayListUnmanaged(ObjectField){};

        while (self.current.kind != .r_brace) {
            if (self.current.kind != .identifier) {
                // Clear any pending doc comments if we don't find an identifier
                self.tokenizer.clearDocComments();
                self.recordError();
                return error.UnexpectedToken;
            }

            // Get doc comments from the token
            const key_token = self.current; // Capture for location
            const doc = self.current.doc_comments;
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
                break :blk try self.makeExpression(.{ .identifier = key }, key_token);
            };

            try fields.append(self.arena, .{
                .key = .{ .static = key },
                .value = value_expr,
                .is_patch = is_patch,
                .doc = doc,
                .key_location = .{
                    .line = key_token.line,
                    .column = key_token.column,
                    .offset = key_token.offset,
                    .length = key_token.lexeme.len,
                },
            });

            if (self.current.kind == .comma) {
                try self.advance();
                if (self.current.kind == .r_brace) break;
                continue;
            }

            if (self.current.kind == .r_brace) break;

            if (self.current.preceded_by_newline) {
                continue;
            }

            self.recordError();
            return error.UnexpectedToken;
        }

        try self.expect(.r_brace);

        const slice = try fields.toOwnedSlice(self.arena);
        return try self.makeExpression(.{ .object = .{ .fields = slice, .module_doc = module_doc } }, brace_token);
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

        // Use the key expression's location as the start of the comprehension
        const node = try self.allocateExpression();
        node.* = .{
            .data = .{ .object_comprehension = .{
                .key = key,
                .value = value,
                .clauses = try clauses.toOwnedSlice(self.arena),
                .filter = filter,
            } },
            .location = key.location,
        };
        return node;
    }

    fn parseTupleOrParenthesized(self: *Parser) ParseError!*Expression {
        const paren_token = self.current; // Capture opening paren for location
        try self.expect(.l_paren);

        // Empty tuple: ()
        if (self.current.kind == .r_paren) {
            try self.advance();
            return try self.makeExpression(.{ .tuple = .{ .elements = &[_]*Expression{} } }, paren_token);
        }

        // Check for operator function: (+), (-), (*), (/), etc.
        const op: ?BinaryOp = switch (self.current.kind) {
            .plus => .add,
            .minus => .subtract,
            .star => .multiply,
            .slash => .divide,
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
            else => null,
        };

        if (op) |operator| {
            try self.advance();
            try self.expect(.r_paren);
            return try self.makeExpression(.{ .operator_function = operator }, paren_token);
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
        return try self.makeExpression(.{ .tuple = .{ .elements = slice } }, paren_token);
    }

    fn createPattern(self: *Parser, data: PatternData, token: Token) !*Pattern {
        const pattern = try self.arena.create(Pattern);
        pattern.* = .{
            .data = data,
            .location = .{
                .line = token.line,
                .column = token.column,
                .offset = token.offset,
                .length = token.lexeme.len,
            },
        };
        return pattern;
    }

    fn parsePattern(self: *Parser) ParseError!*Pattern {
        switch (self.current.kind) {
            .number => {
                const token = self.current;
                const lexeme = self.current.lexeme;
                // Check if the number contains a decimal point
                const has_decimal_point = std.mem.indexOfScalar(u8, lexeme, '.') != null;
                try self.advance();
                if (has_decimal_point) {
                    const value = try std.fmt.parseFloat(f64, lexeme);
                    return try self.createPattern(.{ .float = value }, token);
                } else {
                    const value = try std.fmt.parseInt(i64, lexeme, 10);
                    return try self.createPattern(.{ .integer = value }, token);
                }
            },
            .string => {
                const token = self.current;
                const value = self.current.lexeme;
                try self.advance();
                return try self.createPattern(.{ .string_literal = value }, token);
            },
            .symbol => {
                const token = self.current;
                const value = self.current.lexeme;
                try self.advance();
                return try self.createPattern(.{ .symbol = value }, token);
            },
            .identifier => {
                const token = self.current;
                const name = self.current.lexeme;

                // Check for boolean and null literals
                if (std.mem.eql(u8, name, "true")) {
                    try self.advance();
                    return try self.createPattern(.{ .boolean = true }, token);
                }
                if (std.mem.eql(u8, name, "false")) {
                    try self.advance();
                    return try self.createPattern(.{ .boolean = false }, token);
                }
                if (std.mem.eql(u8, name, "null")) {
                    try self.advance();
                    return try self.createPattern(.null_literal, token);
                }

                // Regular identifier pattern
                try self.advance();
                return try self.createPattern(.{ .identifier = name }, token);
            },
            .l_paren => return self.parseTuplePattern(),
            .l_bracket => return self.parseArrayPattern(),
            .l_brace => return self.parseObjectPattern(),
            else => return error.UnexpectedToken,
        }
    }

    fn parseTuplePattern(self: *Parser) ParseError!*Pattern {
        const start_token = self.current;
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
            self.recordError();
            return error.UnexpectedToken;
        }

        try self.expect(.r_paren);

        const slice = try elements.toOwnedSlice(self.arena);
        return try self.createPattern(.{ .tuple = .{ .elements = slice } }, start_token);
    }

    fn parseArrayPattern(self: *Parser) ParseError!*Pattern {
        const start_token = self.current;
        try self.expect(.l_bracket);

        var elements = std.ArrayListUnmanaged(*Pattern){};
        var rest: ?[]const u8 = null;

        while (self.current.kind != .r_bracket) {
            // Check for spread operator
            if (self.current.kind == .dot_dot_dot) {
                try self.advance();
                // Expect an identifier after ...
                if (self.current.kind != .identifier) {
                    self.recordError();
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
            self.recordError();
            return error.UnexpectedToken;
        }

        try self.expect(.r_bracket);

        const slice = try elements.toOwnedSlice(self.arena);
        return try self.createPattern(.{ .array = .{ .elements = slice, .rest = rest } }, start_token);
    }

    fn parseObjectPattern(self: *Parser) ParseError!*Pattern {
        const start_token = self.current;
        try self.expect(.l_brace);

        var fields = std.ArrayListUnmanaged(ObjectPatternField){};

        while (self.current.kind != .r_brace) {
            if (self.current.kind != .identifier) {
                self.recordError();
                return error.UnexpectedToken;
            }
            const field_token = self.current;
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
                const field_pattern = try self.createPattern(.{ .identifier = field_name }, field_token);
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
            self.recordError();
            return error.UnexpectedToken;
        }

        try self.expect(.r_brace);

        const slice = try fields.toOwnedSlice(self.arena);
        return try self.createPattern(.{ .object = .{ .fields = slice } }, start_token);
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
        self.lookahead = self.tokenizer.next() catch |err| {
            // For UnexpectedCharacter and UnterminatedString,
            // the tokenizer already recorded the error location
            // For other errors, record error location from current token
            if (err != error.UnexpectedCharacter and err != error.UnterminatedString) {
                self.recordError();
            }
            return err;
        };
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
                        // Use dummy location for synthetic interpolation identifier
                        expr.* = .{
                            .data = .{ .identifier = ident },
                            .location = .{ .line = 0, .column = 0, .offset = 0, .length = 0 },
                        };
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

    /// Create an expression with location from a specific token
    fn makeExpression(self: *Parser, data: ExpressionData, token: Token) ParseError!*Expression {
        const expr = try self.allocateExpression();
        expr.* = .{
            .data = data,
            .location = .{
                .line = token.line,
                .column = token.column,
                .offset = token.offset,
                .length = token.lexeme.len,
            },
        };
        return expr;
    }

    /// Create an expression with location from the current token
    fn makeExpressionHere(self: *Parser, data: ExpressionData) ParseError!*Expression {
        return self.makeExpression(data, self.current);
    }
};

fn getPrecedence(kind: TokenKind) ?u32 {
    return switch (kind) {
        .backslash => 2,
        .pipe_pipe => 3,
        .ampersand_ampersand => 4,
        .equals_equals, .bang_equals, .less, .greater, .less_equals, .greater_equals => 5,
        .ampersand => 6, // Object merge operator
        .dot_dot, .dot_dot_dot => 6, // Range operators
        .plus, .minus => 7,
        .star, .slash => 8,
        else => null,
    };
}
