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

pub const SpecFilter = struct {
    description: []const u8,
    is_describe: bool, // true if filtering a describe block, false if filtering a single test
};

// Find the test or describe block at the given line in the source file
pub fn findTestAtLine(allocator: std.mem.Allocator, file_path: []const u8, target_line: usize) !?SpecFilter {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // Max 1MB
    defer allocator.free(content);

    // Count total lines and build an array
    var line_count: usize = 0;
    var temp_iter = std.mem.splitScalar(u8, content, '\n');
    while (temp_iter.next()) |_| {
        line_count += 1;
    }

    if (target_line == 0 or target_line > line_count) {
        return null;
    }

    // Collect lines up to target line
    var line_buffer = std.ArrayList([]const u8){};
    defer line_buffer.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_line: usize = 0;

    while (lines.next()) |line| {
        try line_buffer.append(allocator, line);
        current_line += 1;
        if (current_line >= target_line) break;
    }

    // Search backwards from target_line to find a test definition
    var line_idx = target_line - 1; // Convert to 0-indexed
    while (line_idx > 0) : (line_idx -= 1) {
        const line = line_buffer.items[line_idx];
        const trimmed = std.mem.trim(u8, line, " \t");

        // Look for "it ", "xit ", or "describe " followed by a string
        const test_types = [_][]const u8{ "it ", "xit ", "describe " };
        for (test_types) |test_type| {
            if (std.mem.startsWith(u8, trimmed, test_type)) {
                const after_keyword = trimmed[test_type.len..];
                // Extract string literal (assuming format: keyword "description" ...)
                if (std.mem.indexOfScalar(u8, after_keyword, '"')) |start_quote| {
                    if (std.mem.indexOfScalar(u8, after_keyword[start_quote + 1 ..], '"')) |end_quote| {
                        const description = after_keyword[start_quote + 1 .. start_quote + 1 + end_quote];
                        const owned_desc = try allocator.dupe(u8, description);
                        return SpecFilter{
                            .description = owned_desc,
                            .is_describe = std.mem.eql(u8, test_type, "describe "),
                        };
                    }
                }
            }
        }

        if (line_idx == 0) break;
    }

    return null;
}

