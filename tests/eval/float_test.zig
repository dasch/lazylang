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

// Float builtin functions

test "float: round" {
    try expectEvaluates("Float = import 'Float'; Float.round 3.7", "4");
}

test "float: round negative" {
    try expectEvaluates("Float = import 'Float'; Float.round (0.0 - 2.5)", "-3");
}

test "float: floor" {
    try expectEvaluates("Float = import 'Float'; Float.floor 3.7", "3");
}

test "float: floor negative" {
    try expectEvaluates("Float = import 'Float'; Float.floor (0.0 - 2.3)", "-3");
}

test "float: ceil" {
    try expectEvaluates("Float = import 'Float'; Float.ceil 3.2", "4");
}

test "float: ceil negative" {
    try expectEvaluates("Float = import 'Float'; Float.ceil (0.0 - 2.7)", "-2");
}

test "float: abs positive" {
    try expectEvaluates("Float = import 'Float'; Float.abs 5.5", "5.5");
}

test "float: abs negative" {
    try expectEvaluates("Float = import 'Float'; Float.abs (0.0 - 5.5)", "5.5");
}

test "float: sqrt perfect square" {
    try expectEvaluates("Float = import 'Float'; Float.sqrt 16.0", "4");
}

test "float: pow" {
    try expectEvaluates("Float = import 'Float'; Float.pow 2.0 3.0", "8");
}

test "float: mod" {
    try expectEvaluates("Float = import 'Float'; Float.mod 10.5 3.0", "1.5");
}

test "float: rem" {
    try expectEvaluates("Float = import 'Float'; Float.rem 10.5 3.0", "1.5");
}

test "float: rem negative" {
    try expectEvaluates("Float = import 'Float'; Float.rem (0.0 - 10.5) 3.0", "-1.5");
}

// Integer mod and rem functions

test "math: mod integers" {
    try expectEvaluates("Float = import 'Float'; Float.mod 10 3", "1");
}

test "math: rem integers" {
    try expectEvaluates("Float = import 'Float'; Float.rem 10 3", "1");
}

// Pattern matching

test "float: pattern match literal" {
    try expectEvaluates(
        \\x = 3.14
        \\when x matches
        \\  3.14 then #yes
        \\  otherwise #no
    , "#yes");
}

test "float: pattern match failure" {
    try expectEvaluates(
        \\x = 3.14
        \\when x matches
        \\  2.71 then #no
        \\  otherwise #yes
    , "#yes");
}
