const std = @import("std");
const cli = @import("cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    var stdout_writer = stdout.writer(&stdout_buffer);
    var stderr_writer = stderr.writer(&stderr_buffer);

    const stdout_file = &stdout_writer.interface;
    const stderr_file = &stderr_writer.interface;

    var args_iter = std.process.args();
    defer args_iter.deinit();

    var args_list = std.ArrayList([]const u8){};
    defer args_list.deinit(allocator);

    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    const result = try cli.run(allocator, args_list.items, stdout_file, stderr_file);

    // Flush output buffers before exiting
    try stdout_file.flush();
    try stderr_file.flush();

    std.process.exit(result.exit_code);
}
