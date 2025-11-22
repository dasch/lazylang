const std = @import("std");
const evaluator = @import("eval.zig");

/// Find the project root by searching up for build.zig or checking if stdlib/lib exists
fn findProjectRoot(allocator: std.mem.Allocator, start_path: []const u8) ![]const u8 {
    // Get absolute path of start_path
    const abs_path = try std.fs.cwd().realpathAlloc(allocator, start_path);
    defer allocator.free(abs_path);

    // Start from the directory containing the file (or the directory itself if start_path is a dir)
    var current = std.fs.path.dirname(abs_path) orelse abs_path;

    while (true) {
        // Check if stdlib/lib exists relative to this directory
        var dir = std.fs.cwd().openDir(current, .{}) catch break;
        defer dir.close();

        const stdlib_path = try std.fs.path.join(allocator, &[_][]const u8{ current, "stdlib", "lib" });
        defer allocator.free(stdlib_path);

        std.fs.accessAbsolute(stdlib_path, .{}) catch {
            // stdlib/lib doesn't exist here, try parent
            const parent = std.fs.path.dirname(current) orelse break;
            if (std.mem.eql(u8, parent, current)) break; // Reached root
            current = parent;
            continue;
        };

        // Found it!
        return try allocator.dupe(u8, current);
    }

    // If we couldn't find project root, just use current working directory
    return try std.fs.cwd().realpathAlloc(allocator, ".");
}

const DocSpec = struct {
    code: []const u8,
    expected: []const u8,
    line_number: usize,
    module_name: []const u8,
    function_name: ?[]const u8,
    module_path: ?[]const u8, // Path to the module file being documented
};

const DocSpecResult = struct {
    passed: bool,
    spec: DocSpec,
    actual_value: ?[]const u8, // Only populated on failure
    error_message: ?[]const u8, // Only populated on error
};

/// Extract docspecs from a documentation comment
fn extractDocSpecs(
    allocator: std.mem.Allocator,
    doc_comment: []const u8,
    module_name: []const u8,
    function_name: ?[]const u8,
    base_line: usize,
    module_path: ?[]const u8,
) !std.ArrayListUnmanaged(DocSpec) {
    var specs = std.ArrayListUnmanaged(DocSpec){};
    errdefer specs.deinit(allocator);

    var lines = std.mem.splitScalar(u8, doc_comment, '\n');
    var line_num: usize = base_line;
    var pending_code: ?[]const u8 = null;
    var pending_line: usize = 0;

    while (lines.next()) |line| : (line_num += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Check if this line has //=> on it
        if (std.mem.indexOf(u8, trimmed, "//=>")) |arrow_idx| {
            const before_arrow = std.mem.trimRight(u8, trimmed[0..arrow_idx], " \t");
            const after_arrow = std.mem.trimLeft(u8, trimmed[arrow_idx + 4 ..], " \t");

            // Check if this is a continuation line (starts with backslash)
            const is_continuation = before_arrow.len > 0 and before_arrow[0] == '\\';

            if (before_arrow.len > 0 and !is_continuation) {
                // Inline format: code //=> expected (no backslash)
                try specs.append(allocator, .{
                    .code = try allocator.dupe(u8, before_arrow),
                    .expected = try allocator.dupe(u8, after_arrow),
                    .line_number = line_num,
                    .module_name = try allocator.dupe(u8, module_name),
                    .function_name = if (function_name) |fn_name| try allocator.dupe(u8, fn_name) else null,
                    .module_path = if (module_path) |path| try allocator.dupe(u8, path) else null,
                });
                pending_code = null;
            } else if (pending_code) |code| {
                // Multi-line format: use pending code
                // If current line has code before arrow (like backslash continuation), append it WITH the backslash
                var full_code: []const u8 = code;
                if (is_continuation) {
                    const continuation_part = std.mem.trimLeft(u8, before_arrow[1..], " \t");
                    full_code = try std.fmt.allocPrint(allocator, "{s} \\ {s}", .{ code, continuation_part });
                    allocator.free(code);
                }

                try specs.append(allocator, .{
                    .code = full_code,
                    .expected = try allocator.dupe(u8, after_arrow),
                    .line_number = pending_line,
                    .module_name = try allocator.dupe(u8, module_name),
                    .function_name = if (function_name) |fn_name| try allocator.dupe(u8, fn_name) else null,
                    .module_path = if (module_path) |path| try allocator.dupe(u8, path) else null,
                });
                pending_code = null;
            }
        } else if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "//")) {
            // Check if this is a continuation line
            if (trimmed[0] == '\\' and pending_code != null) {
                // Continuation line - append to pending code WITH the backslash
                const old_code = pending_code.?;
                const continuation_part = std.mem.trimLeft(u8, trimmed[1..], " \t");
                pending_code = try std.fmt.allocPrint(allocator, "{s} \\ {s}", .{ old_code, continuation_part });
                allocator.free(old_code);
            } else {
                // New code line - store it in case the next line has //=>
                if (pending_code) |old| allocator.free(old);
                pending_code = try allocator.dupe(u8, trimmed);
                pending_line = line_num;
            }
        }
    }

    // Clean up any remaining pending code
    if (pending_code) |code| {
        allocator.free(code);
    }

    return specs;
}

