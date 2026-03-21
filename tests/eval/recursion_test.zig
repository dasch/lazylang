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

test "tail-recursive countdown completes beyond stack depth" {
    // Without TCO this segfaults (Zig stack overflow) around n=375.
    // With TCO the trampoline loop eliminates Zig stack frames for tail calls.
    var result = try eval.evalInlineWithContext(testing.allocator,
        \\count = n ->
        \\  if n == 0 then 0
        \\  else count (n - 1)
        \\count 10000
    );
    defer result.deinit();
    try testing.expect(result.err == null);
    try testing.expectEqualStrings("0", result.output.?.text);
}

test "tail-recursive fibonacci with accumulator completes for large n" {
    // Tail-recursive fib via accumulator — O(n) with TCO.
    // fib 50 0 1 = the 50th Fibonacci number = 12586269025
    var result = try eval.evalInlineWithContext(testing.allocator,
        \\fib = n -> acc1 -> acc2 ->
        \\  if n == 0 then acc1
        \\  else fib (n - 1) acc2 (acc1 + acc2)
        \\fib 50 0 1
    );
    defer result.deinit();
    try testing.expect(result.err == null);
    try testing.expectEqualStrings("12586269025", result.output.?.text);
}
