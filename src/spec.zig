const std = @import("std");
const eval_module = @import("eval.zig");
const cli_error_reporting = @import("cli_error_reporting.zig");
const error_reporter = @import("error_reporter.zig");

// ANSI color codes
const Color = struct {
    const reset = "\x1b[0m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const cyan = "\x1b[36m";
    const blue = "\x1b[34m";
    const yellow = "\x1b[33m";
    const dim = "\x1b[2m";
    const bold = "\x1b[1m";
    const italic = "\x1b[3m";
    const grey = "\x1b[90m";
    const strikethrough = "\x1b[9m";
};

// Format description with markdown-light syntax highlighting
// - `code` -> code_color (default blue)
// - *emphasis* -> italic
// - _emphasis_ -> italic
// After each formatting, resets to reset_color (default Color.reset)
fn formatDescription(allocator: std.mem.Allocator, text: []const u8, code_color: []const u8, reset_color: []const u8) ![]const u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            // Find closing backtick
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                // Add code color, content, and reset to base color
                try result.appendSlice(allocator, code_color);
                try result.appendSlice(allocator, text[i + 1 .. end]);
                try result.appendSlice(allocator, reset_color);
                i = end + 1;
            } else {
                // No closing backtick, just add the character
                try result.append(allocator, text[i]);
                i += 1;
            }
        } else if (text[i] == '*') {
            // Find closing asterisk
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |end| {
                // Add italic code, content, and reset to base color
                try result.appendSlice(allocator, Color.italic);
                try result.appendSlice(allocator, text[i + 1 .. end]);
                try result.appendSlice(allocator, reset_color);
                i = end + 1;
            } else {
                // No closing asterisk, just add the character
                try result.append(allocator, text[i]);
                i += 1;
            }
        } else if (text[i] == '_') {
            // Find closing underscore
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '_')) |end| {
                // Add italic code, content, and reset to base color
                try result.appendSlice(allocator, Color.italic);
                try result.appendSlice(allocator, text[i + 1 .. end]);
                try result.appendSlice(allocator, reset_color);
                i = end + 1;
            } else {
                // No closing underscore, just add the character
                try result.append(allocator, text[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, text[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

// Helper to build the full describe path for display
fn buildDescribePath(allocator: std.mem.Allocator, describe_stack: []const []const u8) ![]const u8 {
    if (describe_stack.len == 0) return "";

    var path = std.ArrayList(u8){};
    errdefer path.deinit(allocator);

    for (describe_stack, 0..) |desc, i| {
        if (i > 0) {
            // Use "." between consecutive symbols, " " otherwise
            const prev_is_symbol = describe_stack[i - 1].len > 0 and describe_stack[i - 1][0] == '#';
            const curr_is_symbol = desc.len > 0 and desc[0] == '#';
            const separator = if (prev_is_symbol and curr_is_symbol) "." else " ";
            try path.appendSlice(allocator, separator);
        }
        // Strip # prefix from symbols
        const desc_name = if (desc.len > 0 and desc[0] == '#')
            desc[1..]
        else
            desc;
        try path.appendSlice(allocator, desc_name);
    }

    try path.appendSlice(allocator, " ");
    return path.toOwnedSlice(allocator);
}

// Helper to find the line number of a test by searching for its description
fn findLineForTest(allocator: std.mem.Allocator, file_path: []const u8, test_description: []const u8) ?usize {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(content);

    // Search for 'it "description"' or 'xit "description"'
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 1;

    while (lines.next()) |line| : (line_number += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");

        // Look for "it " or "xit " followed by the description in quotes
        for ([_][]const u8{ "it \"", "xit \"" }) |prefix| {
            if (std.mem.indexOf(u8, trimmed, prefix)) |start| {
                // Find the description in quotes
                const after_prefix = trimmed[start + prefix.len..];
                if (std.mem.indexOfScalar(u8, after_prefix, '"')) |end| {
                    const found_desc = after_prefix[0..end];
                    if (std.mem.eql(u8, found_desc, test_description)) {
                        return line_number;
                    }
                }
            }
        }
    }

    return null;
}

// Helper to record a failed spec for the summary
fn recordFailedSpec(ctx: anytype, test_description: []const u8) !void {
    // Build the describe path from the stack
    var describe_path = std.ArrayList(u8){};
    defer describe_path.deinit(ctx.allocator);

    for (ctx.current_describe_stack.items, 0..) |desc, i| {
        if (i > 0) {
            // Use "." between consecutive symbols, " " otherwise
            const prev_is_symbol = ctx.current_describe_stack.items[i - 1].len > 0 and ctx.current_describe_stack.items[i - 1][0] == '#';
            const curr_is_symbol = desc.len > 0 and desc[0] == '#';
            const separator = if (prev_is_symbol and curr_is_symbol) "." else " ";
            try describe_path.appendSlice(ctx.allocator, separator);
        }
        // Strip # prefix from symbols
        const desc_name = if (desc.len > 0 and desc[0] == '#')
            desc[1..]
        else
            desc;
        try describe_path.appendSlice(ctx.allocator, desc_name);
    }

    // Add trailing space
    if (ctx.current_describe_stack.items.len > 0) {
        try describe_path.appendSlice(ctx.allocator, " ");
    }

    // Try to find the line number
    const line_number = findLineForTest(ctx.allocator, ctx.current_file_path, test_description);

    const failed_spec = FailedSpec{
        .file_path = try ctx.allocator.dupe(u8, ctx.current_file_path),
        .line_number = line_number,
        .describe_path = try describe_path.toOwnedSlice(ctx.allocator),
        .test_description = try ctx.allocator.dupe(u8, test_description),
    };

    try ctx.failed_specs.append(ctx.allocator, failed_spec);
}

// Helper to record a skipped spec for the summary
fn recordSkippedSpec(ctx: anytype, test_description: []const u8) !void {
    // Build the describe path from the stack
    var describe_path = std.ArrayList(u8){};
    defer describe_path.deinit(ctx.allocator);

    for (ctx.current_describe_stack.items, 0..) |desc, i| {
        if (i > 0) {
            // Use "." between consecutive symbols, " " otherwise
            const prev_is_symbol = ctx.current_describe_stack.items[i - 1].len > 0 and ctx.current_describe_stack.items[i - 1][0] == '#';
            const curr_is_symbol = desc.len > 0 and desc[0] == '#';
            const separator = if (prev_is_symbol and curr_is_symbol) "." else " ";
            try describe_path.appendSlice(ctx.allocator, separator);
        }
        // Strip # prefix from symbols
        const desc_name = if (desc.len > 0 and desc[0] == '#')
            desc[1..]
        else
            desc;
        try describe_path.appendSlice(ctx.allocator, desc_name);
    }

    // Add trailing space
    if (ctx.current_describe_stack.items.len > 0) {
        try describe_path.appendSlice(ctx.allocator, " ");
    }

    // Try to find the line number
    const line_number = findLineForTest(ctx.allocator, ctx.current_file_path, test_description);

    const skipped_spec = SkippedSpec{
        .file_path = try ctx.allocator.dupe(u8, ctx.current_file_path),
        .line_number = line_number,
        .describe_path = try describe_path.toOwnedSlice(ctx.allocator),
        .test_description = try ctx.allocator.dupe(u8, test_description),
    };

    try ctx.skipped_specs.append(ctx.allocator, skipped_spec);
}

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

const FailedSpec = struct {
    file_path: []const u8,
    line_number: ?usize,
    describe_path: []const u8,
    test_description: []const u8,
};

const SkippedSpec = struct {
    file_path: []const u8,
    line_number: ?usize,
    describe_path: []const u8,
    test_description: []const u8,
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
        filter: ?SpecFilter,
        current_describe_stack: std.ArrayList([]const u8),
        verbose: bool,
        failed_specs: std.ArrayList(FailedSpec),
        skipped_specs: std.ArrayList(SkippedSpec),
        current_file_path: []const u8,

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
            // Force thunk if needed
            const forced_value = eval_module.force(ctx.allocator, field.value) catch field.value;
            item_type = switch (forced_value) {
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
    // Get description (can be string or symbol)
    var description: ?[]const u8 = null;
    var description_is_symbol = false;
    var children: ?eval_module.ArrayValue = null;

    for (desc.fields) |field| {
        if (std.mem.eql(u8, field.key, "description")) {
            const forced_value = eval_module.force(ctx.allocator, field.value) catch field.value;
            switch (forced_value) {
                .string => |s| {
                    description = s;
                    description_is_symbol = false;
                },
                .symbol => |s| {
                    description = s;
                    description_is_symbol = true;
                },
                else => {},
            }
        } else if (std.mem.eql(u8, field.key, "children")) {
            const forced_value = eval_module.force(ctx.allocator, field.value) catch field.value;
            children = switch (forced_value) {
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

    if (should_run_children and should_display and ctx.verbose) {
        // Add blank line if needed (from de-indenting)
        if (ctx.needs_blank_line) {
            try ctx.writer.writeAll("\n");
            ctx.needs_blank_line = false;
        }

        try ctx.writeIndent();

        // Format description based on type
        if (description_is_symbol) {
            // Symbols are formatted like code (blue), strip the # prefix
            const symbol_name = if (description.?.len > 0 and description.?[0] == '#')
                description.?[1..]
            else
                description.?;
            try ctx.writer.print("{s}{s}{s}{s}\n", .{ Color.bold, Color.blue, symbol_name, Color.reset });
        } else {
            // Strings use the full markdown-light formatting (white/no color) with bold
            const formatted_desc = try formatDescription(ctx.allocator, description.?, Color.blue, Color.bold);
            defer ctx.allocator.free(formatted_desc);
            try ctx.writer.print("{s}{s}{s}\n", .{ Color.bold, formatted_desc, Color.reset });
        }
    }

    if (should_run_children) {
        const ch = children.?;
        const should_indent = should_display and ctx.verbose;

        if (should_indent) {
            ctx.indent += 1;
        }

        for (ch.elements, 0..) |child, i| {
            // Clear the needs_blank_line flag for children since they're at a deeper level
            if (i == 0) {
                ctx.needs_blank_line = false;
            }

            // Add blank line before sibling describe blocks (but not before the first child)
            // Only in verbose mode
            if (ctx.verbose and i > 0 and should_display) {
                const child_obj = switch (child) {
                    .object => |obj| obj,
                    else => null,
                };
                if (child_obj) |obj| {
                    for (obj.fields) |field| {
                        if (std.mem.eql(u8, field.key, "type")) {
                            const forced_value = eval_module.force(ctx.allocator, field.value) catch field.value;
                            const type_val = switch (forced_value) {
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
            const forced_value = eval_module.force(ctx.allocator, field.value) catch field.value;
            description = switch (forced_value) {
                .string => |s| s,
                else => null,
            };
        } else if (std.mem.eql(u8, field.key, "test")) {
            test_value = eval_module.force(ctx.allocator, field.value) catch field.value;
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

    // If the test is ignored (xit), record it and optionally display it
    if (is_ignored) {
        // Record the skipped spec
        try recordSkippedSpec(ctx, description.?);

        // Only print inline if verbose mode is enabled
        if (ctx.verbose) {
            try ctx.writeIndent();
            const describe_path = try buildDescribePath(ctx.allocator, ctx.current_describe_stack.items);
            defer ctx.allocator.free(describe_path);
            const formatted_desc = try formatDescription(ctx.allocator, description.?, Color.blue, Color.grey);
            defer ctx.allocator.free(formatted_desc);
            try ctx.writer.print("{s}□ {s}{s}{s}{s}\n", .{ Color.grey, Color.strikethrough, describe_path, formatted_desc, Color.reset });
        }
        ctx.ignored += 1;
        return;
    }

    if (test_value == null) {
        try ctx.writeIndent();
        const describe_path = try buildDescribePath(ctx.allocator, ctx.current_describe_stack.items);
        defer ctx.allocator.free(describe_path);
        const formatted_desc = try formatDescription(ctx.allocator, description.?, Color.yellow, Color.red);
        defer ctx.allocator.free(formatted_desc);
        try ctx.writer.print("{s}✗ {s}{s}: missing test{s}\n", .{ Color.red, describe_path, formatted_desc, Color.reset });
        try recordFailedSpec(ctx, description.?);
        ctx.failed += 1;
        return;
    }

    // Check if test_value is an assertion
    const test_obj = switch (test_value.?) {
        .object => |obj| obj,
        else => {
            // Only print passing tests in verbose mode
            if (ctx.verbose) {
                try ctx.writeIndent();
                const formatted_desc = try formatDescription(ctx.allocator, description.?, Color.blue, Color.reset);
                defer ctx.allocator.free(formatted_desc);
                try ctx.writer.print("{s}✓{s} {s}\n", .{ Color.green, Color.reset, formatted_desc });
            }
            ctx.passed += 1;
            return;
        },
    };

    // Parse the test object type and fields
    var test_type: ?[]const u8 = null;
    var fail_details: ?eval_module.Value = null;

    for (test_obj.fields) |field| {
        if (std.mem.eql(u8, field.key, "type")) {
            const forced_value = eval_module.force(ctx.allocator, field.value) catch field.value;
            test_type = switch (forced_value) {
                .string => |s| s,
                else => null,
            };
        } else if (std.mem.eql(u8, field.key, "details")) {
            fail_details = eval_module.force(ctx.allocator, field.value) catch field.value;
        }
    }

    // Handle explicit pass
    if (test_type != null and std.mem.eql(u8, test_type.?, "pass")) {
        // Only print passing tests in verbose mode
        if (ctx.verbose) {
            try ctx.writeIndent();
            const formatted_desc = try formatDescription(ctx.allocator, description.?, Color.blue, Color.reset);
            defer ctx.allocator.free(formatted_desc);
            try ctx.writer.print("{s}✓{s} {s}\n", .{ Color.green, Color.reset, formatted_desc });
        }
        ctx.passed += 1;
        return;
    }

    // Handle explicit fail
    if (test_type != null and std.mem.eql(u8, test_type.?, "fail")) {
        try ctx.writeIndent();
        const describe_path = try buildDescribePath(ctx.allocator, ctx.current_describe_stack.items);
        defer ctx.allocator.free(describe_path);
        const formatted_desc = try formatDescription(ctx.allocator, description.?, Color.yellow, Color.red);
        defer ctx.allocator.free(formatted_desc);
        try ctx.writer.print("{s}✗ {s}{s}{s}\n", .{ Color.red, describe_path, formatted_desc, Color.reset });

        // Record the failed spec
        try recordFailedSpec(ctx, description.?);

        // Handle fail details (can be a string or an object with structured info)
        if (fail_details) |details| {
            switch (details) {
                .string => |msg| {
                    // Simple string message
                    try ctx.writeIndent();
                    try ctx.writer.print("{s}    {s}{s}\n", .{ Color.dim, msg, Color.reset });
                },
                .object => |obj| {
                    // Structured failure details with kind, expected, actual, condition
                    var fail_kind: ?[]const u8 = null;
                    var fail_expected: ?eval_module.Value = null;
                    var fail_actual: ?eval_module.Value = null;
                    var fail_condition: ?eval_module.Value = null;

                    for (obj.fields) |field| {
                        if (std.mem.eql(u8, field.key, "kind")) {
                            const forced_value = eval_module.force(ctx.allocator, field.value) catch field.value;
                            fail_kind = switch (forced_value) {
                                .string => |s| s,
                                else => null,
                            };
                        } else if (std.mem.eql(u8, field.key, "expected")) {
                            fail_expected = eval_module.force(ctx.allocator, field.value) catch field.value;
                        } else if (std.mem.eql(u8, field.key, "actual")) {
                            fail_actual = eval_module.force(ctx.allocator, field.value) catch field.value;
                        } else if (std.mem.eql(u8, field.key, "condition")) {
                            fail_condition = eval_module.force(ctx.allocator, field.value) catch field.value;
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
                                try ctx.writer.print("{s}    Expected: {s}{s}\n", .{ Color.dim, expected_str, Color.reset });
                                try ctx.writeIndent();
                                try ctx.writer.print("{s}    Actual:   {s}{s}\n", .{ Color.dim, actual_str, Color.reset });
                            }
                        } else if (std.mem.eql(u8, k, "notEq")) {
                            // mustNotEq failure
                            if (fail_actual != null) {
                                const value_str = try eval_module.formatValue(ctx.allocator, fail_actual.?);
                                defer ctx.allocator.free(value_str);
                                try ctx.writeIndent();
                                try ctx.writer.print("{s}    Expected not to equal: {s}{s}\n", .{ Color.dim, value_str, Color.reset });
                                try ctx.writeIndent();
                                try ctx.writer.print("{s}    But got:               {s}{s}\n", .{ Color.dim, value_str, Color.reset });
                            }
                        } else if (std.mem.eql(u8, k, "truthy")) {
                            // must failure
                            if (fail_condition != null) {
                                const condition_str = try eval_module.formatValue(ctx.allocator, fail_condition.?);
                                defer ctx.allocator.free(condition_str);
                                try ctx.writeIndent();
                                try ctx.writer.print("{s}    Expected condition to be truthy{s}\n", .{ Color.dim, Color.reset });
                                try ctx.writeIndent();
                                try ctx.writer.print("{s}    But got: {s}{s}\n", .{ Color.dim, condition_str, Color.reset });
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
    // Only print passing tests in verbose mode
    if (ctx.verbose) {
        try ctx.writeIndent();
        const formatted_desc = try formatDescription(ctx.allocator, description.?, Color.blue, Color.reset);
        defer ctx.allocator.free(formatted_desc);
        try ctx.writer.print("{s}✓{s} {s}\n", .{ Color.green, Color.reset, formatted_desc });
    }
    ctx.passed += 1;
}

pub fn runSpec(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    line_number: ?usize,
    verbose: bool,
    writer: anytype,
) !SpecResult {
    var failed_specs = std.ArrayList(FailedSpec){};
    defer {
        for (failed_specs.items) |failed_spec| {
            allocator.free(failed_spec.file_path);
            allocator.free(failed_spec.describe_path);
            allocator.free(failed_spec.test_description);
        }
        failed_specs.deinit(allocator);
    }

    var skipped_specs = std.ArrayList(SkippedSpec){};
    defer {
        for (skipped_specs.items) |skipped_spec| {
            allocator.free(skipped_spec.file_path);
            allocator.free(skipped_spec.describe_path);
            allocator.free(skipped_spec.test_description);
        }
        skipped_specs.deinit(allocator);
    }

    const result = try runSpecWithFailedAndSkippedSpecs(allocator, file_path, line_number, verbose, &failed_specs, &skipped_specs, writer);

    // Print skipped specs list if verbose and there are skipped tests
    if (verbose and result.ignored > 0 and skipped_specs.items.len > 0) {
        try writer.writeAll("\n");
        try writer.print("{s}Skipped specs:{s}\n", .{ Color.grey, Color.reset });
        for (skipped_specs.items) |skipped_spec| {
            try writer.print("{s}- {s}", .{ Color.grey, skipped_spec.file_path });
            if (skipped_spec.line_number) |line| {
                try writer.print(":{d}", .{line});
            }
            try writer.print(" {s}#{s} ", .{ Color.dim, Color.reset });
            try writer.print("{s}", .{Color.strikethrough});
            if (skipped_spec.describe_path.len > 0) {
                try writer.print("{s}", .{skipped_spec.describe_path});
            }
            try writer.print("{s}{s}\n", .{ skipped_spec.test_description, Color.reset });
        }
    }

    // Print failed specs list if there are failures
    if (result.failed > 0 and failed_specs.items.len > 0) {
        try writer.writeAll("\n");
        try writer.print("{s}Failed specs:{s}\n", .{ Color.red, Color.reset });
        for (failed_specs.items) |failed_spec| {
            try writer.print("- {s}", .{failed_spec.file_path});
            if (failed_spec.line_number) |line| {
                try writer.print(":{d}", .{line});
            }
            try writer.print(" {s}#{s} ", .{ Color.dim, Color.reset });
            if (failed_spec.describe_path.len > 0) {
                try writer.print("{s}", .{failed_spec.describe_path});
            }
            try writer.print("{s}\n", .{failed_spec.test_description});
        }
    }

    return result;
}

fn runSpecWithFailedAndSkippedSpecs(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    line_number: ?usize,
    verbose: bool,
    all_failed_specs: ?*std.ArrayList(FailedSpec),
    all_skipped_specs: ?*std.ArrayList(SkippedSpec),
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

    // Read the file content first for error reporting
    const file_content = std.fs.cwd().readFileAlloc(allocator, file_path, std.math.maxInt(usize)) catch |read_err| {
        try writer.print("{s}error: failed to read file '{s}': {}{s}\n", .{ Color.red, file_path, read_err, Color.reset });
        return SpecResult{
            .passed = 0,
            .failed = 1,
            .ignored = 0,
        };
    };
    defer allocator.free(file_content);

    // Evaluate the spec file
    var result = eval_module.evalFileWithValue(allocator, file_path) catch |err| {
        // For file I/O errors that don't have error context
        // Extract just the filename or relative path for display
        const display_path = if (std.mem.lastIndexOf(u8, file_path, "spec/")) |idx|
            file_path[idx..]
        else if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |idx|
            file_path[idx + 1 ..]
        else
            file_path;

        try writer.print("{s}{s} failed with error: {s}{}{s}\n", .{
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
    defer result.deinit();

    // Check if there was an error during evaluation
    if (result.err) |err| {
        // Extract just the filename or relative path for display
        const display_path = if (std.mem.lastIndexOf(u8, file_path, "spec/")) |idx|
            file_path[idx..]
        else if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |idx|
            file_path[idx + 1 ..]
        else
            file_path;

        try writer.print("{s}{s} failed:{s}\n", .{
            Color.red,
            display_path,
            Color.reset,
        });

        // Use proper error reporting with context
        const colors_enabled = error_reporter.shouldUseColors();
        const error_filename = if (result.error_ctx.source_filename.len > 0)
            result.error_ctx.source_filename
        else
            file_path;

        const error_source = result.error_ctx.source_map.get(error_filename) orelse file_content;

        try cli_error_reporting.reportErrorWithContext(
            allocator,
            writer,
            error_filename,
            error_source,
            &result.error_ctx,
            err,
            colors_enabled,
        );

        return SpecResult{
            .passed = 0,
            .failed = 1,
            .ignored = 0,
        };
    }

    const value = result.value;

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
        .verbose = verbose,
        .failed_specs = std.ArrayList(FailedSpec){},
        .skipped_specs = std.ArrayList(SkippedSpec){},
        .current_file_path = file_path,
    };
    defer ctx.current_describe_stack.deinit(allocator);
    defer {
        // If all_failed_specs is provided, transfer ownership to it
        if (all_failed_specs == null) {
            // Clean up if we're not transferring
            for (ctx.failed_specs.items) |failed_spec| {
                allocator.free(failed_spec.file_path);
                allocator.free(failed_spec.describe_path);
                allocator.free(failed_spec.test_description);
            }
        }
        ctx.failed_specs.deinit(allocator);

        // If all_skipped_specs is provided, transfer ownership to it
        if (all_skipped_specs == null) {
            // Clean up if we're not transferring
            for (ctx.skipped_specs.items) |skipped_spec| {
                allocator.free(skipped_spec.file_path);
                allocator.free(skipped_spec.describe_path);
                allocator.free(skipped_spec.test_description);
            }
        }
        ctx.skipped_specs.deinit(allocator);
    }

    try runTestItem(&ctx, value);

    // Transfer failed specs to all_failed_specs if provided
    if (all_failed_specs) |list| {
        try list.appendSlice(allocator, ctx.failed_specs.items);
    }

    // Transfer skipped specs to all_skipped_specs if provided
    if (all_skipped_specs) |list| {
        try list.appendSlice(allocator, ctx.skipped_specs.items);
    }

    return SpecResult{
        .passed = ctx.passed,
        .failed = ctx.failed,
        .ignored = ctx.ignored,
    };
}

fn runAllSpecsRecursive(
    allocator: std.mem.Allocator,
    spec_dir: []const u8,
    verbose: bool,
    writer: anytype,
    total_passed: *usize,
    total_failed: *usize,
    total_ignored: *usize,
    all_failed_specs: *std.ArrayList(FailedSpec),
    all_skipped_specs: *std.ArrayList(SkippedSpec),
    first_file: *bool,
) !void {
    var dir = try std.fs.cwd().openDir(spec_dir, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ spec_dir, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, "Spec.lazy")) {
            // Add blank line between test files (only in verbose mode)
            if (verbose and !first_file.*) {
                try writer.writeAll("\n");
            }
            first_file.* = false;

            const result = try runSpecWithFailedAndSkippedSpecs(allocator, full_path, null, verbose, all_failed_specs, all_skipped_specs, writer);
            total_passed.* += result.passed;
            total_failed.* += result.failed;
            total_ignored.* += result.ignored;
        } else if (entry.kind == .directory) {
            // Recursively search subdirectories
            try runAllSpecsRecursive(allocator, full_path, verbose, writer, total_passed, total_failed, total_ignored, all_failed_specs, all_skipped_specs, first_file);
        }
    }
}

pub fn runAllSpecs(
    allocator: std.mem.Allocator,
    spec_dir: []const u8,
    verbose: bool,
    writer: anytype,
) !SpecResult {
    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var total_ignored: usize = 0;
    var first_file = true;
    var all_failed_specs = std.ArrayList(FailedSpec){};
    defer {
        for (all_failed_specs.items) |failed_spec| {
            allocator.free(failed_spec.file_path);
            allocator.free(failed_spec.describe_path);
            allocator.free(failed_spec.test_description);
        }
        all_failed_specs.deinit(allocator);
    }

    var all_skipped_specs = std.ArrayList(SkippedSpec){};
    defer {
        for (all_skipped_specs.items) |skipped_spec| {
            allocator.free(skipped_spec.file_path);
            allocator.free(skipped_spec.describe_path);
            allocator.free(skipped_spec.test_description);
        }
        all_skipped_specs.deinit(allocator);
    }

    try runAllSpecsRecursive(allocator, spec_dir, verbose, writer, &total_passed, &total_failed, &total_ignored, &all_failed_specs, &all_skipped_specs, &first_file);

    // Print skipped specs list if verbose and there are skipped tests
    if (verbose and total_ignored > 0 and all_skipped_specs.items.len > 0) {
        try writer.writeAll("\n");
        try writer.print("{s}Skipped specs:{s}\n", .{ Color.grey, Color.reset });
        for (all_skipped_specs.items) |skipped_spec| {
            try writer.print("{s}- {s}", .{ Color.grey, skipped_spec.file_path });
            if (skipped_spec.line_number) |line| {
                try writer.print(":{d}", .{line});
            }
            try writer.print(" {s}#{s} ", .{ Color.dim, Color.reset });
            try writer.print("{s}", .{Color.strikethrough});
            if (skipped_spec.describe_path.len > 0) {
                try writer.print("{s}", .{skipped_spec.describe_path});
            }
            try writer.print("{s}{s}\n", .{ skipped_spec.test_description, Color.reset });
        }
    }

    // Print failed specs list if there are failures
    if (total_failed > 0 and all_failed_specs.items.len > 0) {
        try writer.writeAll("\n");
        try writer.print("{s}Failed specs:{s}\n", .{ Color.red, Color.reset });
        for (all_failed_specs.items) |failed_spec| {
            // Format: spec/FooSpec.lazy # Foo / bar / it description
            try writer.print("- {s}", .{failed_spec.file_path});
            if (failed_spec.line_number) |line| {
                try writer.print(":{d}", .{line});
            }
            try writer.print(" {s}#{s} ", .{ Color.dim, Color.reset });
            if (failed_spec.describe_path.len > 0) {
                try writer.print("{s}", .{failed_spec.describe_path});
            }
            try writer.print("{s}\n", .{failed_spec.test_description});
        }
    }

    // Print summary
    try writer.writeAll("\n");
    const total = total_passed + total_failed;
    if (total_failed == 0) {
        try writer.print("{s}{s}✓ {d} spec{s} passed{s}", .{ Color.bold, Color.green, total, if (total == 1) "" else "s", Color.reset });
        if (total_ignored > 0) {
            try writer.print(", {s}{d} ignored{s}", .{ Color.grey, total_ignored, Color.reset });
        }
        try writer.writeAll("\n");
    } else {
        try writer.print("{s}{s}{d}{s} spec{s} passed, {s}{d} failed{s}", .{
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
