const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates arithmetic expressions" {
    try expectEvaluates("1 + 2 * 3", "7");
}

test "evaluates parentheses" {
    try expectEvaluates("(1 + 2) * 3", "9");
}

test "evaluates division" {
    try expectEvaluates("10 / 2", "5");
    try expectEvaluates("20 / 4", "5");
    try expectEvaluates("100 / 10", "10");
}

test "evaluates division with operator precedence" {
    try expectEvaluates("10 + 20 / 4", "15");
    try expectEvaluates("20 / 4 + 10", "15");
    try expectEvaluates("(10 + 20) / 6", "5");
}

test "evaluates division with multiplication" {
    try expectEvaluates("20 / 4 * 2", "10");
    try expectEvaluates("20 * 4 / 2", "40");
}

// Negative number literals

test "negative integer literal" {
    try expectEvaluates("-5", "-5");
}

test "negative integer in expression" {
    try expectEvaluates("-5 + 10", "5");
}

test "negative integer in array" {
    try expectEvaluates("[-1, -2, -3]", "[-1, -2, -3]");
}

test "negative integer in object" {
    try expectEvaluates("{ x: -1 }", "{ x: -1 }");
}

test "negative float literal" {
    try expectEvaluates("-3.14", "-3.14");
}

test "subtraction still works" {
    try expectEvaluates("10 - 5", "5");
}

test "double negative" {
    try expectEvaluates("--5", "5");
}
