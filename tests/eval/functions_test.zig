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

test "evaluates operator function: addition" {
    try expectEvaluates("(+) 1 2", "3");
}

test "evaluates operator function: subtraction" {
    try expectEvaluates("(-) 5 3", "2");
}

test "evaluates operator function: multiplication" {
    try expectEvaluates("(*) 4 5", "20");
}

test "evaluates operator function: logical and" {
    try expectEvaluates("(&&) true false", "false");
}

test "evaluates operator function: logical or" {
    try expectEvaluates("(||) true false", "true");
}

test "evaluates operator function: equal" {
    try expectEvaluates("(==) 5 5", "true");
}

test "evaluates operator function: less than" {
    try expectEvaluates("(<) 3 5", "true");
}

test "evaluates operator function: greater than" {
    try expectEvaluates("(>) 5 3", "true");
}

test "evaluates operator function with partial application" {
    try expectEvaluates("add1 = (+) 1; add1 2", "3");
}

test "evaluates operator function with fold" {
    try expectEvaluates("Array = import 'Array'; Array.fold (+) 0 [1, 2, 3, 4]", "10");
}

test "evaluates operator function with map" {
    try expectEvaluates("Array = import 'Array'; Array.map ((+) 1) [1, 2, 3]", "[2, 3, 4]");
}
