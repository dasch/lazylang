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

// Multi-line application

test "multi-line application with indented arguments" {
    try expectEvaluates(
        \\add = a -> b -> a + b
        \\add
        \\  1
        \\  2
    , "3");
}

test "multi-line application with parenthesized lambda" {
    try expectEvaluates(
        \\Array = import 'Array'
        \\Array.fold
        \\  (acc -> x -> acc + x)
        \\  0
        \\  [1, 2, 3]
    , "6");
}

test "multi-line application in let binding" {
    try expectEvaluates(
        \\add = a -> b -> a + b
        \\result =
        \\  add
        \\    1
        \\    2
        \\result
    , "3");
}

test "separate let bindings are not treated as application" {
    try expectEvaluates(
        \\a = 10
        \\b = 20
        \\a + b
    , "30");
}

// Pipeline lambda bodies

test "pipeline with simple lambda" {
    try expectEvaluates("10 \\ x -> x * 2", "20");
}

test "pipeline with chained lambdas" {
    try expectEvaluates("10 \\ x -> x * 2 \\ x -> x + 5", "25");
}

test "pipeline lambda with let-binding body" {
    try expectEvaluates(
        \\10 \ x -> y = x * 2; y + 1
    , "21");
}

test "pipeline lambda with where clause" {
    try expectEvaluates(
        \\10 \ a -> b where b = a * 2
    , "20");
}

test "multi-line pipeline with lambdas" {
    try expectEvaluates(
        \\result = 10
        \\  \ x -> x * 2
        \\  \ x -> x + 5
        \\result
    , "25");
}

// Operator sections

test "right section: comparison" {
    try expectEvaluates("(> 10) 42", "true");
}

test "right section: comparison false" {
    try expectEvaluates("(> 100) 42", "false");
}

test "right section: arithmetic" {
    try expectEvaluates("(+ 1) 41", "42");
}

test "right section: multiply" {
    try expectEvaluates("(* 2) 21", "42");
}

test "right section: equality" {
    try expectEvaluates("(== 42) 42", "true");
}

test "right section with matches" {
    try expectEvaluates(
        \\when 42 matches
        \\  (> 100) then "big"
        \\  (> 10) then "medium"
        \\  otherwise "small"
    , "\"medium\"");
}

test "right section with Array.filter" {
    try expectEvaluates(
        \\Array = import "Array"
        \\Array.filter (> 3) [1, 2, 3, 4, 5]
    , "[4, 5]");
}

test "right section with Array.map" {
    try expectEvaluates(
        \\Array = import "Array"
        \\Array.map (* 2) [1, 2, 3]
    , "[2, 4, 6]");
}

test "negative literal in parens is not a section" {
    try expectEvaluates("(-1)", "-1");
}
