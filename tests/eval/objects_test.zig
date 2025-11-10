const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates object literals" {
    try expectEvaluates("{ foo: 1, bar: 2 }", "{foo: 1, bar: 2}");
}

test "allows newline separated object fields" {
    try expectEvaluates(
        "{\n  foo: 1\n  bar: 2\n}",
        "{foo: 1, bar: 2}",
    );
}
