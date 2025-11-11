const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates equality operator with equal integers" {
    try expectEvaluates("5 == 5", "true");
}

test "evaluates equality operator with different integers" {
    try expectEvaluates("5 == 3", "false");
}

test "evaluates inequality operator with different integers" {
    try expectEvaluates("5 != 3", "true");
}

test "evaluates inequality operator with equal integers" {
    try expectEvaluates("5 != 5", "false");
}

test "evaluates less than operator" {
    try expectEvaluates("3 < 5", "true");
    try expectEvaluates("5 < 3", "false");
    try expectEvaluates("5 < 5", "false");
}

test "evaluates greater than operator" {
    try expectEvaluates("5 > 3", "true");
    try expectEvaluates("3 > 5", "false");
    try expectEvaluates("5 > 5", "false");
}

test "evaluates less than or equal operator" {
    try expectEvaluates("3 <= 5", "true");
    try expectEvaluates("5 <= 5", "true");
    try expectEvaluates("5 <= 3", "false");
}

test "evaluates greater than or equal operator" {
    try expectEvaluates("5 >= 3", "true");
    try expectEvaluates("5 >= 5", "true");
    try expectEvaluates("3 >= 5", "false");
}

test "evaluates comparison in conditional" {
    try expectEvaluates("if 10 > 5 then \"yes\" else \"no\"", "\"yes\"");
    try expectEvaluates("if 3 > 5 then \"yes\" else \"no\"", "\"no\"");
}

test "evaluates comparison with arithmetic" {
    try expectEvaluates("2 + 3 == 5", "true");
    try expectEvaluates("2 * 3 > 5", "true");
    try expectEvaluates("10 - 5 < 3", "false");
}

test "evaluates chained comparisons with logical operators" {
    try expectEvaluates("5 > 3 && 10 < 20", "true");
    try expectEvaluates("5 < 3 || 10 > 5", "true");
    try expectEvaluates("5 == 5 && 3 != 3", "false");
}

test "evaluates comparison with negative numbers" {
    try expectEvaluates("-5 < 0", "true");
    try expectEvaluates("-10 > -5", "false");
    try expectEvaluates("-5 == -5", "true");
}

test "evaluates comparison precedence" {
    // Comparison should have lower precedence than arithmetic
    try expectEvaluates("2 + 3 == 4 + 1", "true");
    try expectEvaluates("10 - 5 > 2 * 2", "true");
}

test "evaluates nested conditionals with comparisons" {
    try expectEvaluates(
        \\score = 85
        \\if score >= 90 then "excellent" else if score >= 70 then "good" else "needs improvement"
    , "\"good\"");
}
