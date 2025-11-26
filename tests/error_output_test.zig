const std = @import("std");
const cli = @import("cli");
const testing = std.testing;

/// Helper to capture error output from evaluating a file
fn captureErrorOutput(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    var stdout_buffer = std.ArrayList(u8){};
    defer stdout_buffer.deinit(allocator);

    var stderr_buffer = std.ArrayList(u8){};

    const args = &[_][]const u8{ "lazylang", "eval", "--no-color", file_path };

    _ = try cli.run(
        allocator,
        args,
        stdout_buffer.writer(allocator),
        stderr_buffer.writer(allocator),
    );

    return try stderr_buffer.toOwnedSlice(allocator);
}

/// Helper to extract expected error message from comments in fixture file
fn loadExpectedError(allocator: std.mem.Allocator, file_path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    // Parse line by line
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

/// Helper to assert exact match between actual and expected output
fn assertExactMatch(actual: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("\n=== EXPECTED OUTPUT ===\n{s}\n", .{expected});
        std.debug.print("\n=== ACTUAL OUTPUT ===\n{s}\n", .{actual});
        return error.OutputMismatch;
    }
}

/// Helper to check that output contains all expected fragments
fn assertContains(output: []const u8, expected: []const []const u8) !void {
    for (expected) |fragment| {
        if (std.mem.indexOf(u8, output, fragment) == null) {
            std.debug.print("\n=== Error Output ===\n{s}\n", .{output});
            std.debug.print("\n=== Missing Fragment ===\n{s}\n", .{fragment});
            return error.TestExpectedFragment;
        }
    }
}

// ============================================================================
// EXACT ERROR MESSAGE TESTS
// These tests verify complete error output against expected files
// ============================================================================

test "exact error: unknown identifier shows precise error with location" {
    const fixture = "tests/fixtures/errors/unknown_identifier.lazy";
    const actual = try captureErrorOutput(testing.allocator, fixture);
    defer testing.allocator.free(actual);

    const expected = try loadExpectedError(testing.allocator, fixture);
    defer testing.allocator.free(expected);

    try assertExactMatch(actual, expected);
}

test "exact error: unterminated string shows helpful message with quote suggestion" {
    const fixture = "tests/fixtures/errors/unterminated_string.lazy";
    const actual = try captureErrorOutput(testing.allocator, fixture);
    defer testing.allocator.free(actual);

    const expected = try loadExpectedError(testing.allocator, fixture);
    defer testing.allocator.free(expected);

    try assertExactMatch(actual, expected);
}

test "exact error: type mismatch shows expected and found types" {
    const fixture = "tests/fixtures/errors/type_mismatch_add.lazy";
    const actual = try captureErrorOutput(testing.allocator, fixture);
    defer testing.allocator.free(actual);

    const expected = try loadExpectedError(testing.allocator, fixture);
    defer testing.allocator.free(expected);

    try assertExactMatch(actual, expected);
}

test "exact error: unknown field lists available fields" {
    const fixture = "tests/fixtures/errors/unknown_field.lazy";
    const actual = try captureErrorOutput(testing.allocator, fixture);
    defer testing.allocator.free(actual);

    const expected = try loadExpectedError(testing.allocator, fixture);
    defer testing.allocator.free(expected);

    try assertExactMatch(actual, expected);
}

test "exact error: unexpected character shows location and character" {
    const fixture = "tests/fixtures/errors/unexpected_char.lazy";
    const actual = try captureErrorOutput(testing.allocator, fixture);
    defer testing.allocator.free(actual);

    const expected = try loadExpectedError(testing.allocator, fixture);
    defer testing.allocator.free(expected);

    try assertExactMatch(actual, expected);
}

test "exact error: pattern mismatch shows expected pattern" {
    const fixture = "tests/fixtures/errors/pattern_mismatch_tuple.lazy";
    const actual = try captureErrorOutput(testing.allocator, fixture);
    defer testing.allocator.free(actual);

    const expected = try loadExpectedError(testing.allocator, fixture);
    defer testing.allocator.free(expected);

    try assertExactMatch(actual, expected);
}

test "exact error: nested error shows inner location" {
    const fixture = "tests/fixtures/errors/nested_unknown_identifier.lazy";
    const actual = try captureErrorOutput(testing.allocator, fixture);
    defer testing.allocator.free(actual);

    const expected = try loadExpectedError(testing.allocator, fixture);
    defer testing.allocator.free(expected);

    try assertExactMatch(actual, expected);
}

test "exact error: cyclic reference shows both definition and reference on same line" {
    const fixture = "tests/fixtures/errors/cyclic_reference.lazy";
    const actual = try captureErrorOutput(testing.allocator, fixture);
    defer testing.allocator.free(actual);

    const expected = try loadExpectedError(testing.allocator, fixture);
    defer testing.allocator.free(expected);

    try assertExactMatch(actual, expected);
}

test "exact error: cyclic reference shows both definition and reference on different lines" {
    const fixture = "tests/fixtures/errors/cyclic_reference_multiline.lazy";
    const actual = try captureErrorOutput(testing.allocator, fixture);
    defer testing.allocator.free(actual);

    const expected = try loadExpectedError(testing.allocator, fixture);
    defer testing.allocator.free(expected);

    try assertExactMatch(actual, expected);
}

test "exact error: type mismatch on field access shows location with stack trace" {
    const fixture = "tests/fixtures/errors/type_mismatch_field_access.lazy";
    const actual = try captureErrorOutput(testing.allocator, fixture);
    defer testing.allocator.free(actual);

    const expected = try loadExpectedError(testing.allocator, fixture);
    defer testing.allocator.free(expected);

    try assertExactMatch(actual, expected);
}