/// Extract all docspecs from a module file
pub fn extractModuleDocSpecs(
    allocator: std.mem.Allocator,
    input_path: []const u8,
) !std.ArrayListUnmanaged(DocSpec) {
    const source = try std.fs.cwd().readFileAlloc(allocator, input_path, 100 * 1024 * 1024);
    defer allocator.free(source);

    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var parser = try evaluator.Parser.init(arena, source);
    const expression = try parser.parse();

    const module_name = std.fs.path.stem(input_path);
    var all_specs = std.ArrayListUnmanaged(DocSpec){};
    errdefer all_specs.deinit(allocator);

    // Extract module-level docspecs
    switch (expression.data) {
        .object => |obj| {
            if (obj.module_doc) |module_doc| {
                var module_specs = try extractDocSpecs(allocator, module_doc, module_name, null, 1, input_path);
                defer module_specs.deinit(allocator);
                try all_specs.appendSlice(allocator, module_specs.items);
            }

            // Extract function-level docspecs
            for (obj.fields) |field| {
                const static_key = switch (field.key) {
                    .static => |k| k,
                    .dynamic => continue,
                };

                if (field.doc) |doc| {
                    var func_specs = try extractDocSpecs(allocator, doc, module_name, static_key, 1, input_path);
                    defer func_specs.deinit(allocator);
                    try all_specs.appendSlice(allocator, func_specs.items);
                }
            }
        },
        else => {},
    }

    return all_specs;
}

