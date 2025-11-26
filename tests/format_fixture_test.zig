const std = @import("std");
const formatter = @import("formatter");
const testing = std.testing;

const TestCase = struct {
    expected: []const u8,
    input: []const u8,
};

/// Parse fixture file into alternating test cases
/// Format: comment block (expected output) followed by code block (input)
fn parseFixture(allocator: std.mem.Allocator, file_path: []const u8) ![]TestCase {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var cases = std.ArrayList(TestCase){};
    errdefer {
        for (cases.items) |case| {
            allocator.free(case.expected);
            allocator.free(case.input);
        }
        cases.deinit(allocator);
    }

    var expected_lines = std.ArrayList(u8){};
    defer expected_lines.deinit(allocator);

    var input_lines = std.ArrayList(u8){};
    defer input_lines.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_expected = false;
    var in_input = false;

    while (lines.next()) |line| {
        // Check if this is a comment line (expected output)
        if (std.mem.startsWith(u8, line, "// ")) {
            // If we were collecting input, save the test case
            if (in_input) {
                const exp = try expected_lines.toOwnedSlice(allocator);
                const inp = try input_lines.toOwnedSlice(allocator);
                try cases.append(allocator, .{ .expected = exp, .input = inp });
                expected_lines = std.ArrayList(u8){};
                input_lines = std.ArrayList(u8){};
                in_input = false;
            }

            // Strip "// " and add to expected
            if (in_expected) {
                try expected_lines.append(allocator, '\n');
            }
            try expected_lines.appendSlice(allocator, line[3..]);
            in_expected = true;
        } else if (std.mem.eql(u8, line, "//")) {
            // Empty comment line
            if (in_input) {
                const exp = try expected_lines.toOwnedSlice(allocator);
                const inp = try input_lines.toOwnedSlice(allocator);
                try cases.append(allocator, .{ .expected = exp, .input = inp });
                expected_lines = std.ArrayList(u8){};
                input_lines = std.ArrayList(u8){};
                in_input = false;
            }
            if (in_expected) {
                try expected_lines.append(allocator, '\n');
            }
            in_expected = true;
        } else if (line.len == 0) {
            // Blank line - could be separator or part of input
            if (in_input) {
                // Part of input block
                try input_lines.append(allocator, '\n');
                try input_lines.appendSlice(allocator, line);
            }
            // Otherwise skip it (separator between cases)
        } else {
            // Non-comment, non-empty line - this is input
            if (in_input) {
                try input_lines.append(allocator, '\n');
            }
            try input_lines.appendSlice(allocator, line);
            in_input = true;
            in_expected = false;
        }
    }

    // Save final test case if any
    if (in_input) {
        const exp = try expected_lines.toOwnedSlice(allocator);
        const inp = try input_lines.toOwnedSlice(allocator);
        try cases.append(allocator, .{ .expected = exp, .input = inp });
    }

    return cases.toOwnedSlice(allocator);
}

/// Visualize a string with special characters visible
fn visualizeString(s: []const u8) void {
    for (s) |c| {
        switch (c) {
            ' ' => std.debug.print("\x1b[90m·\x1b[0m", .{}), // Gray middle dot for space
            '\t' => std.debug.print("\x1b[90m→\x1b[0m", .{}), // Gray arrow for tab
            '\n' => std.debug.print("\x1b[90m¬\x1b[0m\n", .{}), // Gray not sign for newline
            else => std.debug.print("{c}", .{c}),
        }
    }
}

/// Print a nice diff between expected and actual output
fn printDiff(expected: []const u8, actual: []const u8) void {
    var exp_lines = std.mem.splitScalar(u8, expected, '\n');
    var act_lines = std.mem.splitScalar(u8, actual, '\n');

    var line_num: usize = 1;
    var has_diff = false;

    while (true) {
        const exp_line = exp_lines.next();
        const act_line = act_lines.next();

        if (exp_line == null and act_line == null) break;

        const exp_str = exp_line orelse "";
        const act_str = act_line orelse "";

        if (!std.mem.eql(u8, exp_str, act_str)) {
            if (!has_diff) {
                std.debug.print("\n\x1b[1m━━━ Differences ━━━\x1b[0m\n", .{});
                has_diff = true;
            }

            std.debug.print("\n\x1b[33mLine {d}:\x1b[0m\n", .{line_num});

            // Expected line
            std.debug.print("  \x1b[32m- Expected:\x1b[0m ", .{});
            visualizeString(exp_str);
            if (exp_line != null) std.debug.print("\n", .{});

            // Actual line
            std.debug.print("  \x1b[31m+ Got:     \x1b[0m ", .{});
            visualizeString(act_str);
            if (act_line != null) std.debug.print("\n", .{});
        }

        line_num += 1;
    }

    if (!has_diff) {
        std.debug.print("\n\x1b[33mNote: Strings differ but all lines match. Check trailing whitespace or final newline.\x1b[0m\n", .{});
    }
}

