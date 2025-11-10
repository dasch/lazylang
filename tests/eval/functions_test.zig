const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates lambda application" {
    try expectEvaluates("(x -> x + 1) 41", "42");
}

test "supports higher order functions" {
    try expectEvaluates("(a -> b -> a + b) 2 3", "5");
}

test "evaluates function with tuple destructuring parameter" {
    try expectEvaluates("f = (a, b) -> a + b; f (1, 2)", "3");
}

test "evaluates function with object destructuring parameter" {
    try expectEvaluates("f = { first, last } -> first; f { first: \"John\", last: \"Doe\" }", "\"John\"");
}

test "evaluates function with array destructuring parameter" {
    try expectEvaluates("f = [x, y] -> x + y; f [10, 20]", "30");
}

test "evaluates function with nested destructuring parameter" {
    try expectEvaluates("f = (a, (b, c)) -> a + b + c; f (1, (2, 3))", "6");
}
