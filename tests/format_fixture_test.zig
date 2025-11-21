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
        // Skip comment lines
        if (std.mem.startsWith(u8, line, "//")) {
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

/// Helper to run formatter and compare with expected output
fn testFormatterFixture(allocator: std.mem.Allocator, file_path: []const u8) !void {
    const expected = try loadExpectedOutput(allocator, file_path);
    defer allocator.free(expected);

    const actual_code = try loadActualCode(allocator, file_path);
    defer allocator.free(actual_code);

    var formatted = try formatter.formatSource(allocator, actual_code);
    defer formatted.deinit();

    if (!std.mem.eql(u8, formatted.text, expected)) {
        std.debug.print("\n=== Formatter Test Failed: {s} ===\n", .{file_path});
        std.debug.print("Input:\n{s}\n", .{actual_code});
        std.debug.print("Expected:\n{s}\n", .{expected});
        std.debug.print("Got:\n{s}\n", .{formatted.text});
        std.debug.print("====================================\n", .{});
        return error.FormatterMismatch;
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
    };

    for (fixtures) |fixture| {
        try testFormatterFixture(testing.allocator, fixture);
    }
}
