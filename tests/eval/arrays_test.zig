const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

// Literals

test "evaluates array literals" {
    try expectEvaluates("[1, 2, 3]", "[1, 2, 3]");
}

test "evaluates empty array" {
    try expectEvaluates("[]", "[]");
}

test "evaluates single element array" {
    try expectEvaluates("[42]", "[42]");
}

test "allows newline separated array elements" {
    try expectEvaluates(
        "[\n  1\n  2\n]",
        "[1, 2]",
    );
}

test "evaluates array with mixed types" {
    try expectEvaluates(
        \\[1, "hello", true, null]
    , "[1, \"hello\", true, null]");
}

test "evaluates nested arrays" {
    try expectEvaluates("[[1, 2], [3, 4]]",
        \\[
        \\  [1, 2],
        \\  [3, 4]
        \\]
    );
}

test "evaluates deeply nested arrays" {
    try expectEvaluates("[[[1]]]",
        \\[
        \\  [
        \\    [1]
        \\  ]
        \\]
    );
}

test "evaluates array with expressions" {
    try expectEvaluates("[1 + 2, 3 * 4]", "[3, 12]");
}

test "evaluates array with function calls" {
    try expectEvaluates(
        \\double = x -> x * 2
        \\[double 1, double 2, double 3]
    , "[2, 4, 6]");
}

// Equality

test "evaluates array equality - equal" {
    try expectEvaluates("[1, 2, 3] == [1, 2, 3]", "true");
}

test "evaluates array equality - different values" {
    try expectEvaluates("[1, 2, 3] == [1, 2, 4]", "false");
}

test "evaluates array equality - different lengths" {
    try expectEvaluates("[1, 2] == [1, 2, 3]", "false");
}

test "evaluates array inequality" {
    try expectEvaluates("[1, 2] != [1, 3]", "true");
}

test "evaluates empty array equality" {
    try expectEvaluates("[] == []", "true");
}

// Arrays in data structures

test "evaluates array in object" {
    try expectEvaluates(
        \\{ items: [1, 2, 3] }
    ,
        \\{
        \\  items: [1, 2, 3]
        \\}
    );
}

test "evaluates array in tuple" {
    try expectEvaluates("([1, 2], [3, 4])", "([1, 2], [3, 4])");
}

test "evaluates array of objects" {
    try expectEvaluates(
        \\[{ x: 1 }, { x: 2 }]
    ,
        \\[
        \\  { x: 1 },
        \\  { x: 2 }
        \\]
    );
}

// Array with variable references

test "evaluates array with variable references" {
    try expectEvaluates(
        \\x = 10
        \\y = 20
        \\[x, y, x + y]
    , "[10, 20, 30]");
}

// Array in conditionals

test "evaluates array in if-then-else" {
    try expectEvaluates("if true then [1, 2] else [3, 4]", "[1, 2]");
}

test "evaluates array in pattern matching" {
    try expectEvaluates(
        \\when [1, 2, 3] is
        \\  [a, b, c] then a + b + c
    , "6");
}

// Rest patterns

test "array rest pattern captures remaining elements" {
    try expectEvaluates(
        \\[head, ...tail] = [1, 2, 3, 4]
        \\tail
    , "[2, 3, 4]");
}

test "array rest pattern with single element tail" {
    try expectEvaluates(
        \\[first, ...rest] = [1, 2]
        \\rest
    , "[2]");
}

test "array rest pattern with empty tail" {
    try expectEvaluates(
        \\[only, ...rest] = [42]
        \\rest
    , "[]");
}

test "array rest pattern in function parameter" {
    try expectEvaluates(
        \\head = [x, ...xs] -> x
        \\head [10, 20, 30]
    , "10");
}

test "array rest pattern in when/matches" {
    try expectEvaluates(
        \\when [1, 2, 3, 4] is
        \\  [x, ...rest] then rest
    , "[2, 3, 4]");
}

// Array concatenation

test "array concatenation with ++" {
    try expectEvaluates("[1, 2] ++ [3, 4]", "[1, 2, 3, 4]");
}

test "array concatenation with empty arrays" {
    try expectEvaluates("[] ++ [1, 2]", "[1, 2]");
    try expectEvaluates("[1, 2] ++ []", "[1, 2]");
    try expectEvaluates("[] ++ []", "[]");
}

test "array concatenation chains" {
    try expectEvaluates("[1] ++ [2] ++ [3]", "[1, 2, 3]");
}

test "array rest pattern with literal prefix" {
    try expectEvaluates(
        \\when [1, 2, 3] is
        \\  [1, ...rest] then rest
        \\  otherwise []
    , "[2, 3]");
}

// Array.uniq

test "Array.uniq deduplicates scalar values" {
    try expectEvaluates("Array.uniq [1, 2, 1, 3, 2]", "[1, 2, 3]");
}

test "Array.uniq deduplicates nested arrays" {
    try expectEvaluates("Array.uniq [[1], [1], [2]]",
        \\[
        \\  [1],
        \\  [2]
        \\]
    );
}

test "Array.uniq deduplicates objects" {
    try expectEvaluates("Array.uniq [{ x: 1 }, { x: 1 }, { x: 2 }]",
        \\[
        \\  { x: 1 },
        \\  { x: 2 }
        \\]
    );
}
