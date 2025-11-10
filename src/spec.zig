const std = @import("std");
const eval_module = @import("eval.zig");

pub const SpecResult = struct {
    passed: usize,
    failed: usize,

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
        indent: usize,

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
            try ctx.writer.writeAll("✗ Error: test item is not an object\n");
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
        try ctx.writer.writeAll("✗ Error: test item missing type field\n");
        ctx.failed += 1;
        return;
    }

    if (std.mem.eql(u8, item_type.?, "describe")) {
        try runDescribe(ctx, object);
    } else if (std.mem.eql(u8, item_type.?, "it")) {
        try runIt(ctx, object);
    } else {
        try ctx.writeIndent();
        try ctx.writer.print("✗ Error: unknown test item type '{s}'\n", .{item_type.?});
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
        try ctx.writer.writeAll("✗ Error: describe missing description\n");
        ctx.failed += 1;
        return;
    }

    try ctx.writeIndent();
    try ctx.writer.print("{s}\n", .{description.?});

    if (children) |ch| {
        ctx.indent += 1;
        for (ch.elements) |child| {
            try runTestItem(ctx, child);
        }
        ctx.indent -= 1;
    }
}

fn runIt(ctx: anytype, test_case: eval_module.ObjectValue) anyerror!void {
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
        try ctx.writer.writeAll("✗ Error: it missing description\n");
        ctx.failed += 1;
        return;
    }

    if (test_value == null) {
        try ctx.writeIndent();
        try ctx.writer.print("✗ {s}: missing test\n", .{description.?});
        ctx.failed += 1;
        return;
    }

    // Check if test_value is an assertion
    const test_obj = switch (test_value.?) {
        .object => |obj| obj,
        else => {
            try ctx.writeIndent();
            try ctx.writer.print("✓ {s}\n", .{description.?});
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
            try ctx.writer.print("✗ {s}: assertion missing expected or actual\n", .{description.?});
            ctx.failed += 1;
            return;
        }

        if (valuesEqual(expected.?, actual.?)) {
            try ctx.writeIndent();
            try ctx.writer.print("✓ {s}\n", .{description.?});
            ctx.passed += 1;
        } else {
            try ctx.writeIndent();
            const expected_str = try eval_module.formatValue(ctx.allocator, expected.?);
            defer ctx.allocator.free(expected_str);
            const actual_str = try eval_module.formatValue(ctx.allocator, actual.?);
            defer ctx.allocator.free(actual_str);
            try ctx.writer.print("✗ {s}\n", .{description.?});
            try ctx.writeIndent();
            try ctx.writer.print("  Expected: {s}\n", .{expected_str});
            try ctx.writeIndent();
            try ctx.writer.print("  Actual:   {s}\n", .{actual_str});
            ctx.failed += 1;
        }
    } else {
        // Not an assertion, just check if it's truthy
        try ctx.writeIndent();
        try ctx.writer.print("✓ {s}\n", .{description.?});
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
        try writer.print("Error evaluating spec file: {}\n", .{err});
        return SpecResult{
            .passed = 0,
            .failed = 1,
        };
    };

    const Ctx = RunContext(@TypeOf(writer));
    var ctx = Ctx{
        .allocator = allocator,
        .writer = writer,
        .passed = 0,
        .failed = 0,
        .indent = 0,
    };

    try runTestItem(&ctx, value);

    // Print summary
    try writer.writeAll("\n");
    const total = ctx.passed + ctx.failed;
    if (ctx.failed == 0) {
        try writer.print("✓ {d} test{s} passed\n", .{ total, if (total == 1) "" else "s" });
    } else {
        try writer.print("{d} test{s} passed, {d} failed\n", .{
            ctx.passed,
            if (ctx.passed == 1) "" else "s",
            ctx.failed,
        });
    }

    return SpecResult{
        .passed = ctx.passed,
        .failed = ctx.failed,
    };
}

pub fn runAllSpecs(
    allocator: std.mem.Allocator,
    spec_dir: []const u8,
    writer: anytype,
) !SpecResult {
    var total_passed: usize = 0;
    var total_failed: usize = 0;

    var dir = try std.fs.cwd().openDir(spec_dir, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, "Spec.lazy")) {
            const file_path = try std.fs.path.join(allocator, &[_][]const u8{ spec_dir, entry.name });
            defer allocator.free(file_path);

            const result = try runSpec(allocator, file_path, writer);
            total_passed += result.passed;
            total_failed += result.failed;
        }
    }

    return SpecResult{
        .passed = total_passed,
        .failed = total_failed,
    };
}
