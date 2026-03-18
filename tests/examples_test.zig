const std = @import("std");
const evaluator = @import("evaluator");

const skip_examples = [_][]const u8{
    // These examples have known issues (missing stdlib functions)
    "property_test_demo.lazy",
    "random_demo.lazy",
    // Returns a function, not useful to golden-file
    "hello.lazy",
};

fn isSkipped(name: []const u8) bool {
    for (skip_examples) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

test "all examples run successfully and produce expected output" {
    var dir = std.fs.cwd().openDir("examples", .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open examples directory: {}\n", .{err});
        return error.TestUnexpectedResult;
    };
    defer dir.close();

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".lazy")) continue;
        if (isSkipped(entry.name)) continue;

        const example_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ "examples", entry.name });
        defer std.testing.allocator.free(example_path);

        // Evaluate the example
        var result = evaluator.evalFile(std.testing.allocator, example_path) catch |err| {
            std.debug.print("Failed to evaluate {s}: {}\n", .{ example_path, err });
            return err;
        };
        defer result.deinit();

        // Check golden output if available
        const base_name = entry.name[0 .. entry.name.len - 5]; // strip .lazy
        const expected_path = try std.fmt.allocPrint(std.testing.allocator, "tests/fixtures/examples/{s}.expected", .{base_name});
        defer std.testing.allocator.free(expected_path);

        if (std.fs.cwd().openFile(expected_path, .{})) |file| {
            defer file.close();
            const expected = try file.readToEndAlloc(std.testing.allocator, 1024 * 1024);
            defer std.testing.allocator.free(expected);

            // Trim trailing newline from golden file
            const trimmed_expected = std.mem.trimRight(u8, expected, "\n");

            if (!std.mem.eql(u8, result.text, trimmed_expected)) {
                std.debug.print("\n\x1b[1;31m✗ Example output mismatch: {s}\x1b[0m\n", .{example_path});
                std.debug.print("\nExpected:\n{s}\n", .{trimmed_expected});
                std.debug.print("\nActual:\n{s}\n", .{result.text});
                return error.TestUnexpectedResult;
            }
        } else |_| {
            // No golden file — just ensure it doesn't crash (already validated above)
        }

        count += 1;
    }

    // Ensure we found examples
    try std.testing.expect(count > 0);
}
