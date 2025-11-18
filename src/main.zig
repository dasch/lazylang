//! Main entry point for the Lazylang CLI.
//!
//! This is a thin wrapper that:
//! - Sets up the allocator
//! - Collects command-line arguments
//! - Buffers stdout/stderr for atomic output
//! - Delegates to cli.run() for command dispatch
//! - Exits with the appropriate exit code
//!
//! All actual CLI logic is in cli.zig.

const std = @import("std");
const cli = @import("cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer = std.ArrayList(u8){};
    defer stdout_buffer.deinit(allocator);
    var stderr_buffer = std.ArrayList(u8){};
    defer stderr_buffer.deinit(allocator);

    var args_iter = std.process.args();
    defer args_iter.deinit();

    var args_list = std.ArrayList([]const u8){};
    defer args_list.deinit(allocator);

    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    const result = try cli.run(
        allocator,
        args_list.items,
        stdout_buffer.writer(allocator),
        stderr_buffer.writer(allocator),
    );

    // Write buffered output to actual stdout/stderr
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

    _ = try stdout_file.writeAll(stdout_buffer.items);
    _ = try stderr_file.writeAll(stderr_buffer.items);

    std.process.exit(result.exit_code);
}
