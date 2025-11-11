const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates null literal" {
    try expectEvaluates("null", "null");
}

test "evaluates null in array" {
    try expectEvaluates("[null, 1, null]", "[null, 1, null]");
}

test "evaluates null in tuple" {
    try expectEvaluates("(null, true, false)", "(null, true, false)");
}

test "evaluates null in object" {
    try expectEvaluates("{ value: null }", "{ value: null }");
}

test "evaluates mixed types with null" {
    try expectEvaluates("(1, null, \"test\", true, null)", "(1, null, \"test\", true, null)");
}