/// Run a single docspec and return the result
fn runDocSpec(
    allocator: std.mem.Allocator,
    spec: DocSpec,
    project_root: []const u8,
) !DocSpecResult {
    // Save current directory and change to project root
    // This is needed because module resolution uses paths relative to cwd
    const saved_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(saved_cwd);

    try std.posix.chdir(project_root);
    defer std.posix.chdir(saved_cwd) catch {};

    // Evaluate the code with project root as current directory (so stdlib modules can be found)
    var actual_result = evaluator.evalInlineWithValueAndDir(allocator, spec.code, project_root) catch |err| {
        const error_msg = try std.fmt.allocPrint(allocator, "Evaluation failed with error: {s}", .{@errorName(err)});
        return DocSpecResult{
            .passed = false,
            .spec = spec,
            .actual_value = null,
            .error_message = error_msg,
        };
    };
    defer actual_result.deinit();

    // Check if there was an error stored in the result
    if (actual_result.err) |err| {
        const error_msg = try std.fmt.allocPrint(allocator, "Evaluation failed with error: {s}", .{@errorName(err)});
        return DocSpecResult{
            .passed = false,
            .spec = spec,
            .actual_value = null,
            .error_message = error_msg,
        };
    }

    // Format the actual value
    const actual_str = try evaluator.formatValue(allocator, actual_result.value);
    defer allocator.free(actual_str);

    // Evaluate the expected value with project root as current directory
    var expected_result = evaluator.evalInlineWithValueAndDir(allocator, spec.expected, project_root) catch |err| {
        const error_msg = try std.fmt.allocPrint(allocator, "Error evaluating expected value '{s}': {s}", .{ spec.expected, @errorName(err) });
        return DocSpecResult{
            .passed = false,
            .spec = spec,
            .actual_value = try allocator.dupe(u8, actual_str),
            .error_message = error_msg,
        };
    };
    defer expected_result.deinit();

    // Check if there was an error in the expected result
    if (expected_result.err) |err| {
        const error_msg = try std.fmt.allocPrint(allocator, "Error evaluating expected value '{s}': {s}", .{ spec.expected, @errorName(err) });
        return DocSpecResult{
            .passed = false,
            .spec = spec,
            .actual_value = try allocator.dupe(u8, actual_str),
            .error_message = error_msg,
        };
    }

    // Format the expected value
    const expected_str = try evaluator.formatValue(allocator, expected_result.value);
    defer allocator.free(expected_str);

    // Compare the values
    const passed = std.mem.eql(u8, actual_str, expected_str);

    return DocSpecResult{
        .passed = passed,
        .spec = spec,
        .actual_value = if (!passed) try allocator.dupe(u8, actual_str) else null,
        .error_message = null,
    };
}

/// Run all docspecs for a module file
pub fn runModuleDocSpecs(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    writer: anytype,
) !usize {
    // Find project root for module resolution
    const project_root = try findProjectRoot(allocator, input_path);
    defer allocator.free(project_root);

    var specs = try extractModuleDocSpecs(allocator, input_path);
    defer {
        // Free each spec's allocated strings
        for (specs.items) |spec| {
            allocator.free(spec.code);
            allocator.free(spec.expected);
            allocator.free(spec.module_name);
            if (spec.function_name) |fn_name| {
                allocator.free(fn_name);
            }
        }
        specs.deinit(allocator);
    }

    if (specs.items.len == 0) {
        return 0;
    }

    const module_name = if (specs.items.len > 0) specs.items[0].module_name else std.fs.path.stem(input_path);
    try writer.print("\nTesting {s}...\n", .{module_name});

    var failed_count: usize = 0;

    for (specs.items) |spec| {
        const result = try runDocSpec(allocator, spec, project_root);
        defer {
            if (result.actual_value) |val| allocator.free(val);
            if (result.error_message) |msg| allocator.free(msg);
        }

        if (result.passed) {
            try writer.print("  ✓ ", .{});
            if (spec.function_name) |fname| {
                try writer.print("{s}.", .{spec.module_name});
                try writer.print("{s}", .{fname});
            } else {
                try writer.print("{s} (module docs)", .{spec.module_name});
            }
            try writer.print(" (line {d})\n", .{spec.line_number});
        } else {
            failed_count += 1;
            try writer.print("  ✗ ", .{});
            if (spec.function_name) |fname| {
                try writer.print("{s}.", .{spec.module_name});
                try writer.print("{s}", .{fname});
            } else {
                try writer.print("{s} (module docs)", .{spec.module_name});
            }
            try writer.print(" (line {d})\n", .{spec.line_number});

            try writer.print("    Code: {s}\n", .{spec.code});

            if (result.error_message) |msg| {
                try writer.print("    Error: {s}\n", .{msg});
            } else if (result.actual_value) |actual| {
                try writer.print("    Expected: {s}\n", .{spec.expected});
                try writer.print("    Actual:   {s}\n", .{actual});
            }
        }
    }

    return failed_count;
}

/// Run docspecs for all .lazy files in a directory
pub fn runDirectoryDocSpecs(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    writer: anytype,
) !usize {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();

    var total_failed: usize = 0;

    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".lazy")) continue;

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(full_path);

        const failed = try runModuleDocSpecs(allocator, full_path, writer);
        total_failed += failed;
    }

    return total_failed;
}
