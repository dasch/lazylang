const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

// Basic array comprehensions
test "evaluates simple array comprehension" {
    try expectEvaluates(
        "[x for x in [1, 2, 3]]",
        "[1, 2, 3]",
    );
}

test "evaluates array comprehension with transformation" {
    try expectEvaluates(
        "[x + 1 for x in [1, 2, 3]]",
        "[2, 3, 4]",
    );
}

test "evaluates array comprehension with when filter" {
    try expectEvaluates(
        \\[x for x in [true, false, true] when x]
    ,
        "[true, true]",
    );
}

test "evaluates array comprehension with multiple for clauses" {
    try expectEvaluates(
        "[x + y for x in [1, 2] for y in [10, 20]]",
        "[11, 21, 12, 22]",
    );
}

test "evaluates array comprehension with multiple for clauses and filter" {
    try expectEvaluates(
        "[(x, y, z) for x in [1, 2] for y in [10, 20] for z in [true, false] when z]",
        \\[
        \\  (1, 10, true),
        \\  (1, 20, true),
        \\  (2, 10, true),
        \\  (2, 20, true)
        \\]
    ,
    );
}

test "evaluates nested array comprehension" {
    try expectEvaluates(
        "[[x + y for y in [1, 2]] for x in [10, 20]]",
        \\[
        \\  [11, 12],
        \\  [21, 22]
        \\]
    ,
    );
}

test "evaluates array comprehension with destructuring" {
    try expectEvaluates(
        "[x + y for (x, y) in [(1, 10), (2, 20), (3, 30)]]",
        "[11, 22, 33]",
    );
}

// Basic object comprehensions
test "evaluates simple object comprehension from array" {
    try expectEvaluates(
        \\names = ["Alice", "Bob", "Charlie"]
        \\{ [name]: 1 for name in names }
    ,
        "{ Alice: 1, Bob: 1, Charlie: 1 }",
    );
}

test "evaluates object comprehension with transformation" {
    try expectEvaluates(
        \\{ [x]: x + 1 for x in [1, 2, 3] }
    ,
        "{ 1: 2, 2: 3, 3: 4 }",
    );
}

test "evaluates object comprehension from object" {
    try expectEvaluates(
        \\obj = { a: 1, b: 2, c: 3 }
        \\{ [key]: value + 10 for (key, value) in obj }
    ,
        "{ a: 11, b: 12, c: 13 }",
    );
}

test "evaluates object comprehension with when filter" {
    try expectEvaluates(
        \\{ [x]: y for (x, y) in [("a", true), ("b", false), ("c", true)] when y }
    ,
        "{ a: true, c: true }",
    );
}

test "evaluates object comprehension with multiple for clauses" {
    try expectEvaluates(
        \\{ [x + y]: x for x in [1, 2] for y in [10, 20] }
    ,
        \\{
        \\  11: 1,
        \\  21: 1,
        \\  12: 2,
        \\  22: 2
        \\}
    ,
    );
}

// Empty comprehensions
test "evaluates empty array comprehension" {
    try expectEvaluates(
        "[x for x in []]",
        "[]",
    );
}

test "evaluates array comprehension that filters everything" {
    try expectEvaluates(
        "[x for x in [1, 2, 3] when false]",
        "[]",
    );
}

test "evaluates empty object comprehension" {
    try expectEvaluates(
        "{ [x]: x for x in [] }",
        "{}",
    );
}
