const std = @import("std");
const eval = @import("evaluator");

// Corpus of syntactically plausible Lazylang programs covering a wide range
// of language features. In normal test mode these are smoke-tested; in fuzz
// mode the fuzzer mutates them to discover crashes.
const corpus: []const []const u8 = &.{
    // Literals
    "42",
    "-1",
    "0",
    "3.14",
    "-2.5",
    "true",
    "false",
    "null",
    "\"\"",
    "\"hello\"",
    "#ok",
    "#notFound",

    // Arithmetic
    "1 + 2",
    "10 - 3",
    "4 * 5",
    "10 / 2",
    "10 % 3",
    "2 ^ 8",
    "(1 + 2) * (3 - 1)",
    "-(5 + 3)",

    // Boolean
    "true && false",
    "true || false",
    "!true",
    "1 == 1",
    "1 != 2",
    "3 > 2",
    "2 < 3",
    "3 >= 3",
    "2 <= 3",

    // Strings
    "\"hello\" ++ \" world\"",
    "\"a\" == \"a\"",

    // Arrays
    "[]",
    "[1]",
    "[1, 2, 3]",
    "[1, 2] ++ [3, 4]",
    "[x * 2 for x in [1, 2, 3]]",
    "[x for x in [1, 2, 3] when x > 1]",

    // Objects
    "{}",
    "{ x: 1 }",
    "{ x: 1, y: 2 }",
    "{ x: 1 } & { y: 2 }",
    "{ x: 1 } & { x: 2 }",
    "base { extra: 1 } where base = { x: 1 }",

    // Tuples
    "(1, 2)",
    "(1, 2, 3)",
    "(true, \"hello\", 42)",

    // Let bindings
    "x = 1; x",
    "x = 1; y = 2; x + y",
    "(a, b) = (1, 2); a + b",
    "[head, ...tail] = [1, 2, 3]; head",
    "{ x, y } = { x: 1, y: 2 }; x + y",

    // Lambdas and application
    "(x -> x + 1) 5",
    "(x -> y -> x + y) 3 4",
    "(f -> f 42) (x -> x * 2)",

    // Conditionals
    "if true then 1 else 2",
    "if false then 1 else 2",
    "if 1 > 0 then \"positive\" else \"non-positive\"",

    // When/pattern matching
    "when 1 is\n  1 then \"one\"\n  2 then \"two\"\n  otherwise \"other\"",
    "when #ok is\n  #ok then true\n  #err then false\n  otherwise null",

    // Where clause
    "result where result = x + y; x = 10; y = 20",

    // Pipeline
    "5 \\ (x -> x * 2)",
    "[1, 2, 3] \\ Array.length",

    // Field access
    "{ x: 42 }.x",
    "{ a: { b: 1 } }.a.b",

    // Array indexing
    "[10, 20, 30][1]",

    // Field accessor (partial application)
    ".x { x: 99 }",

    // Imports (stdlib available)
    "Array.length [1, 2, 3]",
    "Array.map (x -> x + 1) [1, 2, 3]",
    "Array.filter (x -> x > 1) [1, 2, 3]",
    "Array.fold (acc -> x -> acc + x) 0 [1, 2, 3]",
    "Array.reverse [1, 2, 3]",
    "String.length \"hello\"",
    "String.append \"foo\" \"bar\"",
    "String.reverse \"hello\"",
    "Math.abs (0 - 5)",
    "Range.toArray (1..5)",

    // Assert (should pass)
    "assert 1 == 1 : \"one equals one\"; true",
    "assert true : \"should be true\"; 42",

    // String interpolation
    "n = 42; \"the answer is #{n}\"",
    "\"#{1 + 1} is two\"",

    // Nested / complex
    "xs = [1, 2, 3]; Array.map (x -> x * x) xs",
    "f = n -> if n <= 1 then 1 else n * (f (n - 1)); f 5",
    "obj = { items: [1, 2, 3] }; Array.length obj.items",

    // Symbol comparisons
    "#ok == #ok",
    "#ok != #err",

    // Operator functions
    "(+) 1 2",
    "Array.fold (+) 0 [1, 2, 3]",

    // Intentionally erroneous programs — evaluator must return an error, not crash
    "undefined_variable",
    "1 / 0",
    "1 + \"string\"",
    "null.field",
    "[1, 2, 3][99]",
    "assert false : \"intentional\"; 0",
    "(x -> x x) (x -> x x)",
};

fn fuzzEvalOne(context: void, input: []const u8) anyerror!void {
    _ = context;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // evalInline uses its own internal arena; we pass a general-purpose
    // allocator for the result string allocation.
    var result = eval.evalInline(arena.allocator(), input) catch return;
    defer result.deinit();
}

test "fuzz evaluator: never crashes on arbitrary input" {
    try std.testing.fuzz({}, fuzzEvalOne, .{ .corpus = corpus });
}
