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
