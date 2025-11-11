const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates where with single binding" {
    try expectEvaluates("x where x = 42", "42");
}

test "evaluates where with multiple bindings" {
    try expectEvaluates("x + y where x = 5; y = 3", "8");
}

test "evaluates where with newline-separated bindings" {
    try expectEvaluates(
        \\x + y where
        \\x = 10
        \\y = 20
    ,
        "30",
    );
}

test "evaluates where with dependent bindings" {
    try expectEvaluates("x + y where x = 5; y = x * 2", "15");
}

test "evaluates where with complex expression" {
    try expectEvaluates("a + b * c where a = 1; b = 2; c = 3", "7");
}

test "evaluates where in tuple" {
    try expectEvaluates("(x where x = 1, y where y = 2)", "(1, 2)");
}

test "evaluates where in array" {
    try expectEvaluates("[x where x = 10, y where y = 20]", "[10, 20]");
}

test "evaluates where in object" {
    try expectEvaluates("{ a: x where x = 100 }", "{ a: 100 }");
}
