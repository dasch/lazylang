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
