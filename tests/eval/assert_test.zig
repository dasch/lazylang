const std = @import("std");
const common = @import("common.zig");
const eval = @import("evaluator");
const expectEvaluates = common.expectEvaluates;
const testing = std.testing;

// Passing assertions

test "assert with true condition evaluates body" {
    try expectEvaluates(
        \\assert true : "should not fail"
        \\42
    , "42");
}

test "assert with expression condition" {
    try expectEvaluates(
        \\x = 5
        \\assert x > 0 : "x must be positive"
        \\x * 2
    , "10");
}

test "multiple assertions" {
    try expectEvaluates(
        \\x = 5
        \\assert x > 0 : "must be positive"
        \\assert x < 100 : "must be less than 100"
        \\x
    , "5");
}

test "assert in object field value" {
    try expectEvaluates(
        \\port = 8080
        \\config = {
        \\  port:
        \\    assert port > 0 : "port must be positive"
        \\    port
        \\}
        \\config.port
    , "8080");
}

// Failing assertions

test "assert with false condition crashes" {
    var result = try eval.evalInlineWithContext(testing.allocator,
        \\assert false : "assertion failed"
        \\42
    );
    defer result.deinit();
    try testing.expect(result.err != null);
}

test "assert with failing expression crashes" {
    var result = try eval.evalInlineWithContext(testing.allocator,
        \\x = -1
        \\assert x > 0 : "x must be positive"
        \\x
    );
    defer result.deinit();
    try testing.expect(result.err != null);
}
