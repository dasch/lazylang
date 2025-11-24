const std = @import("std");
const cli = @import("cli");

const TestOutput = struct {
    result: cli.CommandResult,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *TestOutput) void {
        const allocator = std.testing.allocator;
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

fn runCli(args: []const []const u8) !TestOutput {
    const allocator = std.testing.allocator;

    var stdout_buffer = std.ArrayList(u8){};
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8){};
    defer stderr_buffer.deinit(allocator);

    const result = try cli.run(
        allocator,
        args,
        stdout_buffer.writer(allocator),
        stderr_buffer.writer(allocator),
    );

    const stdout_owned = try stdout_buffer.toOwnedSlice(allocator);
    const stderr_owned = try stderr_buffer.toOwnedSlice(allocator);

    return .{
        .result = result,
        .stdout = stdout_owned,
        .stderr = stderr_owned,
    };
}

test "eval command requires a file path or --expr argument" {
    const args = [_][]const u8{ "lazylang", "eval" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expectStringStartsWith(outcome.stderr, "error: missing file path or --expr option");
}

test "eval command with --expr prints evaluator output" {
    const args = [_][]const u8{ "lazylang", "eval", "--expr", "42" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expectEqualStrings("42\n", outcome.stdout);
    try std.testing.expectEqualStrings("", outcome.stderr);
}

test "eval command with file path evaluates lazylang file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_name = "example.lazy";
    var file = try tmp.dir.createFile(file_name, .{ .read = true });
    try file.writeAll("(x -> x + 1) 41");
    file.close();

    const file_path = try tmp.dir.realpathAlloc(allocator, file_name);
    defer allocator.free(file_path);

    const args = [_][]const u8{ "lazylang", "eval", file_path };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expectEqualStrings("42\n", outcome.stdout);
    try std.testing.expectEqualStrings("", outcome.stderr);
}

test "eval command rejects both --expr and file path" {
    const args = [_][]const u8{ "lazylang", "eval", "--expr", "42", "file.lazy" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expectStringStartsWith(outcome.stderr, "error: cannot specify both --expr and a file path");
}

test "run command requires a file path" {
    const args = [_][]const u8{ "lazylang", "run" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expectStringStartsWith(outcome.stderr, "error: missing file path");
}

test "run command executes function with empty args" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_name = "hello.lazy";
    var file = try tmp.dir.createFile(file_name, .{ .read = true });
    try file.writeAll("{ args, env } -> args");
    file.close();

    const file_path = try tmp.dir.realpathAlloc(allocator, file_name);
    defer allocator.free(file_path);

    const args = [_][]const u8{ "lazylang", "run", file_path };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expectEqualStrings("[]\n", outcome.stdout);
    try std.testing.expectEqualStrings("", outcome.stderr);
}

test "run command passes args after --" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_name = "hello.lazy";
    var file = try tmp.dir.createFile(file_name, .{ .read = true });
    try file.writeAll("{ args, env } -> args");
    file.close();

    const file_path = try tmp.dir.realpathAlloc(allocator, file_name);
    defer allocator.free(file_path);

    const args = [_][]const u8{ "lazylang", "run", file_path, "--", "a", "b", "c" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expectEqualStrings("[\"a\", \"b\", \"c\"]\n", outcome.stdout);
    try std.testing.expectEqualStrings("", outcome.stderr);
}

test "run command errors if file does not evaluate to function" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_name = "notfunc.lazy";
    var file = try tmp.dir.createFile(file_name, .{ .read = true });
    try file.writeAll("42");
    file.close();

    const file_path = try tmp.dir.realpathAlloc(allocator, file_name);
    defer allocator.free(file_path);

    const args = [_][]const u8{ "lazylang", "run", file_path };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expectStringStartsWith(outcome.stderr, "error: file must evaluate to a function");
}

test "run command passes environment variables" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_name = "getenv.lazy";
    var file = try tmp.dir.createFile(file_name, .{ .read = true });
    // Access a specific env var that we know exists
    try file.writeAll("{ args, env } -> env");
    file.close();

    const file_path = try tmp.dir.realpathAlloc(allocator, file_name);
    defer allocator.free(file_path);

    const args = [_][]const u8{ "lazylang", "run", file_path };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    // We just verify that env is an object (starts with '{')
    try std.testing.expect(std.mem.startsWith(u8, outcome.stdout, "{"));
    try std.testing.expectEqualStrings("", outcome.stderr);
}

