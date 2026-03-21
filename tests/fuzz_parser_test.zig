const std = @import("std");
const eval = @import("evaluator");

const Parser = eval.Parser;

// Corpus of interesting inputs to exercise the parser.
// These are run in normal test mode; in fuzz mode, the fuzzer mutates them.
const corpus: []const []const u8 = &.{
    // Empty and whitespace
    "",
    " ",
    "\n",
    "\t",

    // Valid expressions
    "42",
    "3.14",
    "true",
    "false",
    "null",
    "\"hello\"",
    "#ok",
    "1 + 2",
    "1 - 2",
    "1 * 2",
    "10 / 2",
    "2 ^ 3",
    "10 % 3",
    "(1 + 2) * 3",
    "-5",
    "--5",
    "!true",
    "[1, 2, 3]",
    "{ x: 1, y: 2 }",
    "x -> x + 1",
    "f x",
    "f x y",
    "x = 1; x",
    "if true then 1 else 2",
    "if false then 1",
    "x + y where x = 1; y = 2",
    "(a, b) = (1, 2); a",
    "[head, ...tail] = xs; head",
    "{ name, age } = obj; name",
    "[x * 2 for x in xs]",
    "[x for x in xs when x > 0]",
    "{ k: v for k, v in obj }",
    "base { x: 1 }",
    ".name",
    ".a.b.c",
    "obj.field",
    "arr[0]",
    "(+)",
    "(-)",
    "(*)",
    "1 + 2 \\ f",
    "a && b",
    "a || b",
    "a == b",
    "a != b",
    "a < b",
    "a <= b",
    "a > b",
    "a >= b",
    "a & b",
    "a ++ b",
    "when x is\n  1 then \"one\"\n  otherwise \"other\"",
    "assert x > 0 : \"must be positive\"; x",
    "import \"Array\"",
    "\"hello #{name}\"",

    // Tricky / edge cases
    "{ }",
    "[ ]",
    "()",
    "{ x: { y: { z: 1 } } }",
    "[[[1, 2], [3]], [4]]",
    "a -> b -> a + b",
    "let x = 1 in x",
    "1 == 1 == 1",
    "a.b.c.d",
    "f (g x) (h y)",

    // Intentionally broken inputs — parser must return an error, not crash
    "(",
    ")",
    "[",
    "]",
    "{",
    "}",
    "1 +",
    "* 2",
    "\"unterminated",
    "@",
    "!",
    "if",
    "if true",
    "if true then",
    "->",
    "x ->",
    "import",
    "import 42",
    "when x is",
    "assert",
    "assert x",
    "{ x: }",
    "{ : 1 }",
    "[1,]",
    "(1,)",
    "...",
    "\\",
    "#",

    // Binary garbage
    "\x00",
    "\xff\xfe",
    "\x01\x02\x03",
    "a\x00b",
    "\xc0\x80",

    // Very long inputs
    "1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1",
    "((((((((((1))))))))))",
    "{ a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8, i: 9, j: 10 }",
    "[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]",
};

fn fuzzParserOne(context: void, input: []const u8) anyerror!void {
    _ = context;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // The parser must never crash — it must return an error or a valid AST.
    var parser = Parser.init(arena.allocator(), input) catch return;
    _ = parser.parse() catch return;
}

test "fuzz parser: never crashes on arbitrary input" {
    try std.testing.fuzz({}, fuzzParserOne, .{ .corpus = corpus });
}
