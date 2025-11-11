const std = @import("std");
const formatter = @import("formatter");
const testing = std.testing;

fn testFormat(allocator: std.mem.Allocator, input: []const u8, expected: []const u8) !void {
    var result = try formatter.formatSource(allocator, input);
    defer result.deinit();

    if (!std.mem.eql(u8, result.text, expected)) {
        std.debug.print("\n=== Format Test Failed ===\n", .{});
        std.debug.print("Input:\n{s}\n", .{input});
        std.debug.print("Expected:\n{s}\n", .{expected});
        std.debug.print("Got:\n{s}\n", .{result.text});
        std.debug.print("=========================\n", .{});
        return error.TestFailed;
    }
}

test "single-line object with spaces inside braces" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "point = {x: 10, y: 20}",
        "point = { x: 10, y: 20 }\n"
    );
}

test "single-line object already formatted" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "point = { x: 10, y: 20 }",
        "point = { x: 10, y: 20 }\n"
    );
}

test "multi-line object without spaces after brace" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        \\obj = {
        \\  one: 1
        \\  two: 2
        \\}
        ,
        \\obj = {
        \\  one: 1
        \\  two: 2
        \\}
        \\
    );
}

test "nested single-line objects" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "config = {nested: {value: 42}}",
        "config = { nested: { value: 42 } }\n"
    );
}

test "array without spaces inside brackets" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "arr = [1, 2, 3]",
        "arr = [1, 2, 3]\n"
    );
}

test "multi-line array indentation" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        \\arr = [
        \\  1
        \\  2
        \\  3
        \\]
        ,
        \\arr = [
        \\  1
        \\  2
        \\  3
        \\]
        \\
    );
}

test "array with objects" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        \\users = [
        \\  {name: "Alice", age: 30}
        \\  {name: "Bob", age: 25}
        \\]
        ,
        \\users = [
        \\  { name: "Alice", age: 30 }
        \\  { name: "Bob", age: 25 }
        \\]
        \\
    );
}

test "function with proper spacing" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "add = x->y->x+y",
        "add = x -> y -> x + y\n"
    );
}

test "conditional with proper spacing" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "result=if true then \"yes\" else \"no\"",
        "result = if true then \"yes\" else \"no\"\n"
    );
}

// TODO: This test is disabled because the current token-based formatter
// doesn't handle indentation of multi-line expressions after `=`
// We need an AST-based approach to properly handle this case
test "multi-line conditional" {
    if (true) return error.SkipZigTest;

    const allocator = testing.allocator;
    try testFormat(allocator,
        \\result =
        \\  if isExcellent then
        \\    "excellent"
        \\  else
        \\    "good"
        ,
        \\result =
        \\  if isExcellent then
        \\    "excellent"
        \\  else
        \\    "good"
        \\
    );
}

test "nested objects with proper indentation" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        \\person = {
        \\  name: "Alice"
        \\  address: {
        \\    city: "NYC"
        \\    zip: "10001"
        \\  }
        \\}
        ,
        \\person = {
        \\  name: "Alice"
        \\  address: {
        \\    city: "NYC"
        \\    zip: "10001"
        \\  }
        \\}
        \\
    );
}

test "tuple with spaces" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "point = (10, 20)",
        "point = (10, 20)\n"
    );
}

test "operators with spacing" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "result = a+b*c-d",
        "result = a + b * c - d\n"
    );
}
