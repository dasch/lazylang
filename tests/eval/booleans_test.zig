const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates true literal" {
    try expectEvaluates("true", "true");
}

test "evaluates false literal" {
    try expectEvaluates("false", "false");
}

test "evaluates boolean in array" {
    try expectEvaluates("[true, false]", "[true, false]");
}

test "evaluates boolean in tuple" {
    try expectEvaluates("(true, false)", "(true, false)");
}

test "evaluates boolean in object" {
    try expectEvaluates("{ a: true, b: false }", "{ a: true, b: false }");
}

test "evaluates mixed boolean and integer tuple" {
    try expectEvaluates("(true, 42, false)", "(true, 42, false)");
}

test "evaluates mixed types with booleans" {
    try expectEvaluates("(true, \"hello\", 42, false)", "(true, \"hello\", 42, false)");
}

test "evaluates logical AND with true and true" {
    try expectEvaluates("true && true", "true");
}

test "evaluates logical AND with true and false" {
    try expectEvaluates("true && false", "false");
}

test "evaluates logical AND with false and false" {
    try expectEvaluates("false && false", "false");
}

test "evaluates logical OR with true and true" {
    try expectEvaluates("true || true", "true");
}

test "evaluates logical OR with true and false" {
    try expectEvaluates("true || false", "true");
}

test "evaluates logical OR with false and false" {
    try expectEvaluates("false || false", "false");
}

test "evaluates logical NOT with true" {
    try expectEvaluates("!true", "false");
}

test "evaluates logical NOT with false" {
    try expectEvaluates("!false", "true");
}

test "evaluates double NOT" {
    try expectEvaluates("!!true", "true");
}

test "evaluates complex boolean expression with AND and OR" {
    try expectEvaluates("true && false || true", "true");
}

test "evaluates boolean expression with parentheses" {
    try expectEvaluates("!(true && false)", "true");
}

test "evaluates chained AND operations" {
    try expectEvaluates("true && true && true", "true");
}

test "evaluates chained OR operations" {
    try expectEvaluates("false || false || true", "true");
}

test "evaluates mixed boolean operations" {
    try expectEvaluates("!false && true || false", "true");
}