/// Helper to run formatter and compare with expected output
fn testFormatterFixture(allocator: std.mem.Allocator, file_path: []const u8) !void {
    const cases = try parseFixture(allocator, file_path);
    defer {
        for (cases) |case| {
            allocator.free(case.expected);
            allocator.free(case.input);
        }
        allocator.free(cases);
    }

    // Format each case and collect all expected/actual outputs
    var all_expected = std.ArrayList(u8){};
    defer all_expected.deinit(allocator);

    var all_actual = std.ArrayList(u8){};
    defer all_actual.deinit(allocator);

    for (cases) |case| {
        // Format the input
        var formatted = try formatter.formatSource(allocator, case.input);
        defer formatted.deinit();

        // Append to combined outputs with newline after each
        try all_expected.appendSlice(allocator, case.expected);
        try all_expected.append(allocator, '\n');
        try all_actual.appendSlice(allocator, formatted.text);
    }

    // Compare combined outputs
    if (!std.mem.eql(u8, all_actual.items, all_expected.items)) {
        std.debug.print("\n\x1b[1;31m✗ Formatter fixture test failed: {s}\x1b[0m\n", .{file_path});
        std.debug.print("\n\x1b[1m━━━ Test Cases ━━━\x1b[0m\n", .{});
        for (cases, 0..) |case, i| {
            std.debug.print("\n\x1b[1mCase {d}:\x1b[0m\n", .{i + 1});
            std.debug.print("Input:\n", .{});
            visualizeString(case.input);
            std.debug.print("\n", .{});
        }

        printDiff(all_expected.items, all_actual.items);

        std.debug.print("\n\x1b[90mLegend: · = space, → = tab, ¬ = newline\x1b[0m\n", .{});
        std.debug.print("\n\x1b[33mExpected and actual output differ - see above for details\x1b[0m\n\n", .{});

        // Use testing.expect to fail with a clean message, avoiding verbose Zig error output
        try testing.expect(false);
    }
}

// ============================================================================
// INDIVIDUAL FIXTURE TESTS
// ============================================================================

test "formatter: single-line objects" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/single_line_objects.lazy");
}

test "formatter: multi-line objects" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/multi_line_objects.lazy");
}

test "formatter: nested objects" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/nested_objects.lazy");
}

test "formatter: single-line arrays" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/single_line_arrays.lazy");
}

test "formatter: multi-line arrays" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/multi_line_arrays.lazy");
}

test "formatter: arrays with objects" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/arrays_with_objects.lazy");
}

test "formatter: functions and lambdas" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/functions_lambdas.lazy");
}

test "formatter: function applications" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/function_applications.lazy");
}

test "formatter: operators" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/operators.lazy");
}

test "formatter: conditionals" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/conditionals.lazy");
}

test "formatter: let bindings" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/let_bindings.lazy");
}

test "formatter: tuples" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/tuples.lazy");
}

test "formatter: spacing edge cases" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/spacing_edge_cases.lazy");
}

test "formatter: blank lines preserved" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/blank_lines_preserved.lazy");
}

test "formatter: comprehensions" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/comprehensions.lazy");
}

test "formatter: field access" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/field_access.lazy");
}

test "formatter: symbols" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/symbols.lazy");
}

test "formatter: complex nesting" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/complex_nesting.lazy");
}

test "formatter: do indentation" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/do_indentation.lazy");
}

test "formatter: space before brackets" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/space_before_brackets.lazy");
}

test "formatter: trailing whitespace" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/trailing_whitespace.lazy");
}

test "formatter: object field comprehensions" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/object_field_comprehensions.lazy");
}

test "formatter: object no blank line after opening brace" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/object_no_blank_line.lazy");
}

test "formatter: when/matches indentation" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/when_matches_indentation.lazy");
}

test "formatter: if/then/else indentation" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/if_then_else_indentation.lazy");
}

test "formatter: multiline comprehension indentation" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/multiline_comprehension_indentation.lazy");
}

test "formatter: nested comprehension indentation" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/nested_comprehension_indentation.lazy");
}

test "formatter: semicolons stripped" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/semicolons_stripped.lazy");
}

test "formatter: trailing commas removed" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/trailing_commas_removed.lazy");
}

test "formatter: unary operators" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/unary_operators.lazy");
}

// Note: Regular comment preservation is implemented but difficult to test with fixture format
// Manual testing: cat > /tmp/test.lazy << 'EOF'
// foo = x ->
//   // comment here
//   x + 1
// EOF
// ./bin/lazy format /tmp/test.lazy  # Comments are preserved

test "formatter: spacing operators" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/spacing_operators.lazy");
}

test "formatter: if/then/else on same line" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/if_then_else_same_line.lazy");
}

test "formatter: multiline object opening brace" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/multiline_object_opening_brace.lazy");
}

test "formatter: partial application spacing" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/partial_application_spacing.lazy");
}

test "formatter: multiline object field separation" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/multiline_object_field_separation.lazy");
}

test "formatter: object with when/matches" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/object_with_when_matches.lazy");
}

test "formatter: leading comments" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/leading_comments.lazy");
}

test "formatter: continuation in object" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/continuation_in_object.lazy");
}

test "formatter: array indexing" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/array_indexing.lazy");
}

