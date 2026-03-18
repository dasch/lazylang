const std = @import("std");
const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

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

    try expectEvaluates("import 'Helpers/ArrayHelpers'", "{ reverse: <function> }");
}

test "imports stdlib module Array" {
    try expectEvaluates(
        \\Array = import 'Array'
        \\Array.length [1, 2, 3]
    , "3");
}

test "imports stdlib module String" {
    try expectEvaluates(
        \\String = import 'String'
        \\String.toUpperCase "hello"
    , "\"HELLO\"");
}

test "imports module and uses destructuring" {
    try expectEvaluates(
        \\{ length } = import 'Array'
        \\length [1, 2, 3]
    , "3");
}

test "imports same module twice" {
    try expectEvaluates(
        \\A1 = import 'Array'
        \\A2 = import 'Array'
        \\(A1.length [1, 2]) == (A2.length [1, 2])
    , "true");
}

test "imports module returning simple value" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "Config.lazy", .data = "42" });

    const module_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(module_path);

    const original_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".");
    defer {
        std.process.changeCurDir(original_dir) catch unreachable;
        std.testing.allocator.free(original_dir);
    }

    std.process.changeCurDir(module_path) catch unreachable;

    try expectEvaluates("import 'Config'", "42");
}

test "imports module with .lazy extension" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "Mod.lazy", .data = "99" });

    const module_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(module_path);

    const original_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".");
    defer {
        std.process.changeCurDir(original_dir) catch unreachable;
        std.testing.allocator.free(original_dir);
    }

    std.process.changeCurDir(module_path) catch unreachable;

    try expectEvaluates("import 'Mod.lazy'", "99");
}

test "imports module returning array" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{ .sub_path = "Items.lazy", .data = "[1, 2, 3]" });

    const module_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(module_path);

    const original_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".");
    defer {
        std.process.changeCurDir(original_dir) catch unreachable;
        std.testing.allocator.free(original_dir);
    }

    std.process.changeCurDir(module_path) catch unreachable;

    try expectEvaluates("import 'Items'", "[1, 2, 3]");
}
