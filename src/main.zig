const std = @import("std");
const cli = @import("cli.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_file = std.io.getStdOut().writer();
    var stderr_file = std.io.getStdErr().writer();

    var args_iter = std.process.args();
    defer args_iter.deinit();

    var args_list = std.ArrayList([]const u8).init(allocator);
    defer args_list.deinit();

    while (args_iter.next()) |arg| {
        try args_list.append(arg);
    }

    const result = try cli.run(allocator, args_list.items, stdout_file, stderr_file);
    std.process.exit(result.exit_code);
}
