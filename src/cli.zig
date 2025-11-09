const std = @import("std");
const evaluator = @import("eval.zig");

pub const CommandResult = struct {
    exit_code: u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    if (args.len <= 1) {
        try stderr.print("error: missing subcommand\n", .{});
        return .{ .exit_code = 1 };
    }

    const subcommand = args[1];
    if (std.mem.eql(u8, subcommand, "eval")) {
        return try runEval(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "expr")) {
        return try runExpr(allocator, args[2..], stdout, stderr);
    }

    try stderr.print("error: unknown subcommand '{s}'\n", .{subcommand});
    return .{ .exit_code = 1 };
}

fn runEval(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    var expression: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--expr") or std.mem.eql(u8, arg, "-e")) {
            if (index + 1 >= args.len) {
                try stderr.print("error: --expr requires a value\n", .{});
                return .{ .exit_code = 1 };
            }
            expression = args[index + 1];
            index += 1;
            continue;
        }

        if (expression != null) {
            try stderr.print("error: unexpected argument '{s}'\n", .{arg});
            return .{ .exit_code = 1 };
        }
        expression = arg;
    }

    if (expression == null) {
        try stderr.print("error: missing expression. provide --expr <code>\n", .{});
        return .{ .exit_code = 1 };
    }

    var eval_output = try evaluator.evalInline(allocator, expression.?);
    defer eval_output.deinit();

    try stdout.print("{s}\n", .{eval_output.text});
    return .{ .exit_code = 0 };
}

fn runExpr(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    if (args.len == 0) {
        try stderr.print("error: missing file path\n", .{});
        return .{ .exit_code = 1 };
    }

    const file_path = args[0];
    if (args.len > 1) {
        try stderr.print("error: unexpected argument '{s}'\n", .{args[1]});
        return .{ .exit_code = 1 };
    }

    var eval_output = try evaluator.evalFile(allocator, file_path);
    defer eval_output.deinit();

    try stdout.print("{s}\n", .{eval_output.text});
    return .{ .exit_code = 0 };
}
