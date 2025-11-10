const std = @import("std");
const evaluator = @import("../src/eval.zig");

fn expectEvaluates(source: []const u8, expected: []const u8) !void {
    var result = try evaluator.evalInline(std.testing.allocator, source);
    defer result.deinit();
    try std.testing.expectEqualStrings(expected, result.text);
}

test "evaluates arithmetic expressions" {
    try expectEvaluates("1 + 2 * 3", "7");
}

test "evaluates parentheses" {
    try expectEvaluates("(1 + 2) * 3", "9");
}

test "evaluates lambda application" {
    try expectEvaluates("(x -> x + 1) 41", "42");
}

test "supports higher order functions" {
    try expectEvaluates("(a -> b -> a + b) 2 3", "5");
}