test "formatter: nested object continuation" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/nested_object_continuation.lazy");
}

test "formatter: multiple fields with continuations" {
    try testFormatterFixture(testing.allocator, "tests/fixtures/formatter/multiple_fields_with_continuations.lazy");
}

// ============================================================================
// STDLIB FORMATTING TEST
// Ensure stdlib files are properly formatted
// ============================================================================

test "stdlib: all files are properly formatted" {
    const stdlib_paths = [_][]const u8{
        "stdlib/lib",
        "stdlib/spec",
    };

    for (stdlib_paths) |base_path| {
        var dir = std.fs.cwd().openDir(base_path, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open directory {s}: {}\n", .{ base_path, err });
            try testing.expect(false);
            continue;
        };
        defer dir.close();

        var walker = try dir.walk(testing.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".lazy")) continue;

            // Build full path
            const full_path = try std.fs.path.join(testing.allocator, &[_][]const u8{ base_path, entry.path });
            defer testing.allocator.free(full_path);

            // Read original content
            const file = try std.fs.cwd().openFile(full_path, .{});
            defer file.close();
            const original = try file.readToEndAlloc(testing.allocator, 10 * 1024 * 1024);
            defer testing.allocator.free(original);

            // Format the file
            var formatted = try formatter.formatSource(testing.allocator, original);
            defer formatted.deinit();

            // Check if formatted output matches original
            if (!std.mem.eql(u8, formatted.text, original)) {
                std.debug.print("\n\x1b[1;31m✗ File is not properly formatted: {s}\x1b[0m\n", .{full_path});
                std.debug.print("\nRun: ./bin/lazy format -i {s}\n", .{full_path});
                std.debug.print("\nOr run: ./bin/lazy format --diff {s}\n\n", .{full_path});
                try testing.expect(false);
            }
        }
    }
}

// ============================================================================
// REGRESSION TEST
// Ensure all formatter fixtures work correctly
// ============================================================================

test "regression: all formatter fixtures produce correct output" {
    const fixtures = [_][]const u8{
        "tests/fixtures/formatter/single_line_objects.lazy",
        "tests/fixtures/formatter/multi_line_objects.lazy",
        "tests/fixtures/formatter/nested_objects.lazy",
        "tests/fixtures/formatter/single_line_arrays.lazy",
        "tests/fixtures/formatter/multi_line_arrays.lazy",
        "tests/fixtures/formatter/arrays_with_objects.lazy",
        "tests/fixtures/formatter/functions_lambdas.lazy",
        "tests/fixtures/formatter/function_applications.lazy",
        "tests/fixtures/formatter/operators.lazy",
        "tests/fixtures/formatter/conditionals.lazy",
        "tests/fixtures/formatter/let_bindings.lazy",
        "tests/fixtures/formatter/tuples.lazy",
        "tests/fixtures/formatter/spacing_edge_cases.lazy",
        "tests/fixtures/formatter/blank_lines_preserved.lazy",
        "tests/fixtures/formatter/comprehensions.lazy",
        "tests/fixtures/formatter/field_access.lazy",
        "tests/fixtures/formatter/symbols.lazy",
        "tests/fixtures/formatter/complex_nesting.lazy",
        "tests/fixtures/formatter/do_indentation.lazy",
        "tests/fixtures/formatter/space_before_brackets.lazy",
        "tests/fixtures/formatter/trailing_whitespace.lazy",
        "tests/fixtures/formatter/object_field_comprehensions.lazy",
        "tests/fixtures/formatter/object_no_blank_line.lazy",
        "tests/fixtures/formatter/when_matches_indentation.lazy",
        "tests/fixtures/formatter/if_then_else_indentation.lazy",
        "tests/fixtures/formatter/multiline_comprehension_indentation.lazy",
        "tests/fixtures/formatter/nested_comprehension_indentation.lazy",
        "tests/fixtures/formatter/semicolons_stripped.lazy",
        "tests/fixtures/formatter/trailing_commas_removed.lazy",
        "tests/fixtures/formatter/unary_operators.lazy",
        "tests/fixtures/formatter/spacing_operators.lazy",
        "tests/fixtures/formatter/if_then_else_same_line.lazy",
        "tests/fixtures/formatter/multiline_object_opening_brace.lazy",
        "tests/fixtures/formatter/partial_application_spacing.lazy",
        "tests/fixtures/formatter/multiline_object_field_separation.lazy",
        "tests/fixtures/formatter/object_with_when_matches.lazy",
        "tests/fixtures/formatter/leading_comments.lazy",
        "tests/fixtures/formatter/continuation_in_object.lazy",
        "tests/fixtures/formatter/array_indexing.lazy",
        "tests/fixtures/formatter/nested_object_continuation.lazy",
        "tests/fixtures/formatter/multiple_fields_with_continuations.lazy",
        // TODO: Re-enable when doc comment blank line handling is fixed
        // "tests/fixtures/formatter/doc_comments.lazy",
    };

    for (fixtures) |fixture| {
        try testFormatterFixture(testing.allocator, fixture);
    }
}
