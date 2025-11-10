const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates if-then-else with true condition" {
    try expectEvaluates("if true then 1 else 2", "1");
}

test "evaluates if-then-else with false condition" {
    try expectEvaluates("if false then 1 else 2", "2");
}

test "evaluates if-then without else with true condition" {
    try expectEvaluates("if true then 42", "42");
}

test "evaluates if-then without else with false condition returns null" {
    try expectEvaluates("if false then 42", "null");
}

test "evaluates if with boolean expression condition" {
    try expectEvaluates("if true && false then 1 else 2", "2");
}

test "evaluates if with complex condition" {
    try expectEvaluates("if !false then \"yes\" else \"no\"", "\"yes\"");
}

test "evaluates nested if expressions" {
    try expectEvaluates("if true then (if false then 1 else 2) else 3", "2");
}

test "evaluates if in array" {
    try expectEvaluates("[if true then 1 else 2, if false then 3 else 4]", "[1, 4]");
}

test "evaluates if in tuple" {
    try expectEvaluates("(if true then \"a\" else \"b\", if false then \"c\" else \"d\")", "(\"a\", \"d\")");
}

test "evaluates if with arithmetic in branches" {
    try expectEvaluates("if true then 1 + 2 else 3 * 4", "3");
}

test "evaluates chained if-else-if with first condition true" {
    try expectEvaluates("if true then 1 else if false then 2 else 3", "1");
}

test "evaluates chained if-else-if with second condition true" {
    try expectEvaluates("if false then 1 else if true then 2 else 3", "2");
}

test "evaluates chained if-else-if with all conditions false" {
    try expectEvaluates("if false then 1 else if false then 2 else 3", "3");
}
