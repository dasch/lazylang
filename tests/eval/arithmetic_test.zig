const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates arithmetic expressions" {
    try expectEvaluates("1 + 2 * 3", "7");
}

test "evaluates parentheses" {
    try expectEvaluates("(1 + 2) * 3", "9");
}
