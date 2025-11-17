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
