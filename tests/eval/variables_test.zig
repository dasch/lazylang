const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates variable assignment with semicolon" {
    try expectEvaluates("x = 42; x", "42");
}

test "evaluates multiple variable assignments with semicolons" {
    try expectEvaluates("x = 1; y = 2; x + y", "3");
}

test "evaluates variable assignment with newlines" {
    try expectEvaluates("x = 42\nx", "42");
}

test "evaluates multiple variable assignments with newlines" {
    try expectEvaluates(
        \\x = 1
        \\y = 2
        \\x + y
    ,
        "3",
    );
}

test "evaluates variable shadowing" {
    try expectEvaluates("x = 1; x = 2; x", "2");
}

test "evaluates nested variable scopes" {
    try expectEvaluates("x = 1; y = (z = 2; z + 1); x + y", "4");
}

test "evaluates nested scopes with indentation" {
    try expectEvaluates(
        \\x =
        \\  x1 = 1
        \\  x2 = 2
        \\  x1 + x2
        \\y = 3
        \\x + y
    ,
        "6",
    );
}
