const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates tuple destructuring in assignment" {
    try expectEvaluates("(first, last) = (\"John\", \"Doe\"); first", "\"John\"");
}

test "evaluates tuple destructuring with multiple bindings" {
    try expectEvaluates("(a, b) = (1, 2); a + b", "3");
}

test "evaluates tuple destructuring with three elements" {
    try expectEvaluates("(x, y, z) = (1, 2, 3); x + y + z", "6");
}

test "evaluates object destructuring in assignment" {
    try expectEvaluates("{ first, last } = { first: \"John\", last: \"Doe\" }; first", "\"John\"");
}

test "evaluates object destructuring with multiple uses" {
    try expectEvaluates("{ x, y } = { x: 10, y: 20 }; x + y", "30");
}

test "evaluates array destructuring with two elements" {
    try expectEvaluates("[a, b] = [1, 2]; a + b", "3");
}

test "evaluates nested destructuring" {
    try expectEvaluates("(a, (b, c)) = (1, (2, 3)); a + b + c", "6");
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
