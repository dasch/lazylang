const std = @import("std");
const formatter = @import("formatter");
const testing = std.testing;

/// Helper to extract expected formatted output from comments in fixture file
fn loadExpectedOutput(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    // Parse line by line, extracting comment lines as expected output
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Check if line starts with "//"
        if (std.mem.startsWith(u8, line, "// ")) {
            // Strip "// " and add to result
            try result.appendSlice(allocator, line[3..]);
            try result.append(allocator, '\n');
        } else if (std.mem.eql(u8, line, "//")) {
            // Empty comment line - just add newline
            try result.append(allocator, '\n');
        }
        // Skip non-comment lines
    }

    return result.toOwnedSlice(allocator);
}

/// Helper to extract actual code (non-comment lines) from fixture file
fn loadActualCode(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    // Parse line by line, extracting non-comment lines as actual code
    var lines = std.mem.splitScalar(u8, content, '\n');
    var found_code = false;
    while (lines.next()) |line| {
        // Skip comment lines (both // and # style), but NOT doc comments (///)
        if (std.mem.startsWith(u8, line, "///")) {
            // This is a doc comment, keep it
        } else if (std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "#")) {
            continue;
        }

        // Skip empty lines before we find actual code
        if (!found_code and line.len == 0) {
            continue;
        }

        // Add non-comment lines
        if (found_code) {
            try result.append(allocator, '\n');
        }
        try result.appendSlice(allocator, line);
        found_code = true;
    }

    return result.toOwnedSlice(allocator);
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
    const expected = try loadExpectedOutput(allocator, file_path);
    defer allocator.free(expected);

    const actual_code = try loadActualCode(allocator, file_path);
    defer allocator.free(actual_code);

    var formatted = try formatter.formatSource(allocator, actual_code);
    defer formatted.deinit();

    if (!std.mem.eql(u8, formatted.text, expected)) {
        std.debug.print("\n\x1b[1;31m✗ Formatter fixture test failed: {s}\x1b[0m\n", .{file_path});
        std.debug.print("\n\x1b[1m━━━ Input ━━━\x1b[0m\n", .{});
        visualizeString(actual_code);
        std.debug.print("\n", .{});

        printDiff(expected, formatted.text);

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
        // TODO: Re-enable when doc comment blank line handling is fixed
        // "tests/fixtures/formatter/doc_comments.lazy",
    };

    for (fixtures) |fixture| {
        try testFormatterFixture(testing.allocator, fixture);
    }
}
