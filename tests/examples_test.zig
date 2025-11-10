const std = @import("std");
const evaluator = @import("evaluator");

const examples = [_][]const u8{
    "examples/variables.lazy",
    "examples/tuples.lazy",
    "examples/objects.lazy",
    "examples/functions.lazy",
    "examples/conditionals.lazy",
    "examples/destructuring.lazy",
    "examples/pattern_matching.lazy",
};

test "all examples run successfully" {
    for (examples) |example_file| {
        var result = evaluator.evalFile(std.testing.allocator, example_file) catch |err| {
            std.debug.print("Failed to evaluate {s}: {}\n", .{ example_file, err });
            return err;
        };
        defer result.deinit();
    }
}
