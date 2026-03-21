const std = @import("std");
const eval = @import("evaluator");
const testing = std.testing;

test "deep recursion produces UserCrash error instead of segfault" {
    var result = try eval.evalInlineWithContext(testing.allocator,
        \\f = x -> f (x + 1)
        \\f 0
    );
    defer result.deinit();
    try testing.expect(result.err != null);
    try testing.expectEqual(eval.EvalError.UserCrash, result.err.?);
}

test "mutual recursion produces UserCrash error instead of segfault" {
    var result = try eval.evalInlineWithContext(testing.allocator,
        \\f 0
        \\where
        \\  f = x -> g (x + 1)
        \\  g = x -> f (x + 1)
    );
    defer result.deinit();
    try testing.expect(result.err != null);
    try testing.expectEqual(eval.EvalError.UserCrash, result.err.?);
}

test "normal recursion within depth limit succeeds" {
    var result = try eval.evalInlineWithContext(testing.allocator,
        \\fib = n -> if n <= 1 then n else fib (n - 1) + fib (n - 2)
        \\fib 10
    );
    defer result.deinit();
    try testing.expect(result.err == null);
    try testing.expectEqualStrings("55", result.output.?.text);
}
