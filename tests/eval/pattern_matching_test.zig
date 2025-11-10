const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates when matches with tuple pattern" {
    try expectEvaluates(
        \\when (1, 2) matches
        \\  (x, y) then x + y
    ,
        "3",
    );
}

test "evaluates when matches with multiple patterns" {
    try expectEvaluates(
        \\value = [1, 2, 3]
        \\when value matches
        \\  (x, y) then x + y
        \\  [a, b, c] then a + b + c
    ,
        "6",
    );
}

test "evaluates when matches with otherwise" {
    try expectEvaluates(
        \\value = 42
        \\when value matches
        \\  (x, y) then x + y
        \\  otherwise 100
    ,
        "100",
    );
}

test "evaluates when matches with array pattern" {
    try expectEvaluates(
        \\when [1, 2, 3] matches
        \\  [a, b, c] then a + b + c
    ,
        "6",
    );
}

test "evaluates when matches with object pattern" {
    try expectEvaluates(
        \\when { x: 10, y: 20 } matches
        \\  { x, y } then x + y
    ,
        "30",
    );
}

test "evaluates when matches with nested pattern" {
    try expectEvaluates(
        \\when (1, (2, 3)) matches
        \\  (a, (b, c)) then a + b + c
    ,
        "6",
    );
}

test "evaluates when matches selecting first match" {
    try expectEvaluates(
        \\when (5, 10) matches
        \\  (a, b) then a + b
        \\  (x, y) then x * y
    ,
        "15",
    );
}

test "evaluates when matches with literal number in tuple pattern" {
    try expectEvaluates(
        \\when (1, 2) matches
        \\  (0, x) then x
        \\  (1, y) then y + 10
    ,
        "12",
    );
}

test "evaluates when matches with literal string in tuple pattern" {
    try expectEvaluates(
        \\when ("ok", 42) matches
        \\  ("error", msg) then msg
        \\  ("ok", value) then value
    ,
        "42",
    );
}

test "evaluates when matches with literal in object pattern" {
    try expectEvaluates(
        \\obj = { status: "ok", payload: 100 }
        \\when obj matches
        \\  { status: "error" } then 0
        \\  { status: "ok", payload } then payload
    ,
        "100",
    );
}

test "evaluates when matches with boolean literal" {
    try expectEvaluates(
        \\when (true, 5) matches
        \\  (false, x) then x
        \\  (true, y) then y + 10
    ,
        "15",
    );
}

test "evaluates when matches with null literal" {
    try expectEvaluates(
        \\when (null, 42) matches
        \\  (null, x) then x
        \\  (y, z) then y + z
    ,
        "42",
    );
}

test "evaluates when matches with mixed literals" {
    try expectEvaluates(
        \\when (1, "test", true) matches
        \\  (1, "test", flag) then flag
        \\  (x, y, z) then false
    ,
        "true",
    );
}
