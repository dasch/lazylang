const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates do with simple expression" {
    try expectEvaluates("(x -> x + 1) do 5", "6");
}

test "evaluates do with variable bindings" {
    try expectEvaluates("(x -> x) do y = 5; y + 1", "6");
}

test "evaluates do with multiple variable bindings" {
    try expectEvaluates("(x -> x) do a = 1; b = 2; a + b", "3");
}

test "evaluates do with curried functions" {
    try expectEvaluates("f = a -> b -> a + b; f 10 do x = 5; x", "15");
}

test "evaluates do with newline-separated bindings" {
    try expectEvaluates(
        \\f = x -> x + 1
        \\f do
        \\  y = 10
        \\  y * 2
    ,
        "21",
    );
}

test "evaluates do as alternative to parentheses" {
    try expectEvaluates("(x -> x) do 42", "42");
    try expectEvaluates("(x -> x) (42)", "42");
}

test "evaluates do with complex expression" {
    try expectEvaluates("f = x -> x * 2; f do a = 5; b = 3; a + b", "16");
}

test "evaluates do with nested bindings" {
    try expectEvaluates(
        \\apply = f -> f
        \\apply do
        \\  x = 10
        \\  y = x + 5
        \\  x + y
    ,
        "25",
    );
}
