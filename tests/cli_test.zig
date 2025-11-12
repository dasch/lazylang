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
