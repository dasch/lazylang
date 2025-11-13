const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "array element with trailing if - true condition" {
    try expectEvaluates(
        \\enabled = true
        \\[1, 2 if enabled, 3]
        ,
        "[1, 2, 3]",
    );
}

test "array element with trailing if - false condition" {
    try expectEvaluates(
        \\enabled = false
        \\[1, 2 if enabled, 3]
        ,
        "[1, 3]",
    );
}

test "array element with trailing unless - true condition" {
    try expectEvaluates(
        \\isDevelopment = true
        \\[1, 2 unless isDevelopment, 3]
        ,
        "[1, 3]",
    );
}

test "array element with trailing unless - false condition" {
    try expectEvaluates(
        \\isDevelopment = false
        \\[1, 2 unless isDevelopment, 3]
        ,
        "[1, 2, 3]",
    );
}

test "multiple conditional elements" {
    try expectEvaluates(
        \\a = true
        \\b = false
        \\c = true
        \\[1 if a, 2 if b, 3 if c]
        ,
        "[1, 3]",
    );
}

test "conditional elements with expressions" {
    try expectEvaluates(
        \\x = 5
        \\[1, x * 2 if x > 3, 10]
        ,
        "[1, 10, 10]",
    );
}

test "conditional elements with complex expressions" {
    try expectEvaluates(
        \\env = "production"
        \\["debug" unless env == "production", "release"]
        ,
        "[\"release\"]",
    );
}

test "conditional elements on newlines" {
    try expectEvaluates(
        \\enabled = true
        \\disabled = false
        \\[
        \\  1
        \\  2 if enabled
        \\  3 if disabled
        \\  4
        \\]
        ,
        "[1, 2, 4]",
    );
}

test "all elements filtered out" {
    try expectEvaluates(
        \\enabled = false
        \\[1 if enabled, 2 if enabled]
        ,
        "[]",
    );
}

test "conditional element with function call" {
    try expectEvaluates(
        \\enabled = true
        \\double = x -> x * 2
        \\[double 5 if enabled]
        ,
        "[10]",
    );
}
