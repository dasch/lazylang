const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates double-quoted strings" {
    try expectEvaluates("\"hello world\"", "\"hello world\"");
}

test "evaluates single-quoted strings" {
    try expectEvaluates("'hello world'", "\"hello world\"");
}
