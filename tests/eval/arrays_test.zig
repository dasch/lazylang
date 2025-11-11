const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates array literals" {
    try expectEvaluates("[1, 2, 3]", "[1, 2, 3]");
}

test "allows newline separated array elements" {
    try expectEvaluates(
        "[\n  1\n  2\n]",
        "[1, 2]",
    );
}

test "Array.get returns ok tuple when index is valid" {
    try expectEvaluates(
        \\{ get } = import 'Array'
        \\get 1 [10, 20, 30]
    ,
        "(#ok, 20)",
    );
}

test "Array.get returns ok tuple for first element" {
    try expectEvaluates(
        \\{ get } = import 'Array'
        \\get 0 [10, 20, 30]
    ,
        "(#ok, 10)",
    );
}

test "Array.get returns outOfBounds tag when index is at length" {
    try expectEvaluates(
        \\{ get } = import 'Array'
        \\get 3 [10, 20, 30]
    ,
        "#outOfBounds",
    );
}

test "Array.get returns outOfBounds tag when index is beyond length" {
    try expectEvaluates(
        \\{ get } = import 'Array'
        \\arr = [10, 20, 30]
        \\get 10 arr
    ,
        "#outOfBounds",
    );
}
