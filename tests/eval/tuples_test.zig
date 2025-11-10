const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates empty tuple" {
    try expectEvaluates("()", "()");
}

test "evaluates single element tuple" {
    try expectEvaluates("(42,)", "(42)");
}

test "evaluates two element tuple" {
    try expectEvaluates("(1, 2)", "(1, 2)");
}

test "evaluates multi-element tuple" {
    try expectEvaluates("(1, 2, 3, 4)", "(1, 2, 3, 4)");
}

test "evaluates tuple with mixed types" {
    try expectEvaluates("(1, \"test\", 3)", "(1, \"test\", 3)");
}

test "evaluates nested tuples" {
    try expectEvaluates("((1, 2), (3, 4))", "((1, 2), (3, 4))");
}

test "evaluates tuple with expressions" {
    try expectEvaluates("(1 + 2, 3 * 4)", "(3, 12)");
}

test "evaluates tuple with arrays" {
    try expectEvaluates("([1, 2], [3, 4])", "([1, 2], [3, 4])");
}

test "evaluates tuple with objects" {
    try expectEvaluates("({ a: 1 }, { b: 2 })", "({a: 1}, {b: 2})");
}

test "evaluates tuple with strings" {
    try expectEvaluates("(\"a\", \"b\", \"c\")", "(\"a\", \"b\", \"c\")");
}

test "distinguishes parenthesized expressions from tuples" {
    try expectEvaluates("(42)", "42");
    try expectEvaluates("(1 + 2)", "3");
}

test "evaluates tuple with lambda expressions" {
    try expectEvaluates("((x -> x + 1), (x -> x * 2))", "(<function>, <function>)");
}
