//! Format command handler for Lazylang CLI.
//!
//! This module implements the 'format' subcommand which formats Lazylang
//! source code by normalizing whitespace and indentation.
//!
//! Usage: lazylang format <path>

const std = @import("std");
const formatter = @import("formatter.zig");

const cli_types = @import("cli_types.zig");
pub const CommandResult = cli_types.CommandResult;

pub fn runFormat(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    if (args.len == 0) {
        try stderr.print("error: missing file path\n", .{});
        try stderr.print("usage: lazy format <path>\n", .{});
        return .{ .exit_code = 1 };
    }

    if (args.len > 1) {
        try stderr.print("error: too many arguments\n", .{});
        try stderr.print("usage: lazy format <path>\n", .{});
        return .{ .exit_code = 1 };
    }

    const file_path = args[0];

    var format_output = formatter.formatFile(allocator, file_path) catch |err| {
        try stderr.print("error: failed to format file: {}\n", .{err});
        return .{ .exit_code = 1 };
    };
    defer format_output.deinit();

    try stdout.print("{s}", .{format_output.text});
    return .{ .exit_code = 0 };
}