test "eval --manifest writes string values to files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test expression that returns an object with string values
    const args = [_][]const u8{ "lazylang", "eval", "--expr", "{ [\"file1.txt\"]: \"content1\", [\"file2.txt\"]: \"content2\" }", "--manifest" };

    // Change to temp directory
    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch {};

    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, "Wrote file1.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, "Wrote file2.txt") != null);

    // Verify files were created with correct content
    const file1_content = try tmp.dir.readFileAlloc(allocator, "file1.txt", 1024);
    defer allocator.free(file1_content);
    try std.testing.expectEqualStrings("content1", file1_content);

    const file2_content = try tmp.dir.readFileAlloc(allocator, "file2.txt", 1024);
    defer allocator.free(file2_content);
    try std.testing.expectEqualStrings("content2", file2_content);
}

test "eval --manifest --json writes JSON-encoded values to files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test expression that returns an object with non-string values
    const args = [_][]const u8{ "lazylang", "eval", "--expr", "{ [\"data.json\"]: { x: 1, y: 2 } }", "--manifest", "--json" };

    // Change to temp directory
    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch {};

    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, "Wrote data.json") != null);

    // Verify file was created with JSON content
    const file_content = try tmp.dir.readFileAlloc(allocator, "data.json", 1024);
    defer allocator.free(file_content);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "\"x\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "\"y\":2") != null);
}

test "eval --manifest --yaml writes YAML-encoded values to files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create test expression that returns an object with non-string values
    const args = [_][]const u8{ "lazylang", "eval", "--expr", "{ [\"data.yaml\"]: [1, 2, 3] }", "--manifest", "--yaml" };

    // Change to temp directory
    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch {};

    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, "Wrote data.yaml") != null);

    // Verify file was created with YAML content
    const file_content = try tmp.dir.readFileAlloc(allocator, "data.yaml", 1024);
    defer allocator.free(file_content);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "- 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "- 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "- 3") != null);
}

test "eval --manifest errors when output is not an object" {
    const args = [_][]const u8{ "lazylang", "eval", "--expr", "[1, 2, 3]", "--manifest" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "error: --manifest requires output to be an object") != null);
}

test "eval --manifest errors when value is not a string in pretty mode" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const args = [_][]const u8{ "lazylang", "eval", "--expr", "{ [\"file.txt\"]: 42 }", "--manifest" };

    // Change to temp directory
    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch {};

    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "--manifest without --json or --yaml requires all values to be strings") != null);
}

