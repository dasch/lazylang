const std = @import("std");
const evaluator = @import("evaluator");

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

test "evaluates array literals" {
    try expectEvaluates("[1, 2, 3]", "[1, 2, 3]");
}

test "allows newline separated array elements" {
    try expectEvaluates(
        "[\n  1\n  2\n]",
        "[1, 2]",
    );
}

test "evaluates object literals" {
    try expectEvaluates("{ foo: 1, bar: 2 }", "{foo: 1, bar: 2}");
}

test "allows newline separated object fields" {
    try expectEvaluates(
        "{\n  foo: 1\n  bar: 2\n}",
        "{foo: 1, bar: 2}",
    );
}

test "imports modules from search paths" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makePath("Helpers");
    try tmp_dir.dir.writeFile(.{ .sub_path = "Helpers/ArrayHelpers.lazy", .data = "{ reverse: items -> items }" });

    const module_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(module_path);

    const original_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".");
    defer {
        std.process.changeCurDir(original_dir) catch unreachable;
        std.testing.allocator.free(original_dir);
    }

    std.process.changeCurDir(module_path) catch unreachable;

    try expectEvaluates("import 'Helpers/ArrayHelpers'", "{reverse: <function>}");
}
