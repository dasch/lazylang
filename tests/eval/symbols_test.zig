const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates simple symbol" {
    try expectEvaluates("#foo", "#foo");
}

test "evaluates symbol with underscore" {
    try expectEvaluates("#hello_world", "#hello_world");
}

test "evaluates symbol in tuple" {
    try expectEvaluates("(#ok, 42)", "(#ok, 42)");
}

test "evaluates symbol in array" {
    try expectEvaluates("[#one, #two, #three]", "[#one, #two, #three]");
}

test "evaluates symbol in object" {
    try expectEvaluates("{ status: #active }", "{status: #active}");
}

test "evaluates pattern matching with symbol" {
    try expectEvaluates(
        \\when (#ok, 42) matches
        \\  (#ok, x) then x
    ,
        "42",
    );
}

test "evaluates pattern matching with different symbols" {
    try expectEvaluates(
        \\when (#error, 10) matches
        \\  (#ok, x) then x
        \\  (#error, y) then y
    ,
        "10",
    );
}

test "evaluates pattern matching with symbol as only value" {
    try expectEvaluates(
        \\when #noSuchKey matches
        \\  #ok then 1
        \\  #noSuchKey then 2
    ,
        "2",
    );
}

test "evaluates error handling pattern from README" {
    try expectEvaluates(
        \\result = (#ok, 100)
        \\when result matches
        \\  (#ok, value) then value
        \\  #noSuchKey then 0
    ,
        "100",
    );
}

test "evaluates symbols are case sensitive" {
    try expectEvaluates(
        \\when #OK matches
        \\  #ok then 1
        \\  #OK then 2
    ,
        "2",
    );
}

test "evaluates nested pattern with symbols" {
    try expectEvaluates(
        \\when ((#ok, #success), 42) matches
        \\  ((#ok, #success), x) then x
    ,
        "42",
    );
}