test "eval --json errors on function" {
    const args = [_][]const u8{ "lazylang", "eval", "--expr", "x -> x + 1", "--json" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Cannot represent function in JSON output") != null);
}

test "eval --yaml errors on function" {
    const args = [_][]const u8{ "lazylang", "eval", "--expr", "x -> x + 1", "--yaml" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Cannot represent function in YAML output") != null);
}

test "eval --json errors on function in object" {
    const args = [_][]const u8{ "lazylang", "eval", "--expr", "{ foo: (x -> x + 1) }", "--json" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Cannot represent function in JSON output") != null);
}

test "eval --yaml errors on function in array" {
    const args = [_][]const u8{ "lazylang", "eval", "--expr", "[1, (x -> x + 1), 3]", "--yaml" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Cannot represent function in YAML output") != null);
}

// Help command tests

test "no subcommand shows help" {
    const args = [_][]const u8{"lazylang"};
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Lazylang - A pure, lazy functional language") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "eval") != null);
}

test "help command shows help" {
    const args = [_][]const u8{ "lazylang", "help" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Lazylang - A pure, lazy functional language") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Commands:") != null);
}

test "help eval shows eval help" {
    const args = [_][]const u8{ "lazylang", "help", "eval" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Evaluate a Lazylang file") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "--expr") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "--json") != null);
}

test "eval -h shows eval help" {
    const args = [_][]const u8{ "lazylang", "eval", "-h" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Evaluate a Lazylang file") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "--expr") != null);
}

test "run --help shows run help" {
    const args = [_][]const u8{ "lazylang", "run", "--help" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Execute a Lazylang program") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "args") != null);
}

test "help unknown_command shows error" {
    const args = [_][]const u8{ "lazylang", "help", "unknown" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "error: unknown command 'unknown'") != null);
}

test "unknown subcommand shows error and help" {
    const args = [_][]const u8{ "lazylang", "invalid" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expectEqualStrings("", outcome.stdout);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "error: unknown subcommand 'invalid'") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Commands:") != null);
}

// Spec command tests

test "spec -h shows spec help" {
    const args = [_][]const u8{ "lazylang", "spec", "-h" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Run Lazylang test files") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "--verbose") != null);
}

test "spec with invalid flag shows error" {
    const args = [_][]const u8{ "lazylang", "spec", "--invalid" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "error: unknown flag '--invalid'") != null);
}

test "spec with nonexistent path shows error" {
    const args = [_][]const u8{ "lazylang", "spec", "/nonexistent/path.lazy" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "error: path not found") != null);
}

test "spec with directory line number shows error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const path_with_line = try std.fmt.allocPrint(allocator, "{s}:42", .{tmp_path});
    defer allocator.free(path_with_line);

    const args = [_][]const u8{ "lazylang", "spec", path_with_line };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "cannot specify line number for directory") != null);
}

// Format command tests

test "format -h shows format help" {
    const args = [_][]const u8{ "lazylang", "format", "-h" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Format Lazylang source code") != null);
}

test "format requires a file path" {
    const args = [_][]const u8{ "lazylang", "format" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "error: missing file path") != null);
}

test "format supports multiple files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create first file
    const file1_name = "file1.lazy";
    var file1 = try tmp.dir.createFile(file1_name, .{});
    try file1.writeAll("{x:1}");
    file1.close();

    // Create second file
    const file2_name = "file2.lazy";
    var file2 = try tmp.dir.createFile(file2_name, .{});
    try file2.writeAll("[1,2,3]");
    file2.close();

    const file1_path = try tmp.dir.realpathAlloc(allocator, file1_name);
    defer allocator.free(file1_path);
    const file2_path = try tmp.dir.realpathAlloc(allocator, file2_name);
    defer allocator.free(file2_path);

    const args = [_][]const u8{ "lazylang", "format", file1_path, file2_path };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    // Should have both formatted outputs with blank line between
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, "{ x: 1 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stdout, "[1, 2, 3]") != null);
}

test "format outputs formatted code" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_name = "unformatted.lazy";
    var file = try tmp.dir.createFile(file_name, .{ .read = true });
    try file.writeAll("{  x:   1,   y:   2  }");
    file.close();

    const file_path = try tmp.dir.realpathAlloc(allocator, file_name);
    defer allocator.free(file_path);

    const args = [_][]const u8{ "lazylang", "format", file_path };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    // Formatted output should have normalized spacing
    try std.testing.expect(outcome.stdout.len > 0);
}

// Docs command tests

test "docs -h shows docs help" {
    const args = [_][]const u8{ "lazylang", "docs", "-h" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Generate HTML documentation") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "--output") != null);
}

test "docs with --output requires a value" {
    const args = [_][]const u8{ "lazylang", "docs", "--output" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "error: --output requires a value") != null);
}

test "docs with nonexistent path shows error" {
    const args = [_][]const u8{ "lazylang", "docs", "/nonexistent/path" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 1), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "error: path not found") != null);
}

test "spec --help shows spec help" {
    const args = [_][]const u8{ "lazylang", "spec", "--help" };
    var outcome = try runCli(&args);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u8, 0), outcome.result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "Run Lazylang test files") != null);
}
