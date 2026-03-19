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
        "{ x: 10, y: 20 }",
        "{ x: 10, y: 20 }\n"
    );
}

test "empty object" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "{}",
        "{}\n"
    );
}

test "empty array" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "[]",
        "[]\n"
    );
}

test "simple let binding" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "x = 42",
        "x = 42\n"
    );
}

test "operator spacing" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "a+b*c",
        "a + b * c\n"
    );
}

test "string formatting" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "name = \"Alice\"",
        "name = \"Alice\"\n"
    );
}

test "object with inline comment stays multi-line" {
    const allocator = testing.allocator;
    // An object with an inline comment on a field should not collapse to single-line
    try testFormat(allocator,
        "{\n  x: 1 // comment\n}",
        "{\n  x: 1 // comment\n}\n"
    );
}

test "object with inline comment on one of two fields stays multi-line" {
    const allocator = testing.allocator;
    try testFormat(allocator,
        "{\n  x: 1 // comment\n  y: 2\n}",
        "{\n  x: 1 // comment\n  y: 2\n}\n"
    );
}