// ============================================================================
// ERROR MESSAGE QUALITY TESTS
// These tests verify error messages contain helpful information
// ============================================================================

test "error messages include source location" {
    const output = try captureErrorOutput(testing.allocator, "tests/fixtures/errors/unknown_identifier.lazy");
    defer testing.allocator.free(output);

    // Should have the --> indicator showing file location
    try assertContains(output, &[_][]const u8{
        "-->",
        "unknown_identifier.lazy",
        "|", // Line gutter
    });
}

test "error messages include line number gutter" {
    const output = try captureErrorOutput(testing.allocator, "tests/fixtures/errors/unknown_identifier.lazy");
    defer testing.allocator.free(output);

    // Should show the actual source line with line number
    try assertContains(output, &[_][]const u8{
        "|",
        "unknownVar",
    });
}

test "error messages include caret pointing to error" {
    const output = try captureErrorOutput(testing.allocator, "tests/fixtures/errors/unknown_identifier.lazy");
    defer testing.allocator.free(output);

    // Should have ^ or similar marker
    const has_caret = std.mem.indexOf(u8, output, "^") != null or
        std.mem.indexOf(u8, output, "~") != null;

    if (!has_caret) {
        std.debug.print("\n=== Error Output ===\n{s}\n", .{output});
        return error.TestExpectedCaretMarker;
    }
}

test "error messages include helpful suggestions" {
    const output = try captureErrorOutput(testing.allocator, "tests/fixtures/errors/unknown_identifier.lazy");
    defer testing.allocator.free(output);

    // Should have a "help:" section
    try assertContains(output, &[_][]const u8{
        "help:",
    });
}

test "error messages for unknown fields list available fields" {
    const output = try captureErrorOutput(testing.allocator, "tests/fixtures/errors/unknown_field.lazy");
    defer testing.allocator.free(output);

    // Should show what fields ARE available
    try assertContains(output, &[_][]const u8{
        "name",
        "age",
    });
}

// ============================================================================
// ERROR MESSAGE FORMAT TESTS
// ============================================================================

test "error messages start with 'error:' label" {
    const output = try captureErrorOutput(testing.allocator, "tests/fixtures/errors/unknown_identifier.lazy");
    defer testing.allocator.free(output);

    if (!std.mem.startsWith(u8, output, "error:")) {
        std.debug.print("\n=== Error Output ===\n{s}\n", .{output});
        return error.TestExpectedErrorLabel;
    }
}

test "error messages include descriptive title" {
    const fixtures = [_]struct {
        file: []const u8,
        expected_title: []const u8,
    }{
        .{ .file = "tests/fixtures/errors/unknown_identifier.lazy", .expected_title = "Unknown identifier" },
        .{ .file = "tests/fixtures/errors/unknown_field.lazy", .expected_title = "Unknown field" },
        .{ .file = "tests/fixtures/errors/type_mismatch_add.lazy", .expected_title = "Type mismatch" },
        .{ .file = "tests/fixtures/errors/unterminated_string.lazy", .expected_title = "Unterminated string" },
    };

    for (fixtures) |fixture| {
        const output = try captureErrorOutput(testing.allocator, fixture.file);
        defer testing.allocator.free(output);

        try assertContains(output, &[_][]const u8{fixture.expected_title});
    }
}

// ============================================================================
// REGRESSION TEST
// Ensure all error fixtures produce proper formatted output
// ============================================================================

test "regression: all error fixtures produce non-empty, formatted output" {
    const fixtures = [_][]const u8{
        "tests/fixtures/errors/unterminated_string.lazy",
        "tests/fixtures/errors/unexpected_char.lazy",
        "tests/fixtures/errors/unknown_identifier.lazy",
        "tests/fixtures/errors/type_mismatch_add.lazy",
        "tests/fixtures/errors/type_mismatch_comparison.lazy",
        "tests/fixtures/errors/type_mismatch_field_access.lazy",
        "tests/fixtures/errors/unknown_field.lazy",
        "tests/fixtures/errors/module_not_found.lazy",
        "tests/fixtures/errors/not_a_function.lazy",
        "tests/fixtures/errors/unexpected_token.lazy",
        "tests/fixtures/errors/pattern_mismatch_tuple.lazy",
        "tests/fixtures/errors/pattern_mismatch_array.lazy",
        "tests/fixtures/errors/missing_closing_paren.lazy",
        "tests/fixtures/errors/cyclic_reference.lazy",
        "tests/fixtures/errors/cyclic_reference_multiline.lazy",
        "tests/fixtures/errors/nested_unknown_identifier.lazy",
    };

    for (fixtures) |fixture| {
        const output = try captureErrorOutput(testing.allocator, fixture);
        defer testing.allocator.free(output);

        // Every error must have:
        // 1. Non-empty output
        try testing.expect(output.len > 0);

        // 2. The word "error" (case-insensitive)
        var found_error = false;
        var i: usize = 0;
        while (i < output.len) : (i += 1) {
            if (i + 5 <= output.len) {
                const slice = output[i .. i + 5];
                if (std.ascii.eqlIgnoreCase(slice, "error")) {
                    found_error = true;
                    break;
                }
            }
        }
        try testing.expect(found_error);

        // 3. A "help:" section
        try testing.expect(std.mem.indexOf(u8, output, "help:") != null);
    }
}
