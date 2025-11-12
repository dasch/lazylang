const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

// Basic float literal tests

test "float: basic literal" {
    try expectEvaluates("3.14", "3.14");
}

test "float: zero with decimal" {
    try expectEvaluates("0.0", "0");
}

test "float: negative literal" {
    try expectEvaluates("x = 0.0 - 2.5; x", "-2.5");
}

// Arithmetic operations

test "float: addition" {
    try expectEvaluates("3.14 + 2.86", "6");
}

test "float: subtraction" {
    try expectEvaluates("10.5 - 3.2", "7.3");
}

test "float: multiplication" {
    try expectEvaluates("2.5 * 4.0", "10");
}

test "float: mixed integer and float addition" {
    try expectEvaluates("5 + 3.14", "8.14");
}

test "float: mixed integer and float subtraction" {
    try expectEvaluates("10 - 2.5", "7.5");
}

test "float: mixed integer and float multiplication" {
    try expectEvaluates("3 * 2.5", "7.5");
}

// Comparison operations

test "float: less than comparison" {
    try expectEvaluates("3.14 < 3.15", "true");
}

test "float: greater than comparison" {
    try expectEvaluates("3.15 > 3.14", "true");
}

test "float: less or equal comparison" {
    try expectEvaluates("3.14 <= 3.14", "true");
}

test "float: greater or equal comparison" {
    try expectEvaluates("3.15 >= 3.14", "true");
}

test "float: equality comparison" {
    try expectEvaluates("3.14 == 3.14", "true");
}

test "float: inequality comparison" {
    try expectEvaluates("3.14 != 3.15", "true");
}

test "float: mixed integer float comparison" {
    try expectEvaluates("3 < 3.5", "true");
}
