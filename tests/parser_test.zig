const std = @import("std");
const eval = @import("evaluator");
const testing = std.testing;

const Parser = eval.Parser;

fn expectParses(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    _ = try parser.parse();
}

fn expectParseError(source: []const u8, expected: anyerror) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source) catch |err| {
        try testing.expectEqual(expected, err);
        return;
    };
    const result = parser.parse();
    if (result) |_| {
        return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(expected, err);
    }
}

// ============================================================================
// OPERATOR PRECEDENCE
// ============================================================================

test "parser: multiplication has higher precedence than addition" {
    // 1 + 2 * 3 should parse as 1 + (2 * 3), not (1 + 2) * 3
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "1 + 2 * 3");
    const expr = try parser.parse();

    // Top level should be binary add
    switch (expr.data) {
        .binary => |bin| {
            try testing.expectEqual(.add, bin.op);
            // Left should be integer 1
            switch (bin.left.data) {
                .integer => |v| try testing.expectEqual(@as(i64, 1), v),
                else => return error.TestUnexpectedResult,
            }
            // Right should be binary multiply
            switch (bin.right.data) {
                .binary => |inner| {
                    try testing.expectEqual(.multiply, inner.op);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: parentheses override precedence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "(1 + 2) * 3");
    const expr = try parser.parse();

    // Top level should be binary multiply
    switch (expr.data) {
        .binary => |bin| {
            try testing.expectEqual(.multiply, bin.op);
            // Left should be binary add (from parenthesized expression)
            switch (bin.left.data) {
                .binary => |inner| {
                    try testing.expectEqual(.add, inner.op);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: comparison has lower precedence than arithmetic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "2 + 3 == 5");
    const expr = try parser.parse();

    switch (expr.data) {
        .binary => |bin| {
            try testing.expectEqual(.equal, bin.op);
            // Left should be 2 + 3
            switch (bin.left.data) {
                .binary => |inner| try testing.expectEqual(.add, inner.op),
                else => return error.TestUnexpectedResult,
            }
            // Right should be 5
            switch (bin.right.data) {
                .integer => |v| try testing.expectEqual(@as(i64, 5), v),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: logical AND has lower precedence than comparison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "x > 0 && y < 10");
    const expr = try parser.parse();

    switch (expr.data) {
        .binary => |bin| {
            try testing.expectEqual(.logical_and, bin.op);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: logical OR has lower precedence than logical AND" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "a && b || c");
    const expr = try parser.parse();

    switch (expr.data) {
        .binary => |bin| {
            try testing.expectEqual(.logical_or, bin.op);
            // Left should be a && b
            switch (bin.left.data) {
                .binary => |inner| try testing.expectEqual(.logical_and, inner.op),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: pipeline has lowest precedence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Pipeline operator is backslash in Lazylang
    var parser = try Parser.init(arena.allocator(), "x + 1 \\ f");
    const expr = try parser.parse();

    switch (expr.data) {
        .binary => |bin| {
            try testing.expectEqual(.pipeline, bin.op);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ============================================================================
// EXPRESSION TYPES
// ============================================================================

test "parser: integer literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "42");
    const expr = try parser.parse();

    switch (expr.data) {
        .integer => |v| try testing.expectEqual(@as(i64, 42), v),
        else => return error.TestUnexpectedResult,
    }
}

test "parser: float literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "3.14");
    const expr = try parser.parse();

    switch (expr.data) {
        .float => |v| try testing.expect(@abs(v - 3.14) < 0.001),
        else => return error.TestUnexpectedResult,
    }
}

test "parser: string literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "\"hello\"");
    const expr = try parser.parse();

    switch (expr.data) {
        .string_literal => |s| try testing.expectEqualStrings("hello", s),
        else => return error.TestUnexpectedResult,
    }
}

test "parser: symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "#ok");
    const expr = try parser.parse();

    switch (expr.data) {
        .symbol => |s| try testing.expectEqualStrings("#ok", s),
        else => return error.TestUnexpectedResult,
    }
}

test "parser: lambda" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "x -> x + 1");
    const expr = try parser.parse();

    switch (expr.data) {
        .lambda => |l| {
            switch (l.param.data) {
                .identifier => |name| try testing.expectEqualStrings("x", name),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: let binding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "x = 42; x");
    const expr = try parser.parse();

    switch (expr.data) {
        .let => |l| {
            switch (l.pattern.data) {
                .identifier => |name| try testing.expectEqualStrings("x", name),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: if-then-else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "if true then 1 else 2");
    const expr = try parser.parse();

    switch (expr.data) {
        .if_expr => |ie| {
            try testing.expect(ie.else_expr != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: if-then without else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "if true then 42");
    const expr = try parser.parse();

    switch (expr.data) {
        .if_expr => |ie| {
            try testing.expect(ie.else_expr == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: when matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "when x is\n  1 then \"one\"\n  2 then \"two\"\n  otherwise \"other\"");
    const expr = try parser.parse();

    switch (expr.data) {
        .when_matches => |wm| {
            try testing.expectEqual(@as(usize, 2), wm.branches.len);
            try testing.expect(wm.otherwise != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: array comprehension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "[x * 2 for x in xs]");
    const expr = try parser.parse();

    switch (expr.data) {
        .array_comprehension => |comp| {
            try testing.expectEqual(@as(usize, 1), comp.clauses.len);
            try testing.expect(comp.filter == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: array comprehension with filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "[x for x in xs when x > 0]");
    const expr = try parser.parse();

    switch (expr.data) {
        .array_comprehension => |comp| {
            try testing.expectEqual(@as(usize, 1), comp.clauses.len);
            try testing.expect(comp.filter != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: object extend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "base { x: 1 }");
    const expr = try parser.parse();

    switch (expr.data) {
        .object_extend => |oe| {
            try testing.expectEqual(@as(usize, 1), oe.fields.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: field accessor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), ".name");
    const expr = try parser.parse();

    switch (expr.data) {
        .field_accessor => |fa| {
            try testing.expectEqual(@as(usize, 1), fa.fields.len);
            try testing.expectEqualStrings("name", fa.fields[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: operator function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "(+)");
    const expr = try parser.parse();

    switch (expr.data) {
        .operator_function => |op| {
            try testing.expectEqual(.add, op);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: where expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "x + y where x = 1; y = 2");
    const expr = try parser.parse();

    switch (expr.data) {
        .where_expr => |w| {
            try testing.expectEqual(@as(usize, 2), w.bindings.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ============================================================================
// PARSE ERRORS
// ============================================================================

test "parser: rejects unterminated string" {
    try expectParseError("\"hello", error.UnterminatedString);
}

test "parser: rejects unexpected character" {
    try expectParseError("@", error.UnexpectedCharacter);
}

test "parser: rejects missing expression after operator" {
    try expectParseError("5 +", error.ExpectedExpression);
}

test "parser: rejects missing closing paren" {
    try expectParseError("(5 + 3", error.UnexpectedToken);
}

test "parser: rejects missing closing bracket" {
    try expectParseError("[1, 2", error.UnexpectedToken);
}

test "parser: rejects missing closing brace" {
    try expectParseError("{ x: 1", error.UnexpectedToken);
}

// ============================================================================
// PATTERN PARSING
// ============================================================================

test "parser: tuple destructuring pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "(a, b) = (1, 2); a");
    const expr = try parser.parse();

    switch (expr.data) {
        .let => |l| {
            switch (l.pattern.data) {
                .tuple => |t| try testing.expectEqual(@as(usize, 2), t.elements.len),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: array destructuring pattern with rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "[head, ...tail] = xs; head");
    const expr = try parser.parse();

    switch (expr.data) {
        .let => |l| {
            switch (l.pattern.data) {
                .array => |a| {
                    try testing.expectEqual(@as(usize, 1), a.elements.len);
                    try testing.expect(a.rest != null);
                    try testing.expectEqualStrings("tail", a.rest.?);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: object destructuring pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "{ name, age } = obj; name");
    const expr = try parser.parse();

    switch (expr.data) {
        .let => |l| {
            switch (l.pattern.data) {
                .object => |o| {
                    try testing.expectEqual(@as(usize, 2), o.fields.len);
                    try testing.expectEqualStrings("name", o.fields[0].key);
                    try testing.expectEqualStrings("age", o.fields[1].key);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

// ============================================================================
// CONDITIONAL ARRAY ELEMENTS
// ============================================================================

test "parser: conditional array element with if" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "[1, 2 if true, 3]");
    const expr = try parser.parse();

    switch (expr.data) {
        .array => |arr| {
            try testing.expectEqual(@as(usize, 3), arr.elements.len);
            switch (arr.elements[1]) {
                .conditional_if => {},
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser: conditional array element with unless" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "[1, 2 unless false, 3]");
    const expr = try parser.parse();

    switch (expr.data) {
        .array => |arr| {
            try testing.expectEqual(@as(usize, 3), arr.elements.len);
            switch (arr.elements[1]) {
                .conditional_unless => {},
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}