fn RunContext(comptime WriterType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        writer: WriterType,
        passed: usize,
        failed: usize,
        ignored: usize,
        indent: usize,
        needs_blank_line: bool,
        filter: ?SpecFilter,
        current_describe_stack: std.ArrayList([]const u8),

        fn writeIndent(self: *@This()) !void {
            for (0..self.indent) |_| {
                try self.writer.writeAll("  ");
            }
        }

        fn matchesFilter(self: *@This(), description: []const u8, is_describe: bool) bool {
            if (self.filter == null) return true;

            const filter = self.filter.?;

            // If filtering for a describe block
            if (filter.is_describe) {
                // Check if we're inside the target describe block
                for (self.current_describe_stack.items) |desc| {
                    if (std.mem.eql(u8, desc, filter.description)) {
                        return true;
                    }
                }
                // Or if this is the target describe block itself
                if (is_describe and std.mem.eql(u8, description, filter.description)) {
                    return true;
                }
                return false;
            } else {
                // Filtering for a single test - exact match on description
                return !is_describe and std.mem.eql(u8, description, filter.description);
            }
        }
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

    // Check if this describe block should be included based on filter
    const should_display = ctx.matchesFilter(description.?, true);

    // Always push to stack for nested filter checks
    try ctx.current_describe_stack.append(ctx.allocator, description.?);
    defer _ = ctx.current_describe_stack.pop();

    // Decide if we should process children:
    // - If no filter, always process
    // - If there's a filter, always descend (we might find the target inside)
    // We'll filter at the leaf level (individual tests or target describe)
    const should_run_children = children != null and
        (ctx.filter == null or ctx.filter != null); // Always descend when there's a filter

    if (should_run_children and should_display) {
        // Add blank line if needed (from de-indenting)
        if (ctx.needs_blank_line) {
            try ctx.writer.writeAll("\n");
            ctx.needs_blank_line = false;
        }

        try ctx.writeIndent();
        try ctx.writer.print("{s}{s}{s}\n", .{ Color.cyan, description.?, Color.reset });
    }

    if (should_run_children) {
        const ch = children.?;
        const should_indent = should_display;

        if (should_indent) {
            ctx.indent += 1;
        }

        for (ch.elements, 0..) |child, i| {
            // Clear the needs_blank_line flag for children since they're at a deeper level
            if (i == 0) {
                ctx.needs_blank_line = false;
            }

            // Add blank line before sibling describe blocks (but not before the first child)
            if (i > 0 and should_display) {
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

        if (should_indent) {
            ctx.indent -= 1;
        }

        // Mark that we need a blank line before the next item at this level
        if (should_display) {
            ctx.needs_blank_line = true;
        }
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

    // Check if this test matches the filter
    if (!ctx.matchesFilter(description.?, false)) {
        return; // Skip this test
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

    // Parse the test object type and fields
    var test_type: ?[]const u8 = null;
    var fail_details: ?eval_module.Value = null;

    for (test_obj.fields) |field| {
        if (std.mem.eql(u8, field.key, "type")) {
            test_type = switch (field.value) {
                .string => |s| s,
                else => null,
            };
        } else if (std.mem.eql(u8, field.key, "details")) {
            fail_details = field.value;
        }
    }

    // Handle explicit pass
    if (test_type != null and std.mem.eql(u8, test_type.?, "pass")) {
        try ctx.writeIndent();
        try ctx.writer.print("{s}✓{s} {s}\n", .{ Color.green, Color.reset, description.? });
        ctx.passed += 1;
        return;
    }

    // Handle explicit fail
    if (test_type != null and std.mem.eql(u8, test_type.?, "fail")) {
        try ctx.writeIndent();
        try ctx.writer.print("{s}✗ {s}{s}\n", .{ Color.red, description.?, Color.reset });

        // Handle fail details (can be a string or an object with structured info)
        if (fail_details) |details| {
            switch (details) {
                .string => |msg| {
                    // Simple string message
                    try ctx.writeIndent();
                    try ctx.writer.print("{s}  {s}{s}\n", .{ Color.dim, msg, Color.reset });
                },
                .object => |obj| {
                    // Structured failure details with kind, expected, actual, condition
                    var fail_kind: ?[]const u8 = null;
                    var fail_expected: ?eval_module.Value = null;
                    var fail_actual: ?eval_module.Value = null;
                    var fail_condition: ?eval_module.Value = null;

                    for (obj.fields) |field| {
                        if (std.mem.eql(u8, field.key, "kind")) {
                            fail_kind = switch (field.value) {
                                .string => |s| s,
                                else => null,
                            };
                        } else if (std.mem.eql(u8, field.key, "expected")) {
                            fail_expected = field.value;
                        } else if (std.mem.eql(u8, field.key, "actual")) {
                            fail_actual = field.value;
                        } else if (std.mem.eql(u8, field.key, "condition")) {
                            fail_condition = field.value;
                        }
                    }

                    if (fail_kind) |k| {
                        if (std.mem.eql(u8, k, "eq")) {
                            // mustEq failure
                            if (fail_expected != null and fail_actual != null) {
                                const expected_str = try eval_module.formatValue(ctx.allocator, fail_expected.?);
                                defer ctx.allocator.free(expected_str);
                                const actual_str = try eval_module.formatValue(ctx.allocator, fail_actual.?);
                                defer ctx.allocator.free(actual_str);
                                try ctx.writeIndent();
                                try ctx.writer.print("{s}  Expected: {s}{s}\n", .{ Color.dim, expected_str, Color.reset });
                                try ctx.writeIndent();
                                try ctx.writer.print("{s}  Actual:   {s}{s}\n", .{ Color.dim, actual_str, Color.reset });
                            }
                        } else if (std.mem.eql(u8, k, "notEq")) {
                            // mustNotEq failure
                            if (fail_actual != null) {
                                const value_str = try eval_module.formatValue(ctx.allocator, fail_actual.?);
                                defer ctx.allocator.free(value_str);
                                try ctx.writeIndent();
                                try ctx.writer.print("{s}  Expected not to equal: {s}{s}\n", .{ Color.dim, value_str, Color.reset });
                                try ctx.writeIndent();
                                try ctx.writer.print("{s}  But got:               {s}{s}\n", .{ Color.dim, value_str, Color.reset });
                            }
                        } else if (std.mem.eql(u8, k, "truthy")) {
                            // must failure
                            if (fail_condition != null) {
                                const condition_str = try eval_module.formatValue(ctx.allocator, fail_condition.?);
                                defer ctx.allocator.free(condition_str);
                                try ctx.writeIndent();
                                try ctx.writer.print("{s}  Expected condition to be truthy{s}\n", .{ Color.dim, Color.reset });
                                try ctx.writeIndent();
                                try ctx.writer.print("{s}  But got: {s}{s}\n", .{ Color.dim, condition_str, Color.reset });
                            }
                        }
                    }
                },
                else => {},
            }
        }
        ctx.failed += 1;
        return;
    }

    // Not a recognized test type (pass or fail), treat as truthy success
    try ctx.writeIndent();
    try ctx.writer.print("{s}✓{s} {s}\n", .{ Color.green, Color.reset, description.? });
    ctx.passed += 1;
}

pub fn runSpec(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    line_number: ?usize,
    writer: anytype,
) !SpecResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // If line number is specified, find the test at that line
    var filter: ?SpecFilter = null;
    if (line_number) |line| {
        filter = try findTestAtLine(allocator, file_path, line);
        if (filter == null) {
            try writer.print("{s}No test found at line {d} in {s}{s}\n", .{ Color.red, line, file_path, Color.reset });
            return SpecResult{
                .passed = 0,
                .failed = 0,
                .ignored = 0,
            };
        }
    }
    defer if (filter) |f| allocator.free(f.description);

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
        .filter = filter,
        .current_describe_stack = std.ArrayList([]const u8){},
    };
    defer ctx.current_describe_stack.deinit(allocator);

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

            const result = try runSpec(allocator, full_path, null, writer);
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
