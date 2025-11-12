const std = @import("std");
const eval_module = @import("eval.zig");

// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const cyan = "\x1b[36m";
    const dim = "\x1b[2m";
    const bold = "\x1b[1m";
    const grey = "\x1b[90m";
};

pub const SpecResult = struct {
    passed: usize,
    failed: usize,
    ignored: usize,

    pub fn exitCode(self: SpecResult) u8 {
        return if (self.failed == 0) @as(u8, 0) else @as(u8, 1);
    }
};

fn RunContext(comptime WriterType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        writer: WriterType,
        passed: usize,
        failed: usize,
        ignored: usize,
        indent: usize,
        needs_blank_line: bool,

        fn writeIndent(self: *@This()) !void {
            for (0..self.indent) |_| {
                try self.writer.writeAll("  ");
            }
        }
    };
}

fn valuesEqual(a: eval_module.Value, b: eval_module.Value) bool {
    return switch (a) {
        .integer => |av| switch (b) {
            .integer => |bv| av == bv,
            else => false,
        },
        .boolean => |av| switch (b) {
            .boolean => |bv| av == bv,
            else => false,
        },
        .null_value => switch (b) {
            .null_value => true,
            else => false,
        },
        .symbol => |av| switch (b) {
            .symbol => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .string => |av| switch (b) {
            .string => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .function => false, // Functions are not comparable
        .native_fn => false, // Native functions are not comparable
        .array => |av| switch (b) {
            .array => |bv| blk: {
                if (av.elements.len != bv.elements.len) break :blk false;
                for (av.elements, 0..) |elem, i| {
                    if (!valuesEqual(elem, bv.elements[i])) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .tuple => |av| switch (b) {
            .tuple => |bv| blk: {
                if (av.elements.len != bv.elements.len) break :blk false;
                for (av.elements, 0..) |elem, i| {
                    if (!valuesEqual(elem, bv.elements[i])) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |av| switch (b) {
            .object => |bv| blk: {
                if (av.fields.len != bv.fields.len) break :blk false;
                for (av.fields) |afield| {
                    var found = false;
                    for (bv.fields) |bfield| {
                        if (std.mem.eql(u8, afield.key, bfield.key)) {
                            if (!valuesEqual(afield.value, bfield.value)) break :blk false;
                            found = true;
                            break;
                        }
                    }
                    if (!found) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
    };
}

fn runTestItem(ctx: anytype, item: eval_module.Value) anyerror!void {
    const object = switch (item) {
        .object => |obj| obj,
        else => {
            try ctx.writeIndent();
            try ctx.writer.print("{s}✗ Error: test item is not an object{s}\n", .{ Color.red, Color.reset });
            ctx.failed += 1;
            return;
        },
    };

    // Find the type field
    var item_type: ?[]const u8 = null;
    for (object.fields) |field| {
        if (std.mem.eql(u8, field.key, "type")) {
            item_type = switch (field.value) {
                .string => |s| s,
                else => null,
            };
            break;
        }
    }

    if (item_type == null) {
        try ctx.writeIndent();
        try ctx.writer.print("{s}✗ Error: test item missing type field{s}\n", .{ Color.red, Color.reset });
        ctx.failed += 1;
        return;
    }

    if (std.mem.eql(u8, item_type.?, "describe")) {
        try runDescribe(ctx, object);
    } else if (std.mem.eql(u8, item_type.?, "it")) {
        try runIt(ctx, object, false);
    } else if (std.mem.eql(u8, item_type.?, "xit")) {
        try runIt(ctx, object, true);
    } else {
        try ctx.writeIndent();
        try ctx.writer.print("{s}✗ Error: unknown test item type '{s}'{s}\n", .{ Color.red, item_type.?, Color.reset });
        ctx.failed += 1;
    }
}

fn runDescribe(ctx: anytype, desc: eval_module.ObjectValue) anyerror!void {
    // Get description
    var description: ?[]const u8 = null;
    var children: ?eval_module.ArrayValue = null;

    for (desc.fields) |field| {
        if (std.mem.eql(u8, field.key, "description")) {
            description = switch (field.value) {
                .string => |s| s,
                else => null,
            };
        } else if (std.mem.eql(u8, field.key, "children")) {
            children = switch (field.value) {
                .array => |a| a,
                else => null,
            };
        }
    }

    if (description == null) {
        try ctx.writeIndent();
        try ctx.writer.print("{s}✗ Error: describe missing description{s}\n", .{ Color.red, Color.reset });
        ctx.failed += 1;
        return;
    }

    // Add blank line if needed (from de-indenting)
    if (ctx.needs_blank_line) {
        try ctx.writer.writeAll("\n");
        ctx.needs_blank_line = false;
    }

    try ctx.writeIndent();
    try ctx.writer.print("{s}{s}{s}\n", .{ Color.cyan, description.?, Color.reset });

    if (children) |ch| {
        ctx.indent += 1;
        for (ch.elements, 0..) |child, i| {
            // Clear the needs_blank_line flag for children since they're at a deeper level
            if (i == 0) {
                ctx.needs_blank_line = false;
            }

            // Add blank line before sibling describe blocks (but not before the first child)
            if (i > 0) {
                const child_obj = switch (child) {
                    .object => |obj| obj,
                    else => null,
                };
                if (child_obj) |obj| {
                    for (obj.fields) |field| {
                        if (std.mem.eql(u8, field.key, "type")) {
                            const type_val = switch (field.value) {
                                .string => |s| s,
                                else => null,
                            };
                            if (type_val != null and std.mem.eql(u8, type_val.?, "describe")) {
                                try ctx.writer.writeAll("\n");
                                // Clear the flag since we just added the blank line
                                ctx.needs_blank_line = false;
                            }
                            break;
                        }
                    }
                }
            }
            try runTestItem(ctx, child);
        }
        ctx.indent -= 1;
        // Mark that we need a blank line before the next item at this level
        ctx.needs_blank_line = true;
    }
}

fn runIt(ctx: anytype, test_case: eval_module.ObjectValue, is_ignored: bool) anyerror!void {
    // Get description and test expression result
    var description: ?[]const u8 = null;
    var test_value: ?eval_module.Value = null;

    for (test_case.fields) |field| {
        if (std.mem.eql(u8, field.key, "description")) {
            description = switch (field.value) {
                .string => |s| s,
                else => null,
            };
        } else if (std.mem.eql(u8, field.key, "test")) {
            test_value = field.value;
        }
    }

    if (description == null) {
        try ctx.writeIndent();
        try ctx.writer.print("{s}✗ Error: it missing description{s}\n", .{ Color.red, Color.reset });
        ctx.failed += 1;
        return;
    }

    // If the test is ignored (xit), just display it and return
    if (is_ignored) {
        try ctx.writeIndent();
        try ctx.writer.print("{s}○ {s}{s}\n", .{ Color.grey, description.?, Color.reset });
        ctx.ignored += 1;
        return;
    }

    if (test_value == null) {
        try ctx.writeIndent();
        try ctx.writer.print("{s}✗ {s}: missing test{s}\n", .{ Color.red, description.?, Color.reset });
        ctx.failed += 1;
        return;
    }

    // Check if test_value is an assertion
    const test_obj = switch (test_value.?) {
        .object => |obj| obj,
        else => {
            try ctx.writeIndent();
            try ctx.writer.print("{s}✓{s} {s}\n", .{ Color.green, Color.reset, description.? });
            ctx.passed += 1;
            return;
        },
    };

    // Check if it's an assertion object
    var is_assertion = false;
    var expected: ?eval_module.Value = null;
    var actual: ?eval_module.Value = null;

    for (test_obj.fields) |field| {
        if (std.mem.eql(u8, field.key, "type")) {
            const type_val = switch (field.value) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, type_val, "assertion")) {
                is_assertion = true;
            }
        } else if (std.mem.eql(u8, field.key, "expected")) {
            expected = field.value;
        } else if (std.mem.eql(u8, field.key, "actual")) {
            actual = field.value;
        }
    }

    if (is_assertion) {
        if (expected == null or actual == null) {
            try ctx.writeIndent();
            try ctx.writer.print("{s}✗ {s}: assertion missing expected or actual{s}\n", .{ Color.red, description.?, Color.reset });
            ctx.failed += 1;
            return;
        }

        if (valuesEqual(expected.?, actual.?)) {
            try ctx.writeIndent();
            try ctx.writer.print("{s}✓{s} {s}\n", .{ Color.green, Color.reset, description.? });
            ctx.passed += 1;
        } else {
            try ctx.writeIndent();
            const expected_str = try eval_module.formatValue(ctx.allocator, expected.?);
            defer ctx.allocator.free(expected_str);
            const actual_str = try eval_module.formatValue(ctx.allocator, actual.?);
            defer ctx.allocator.free(actual_str);
            try ctx.writer.print("{s}✗ {s}{s}\n", .{ Color.red, description.?, Color.reset });
            try ctx.writeIndent();
            try ctx.writer.print("{s}  Expected: {s}{s}\n", .{ Color.dim, expected_str, Color.reset });
            try ctx.writeIndent();
            try ctx.writer.print("{s}  Actual:   {s}{s}\n", .{ Color.dim, actual_str, Color.reset });
            ctx.failed += 1;
        }
    } else {
        // Not an assertion, just check if it's truthy
        try ctx.writeIndent();
        try ctx.writer.print("{s}✓{s} {s}\n", .{ Color.green, Color.reset, description.? });
        ctx.passed += 1;
    }
}

pub fn runSpec(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    writer: anytype,
) !SpecResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Evaluate the spec file
    const value = eval_module.evalFileValue(arena.allocator(), allocator, file_path) catch |err| {
        // Extract just the filename or relative path for display
        const display_path = if (std.mem.lastIndexOf(u8, file_path, "spec/")) |idx|
            file_path[idx..]
        else if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |idx|
            file_path[idx + 1 ..]
        else
            file_path;

        try writer.print("{s}{s} failed with a syntax error: {s}{}{s}\n", .{
            Color.red,
            display_path,
            Color.dim,
            err,
            Color.reset,
        });
        return SpecResult{
            .passed = 0,
            .failed = 1,
            .ignored = 0,
        };
    };

    const Ctx = RunContext(@TypeOf(writer));
    var ctx = Ctx{
        .allocator = allocator,
        .writer = writer,
        .passed = 0,
        .failed = 0,
        .ignored = 0,
        .indent = 0,
        .needs_blank_line = false,
    };

    try runTestItem(&ctx, value);

    return SpecResult{
        .passed = ctx.passed,
        .failed = ctx.failed,
        .ignored = ctx.ignored,
    };
}

fn runAllSpecsRecursive(
    allocator: std.mem.Allocator,
    spec_dir: []const u8,
    writer: anytype,
    total_passed: *usize,
    total_failed: *usize,
    total_ignored: *usize,
    first_file: *bool,
) !void {
    var dir = try std.fs.cwd().openDir(spec_dir, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ spec_dir, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, "Spec.lazy")) {
            // Add blank line between test files
            if (!first_file.*) {
                try writer.writeAll("\n");
            }
            first_file.* = false;

            const result = try runSpec(allocator, full_path, writer);
            total_passed.* += result.passed;
            total_failed.* += result.failed;
            total_ignored.* += result.ignored;
        } else if (entry.kind == .directory) {
            // Recursively search subdirectories
            try runAllSpecsRecursive(allocator, full_path, writer, total_passed, total_failed, total_ignored, first_file);
        }
    }
}

pub fn runAllSpecs(
    allocator: std.mem.Allocator,
    spec_dir: []const u8,
    writer: anytype,
) !SpecResult {
    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var total_ignored: usize = 0;
    var first_file = true;

    try runAllSpecsRecursive(allocator, spec_dir, writer, &total_passed, &total_failed, &total_ignored, &first_file);

    // Print summary
    try writer.writeAll("\n");
    const total = total_passed + total_failed;
    if (total_failed == 0) {
        try writer.print("{s}{s}✓ {d} test{s} passed{s}", .{ Color.bold, Color.green, total, if (total == 1) "" else "s", Color.reset });
        if (total_ignored > 0) {
            try writer.print(", {s}{d} ignored{s}", .{ Color.grey, total_ignored, Color.reset });
        }
        try writer.writeAll("\n");
    } else {
        try writer.print("{s}{s}{d}{s} test{s} passed, {s}{d} failed{s}", .{
            Color.bold,
            Color.green,
            total_passed,
            Color.reset,
            if (total_passed == 1) "" else "s",
            Color.red,
            total_failed,
            Color.reset,
        });
        if (total_ignored > 0) {
            try writer.print(", {s}{d} ignored{s}", .{ Color.grey, total_ignored, Color.reset });
        }
        try writer.writeAll("\n");
    }

    return SpecResult{
        .passed = total_passed,
        .failed = total_failed,
        .ignored = total_ignored,
    };
}
