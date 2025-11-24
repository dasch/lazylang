//! Format command handler for Lazylang CLI.
//!
//! This module implements the 'format' subcommand which formats Lazylang
//! source code by normalizing whitespace and indentation.
//!
//! Usage: lazy format [options] <path>...

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
    var in_place = false;
    var file_paths = std.ArrayList([]const u8){};
    defer file_paths.deinit(allocator);

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--in-place")) {
            in_place = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("error: unknown flag '{s}'\n", .{arg});
            try stderr.print("usage: lazy format [options] <path>...\n", .{});
            return .{ .exit_code = 1 };
        } else {
            try file_paths.append(allocator, arg);
        }
    }

    if (file_paths.items.len == 0) {
        try stderr.print("error: missing file path(s)\n", .{});
        try stderr.print("usage: lazy format [options] <path>...\n", .{});
        return .{ .exit_code = 1 };
    }

    // Process each file
    for (file_paths.items, 0..) |file_path, idx| {
        var format_output = formatter.formatFile(allocator, file_path) catch |err| {
            try stderr.print("error: failed to format file '{s}': {}\n", .{ file_path, err });
            return .{ .exit_code = 1 };
        };
        defer format_output.deinit();

        if (in_place) {
            // Write formatted output back to the file
            const file = std.fs.cwd().openFile(file_path, .{ .mode = .write_only }) catch |err| {
                try stderr.print("error: failed to open file '{s}' for writing: {}\n", .{ file_path, err });
                return .{ .exit_code = 1 };
            };
            defer file.close();

            // Truncate the file first
            try file.setEndPos(0);
            try file.seekTo(0);

            file.writeAll(format_output.text) catch |err| {
                try stderr.print("error: failed to write to file '{s}': {}\n", .{ file_path, err });
                return .{ .exit_code = 1 };
            };
        } else {
            // Print to stdout
            try stdout.print("{s}", .{format_output.text});

            // Add blank line between files (but not after the last one)
            if (idx < file_paths.items.len - 1) {
                try stdout.print("\n", .{});
            }
        }
    }

    return .{ .exit_code = 0 };
}
