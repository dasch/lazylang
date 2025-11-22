const std = @import("std");
const cli_types = @import("cli_types.zig");
const docspec = @import("docspec.zig");

pub fn runDocSpec(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !cli_types.CommandResult {
    var path: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stderr.print(
                \\Test code examples in documentation comments (//=>).
                \\
                \\Usage:
                \\  lazy docspec                     Test all modules in stdlib/lib
                \\  lazy docspec <file>              Test specific file
                \\  lazy docspec <dir>               Test all files in directory
                \\
                \\Options:
                \\  -h, --help           Show this help message
                \\
                \\Examples:
                \\  lazy docspec
                \\  lazy docspec stdlib/lib
                \\  lazy docspec stdlib/lib/Array.lazy
                \\
            , .{});
            return .{ .exit_code = 0 };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (path != null) {
                try stderr.print("error: multiple paths specified\n", .{});
                return .{ .exit_code = 1 };
            }
            path = arg;
        } else {
            try stderr.print("error: unknown option '{s}'\n", .{arg});
            return .{ .exit_code = 1 };
        }
    }

    // Default to stdlib/lib if no path specified
    const target_path = path orelse "stdlib/lib";

    // Check if path is a file or directory
    const stat_info = std.fs.cwd().statFile(target_path) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print("error: path '{s}' not found\n", .{target_path});
        } else {
            try stderr.print("error: could not access '{s}': {s}\n", .{ target_path, @errorName(err) });
        }
        return .{ .exit_code = 1 };
    };

    var total_failed: usize = 0;

    if (stat_info.kind == .file) {
        // Test single file
        total_failed = try docspec.runModuleDocSpecs(allocator, target_path, stdout);
    } else if (stat_info.kind == .directory) {
        // Test all files in directory
        total_failed = try docspec.runDirectoryDocSpecs(allocator, target_path, stdout);
    } else {
        try stderr.print("error: '{s}' is not a file or directory\n", .{target_path});
        return .{ .exit_code = 1 };
    }

    if (total_failed > 0) {
        try stdout.print("\n{d} docspec(s) failed\n", .{total_failed});
        return .{ .exit_code = 1 };
    } else {
        try stdout.print("\nAll docspecs passed!\n", .{});
        return .{ .exit_code = 0 };
    }
}
