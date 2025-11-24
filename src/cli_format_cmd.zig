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

/// Recursively find all .lazy files in a directory
fn findLazyFiles(allocator: std.mem.Allocator, dir_path: []const u8, files: *std.ArrayList([]const u8)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        return err;
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            if (std.mem.endsWith(u8, entry.basename, ".lazy")) {
                const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.path });
                try files.append(allocator, full_path);
            }
        }
    }
}

pub fn runFormat(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    var in_place = false;
    var paths = std.ArrayList([]const u8){};
    defer paths.deinit(allocator);

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
            try paths.append(allocator, arg);
        }
    }

    if (paths.items.len == 0) {
        try stderr.print("error: missing file path(s)\n", .{});
        try stderr.print("usage: lazy format [options] <path>...\n", .{});
        return .{ .exit_code = 1 };
    }

    // Resolve paths: expand directories into file lists
    var file_paths = std.ArrayList([]const u8){};
    defer {
        for (file_paths.items) |path| {
            allocator.free(path);
        }
        file_paths.deinit(allocator);
    }

    for (paths.items) |path| {
        const stat = std.fs.cwd().statFile(path) catch |err| {
            try stderr.print("error: failed to access path '{s}': {}\n", .{ path, err });
            return .{ .exit_code = 1 };
        };

        if (stat.kind == .directory) {
            // Recursively find all .lazy files
            findLazyFiles(allocator, path, &file_paths) catch |err| {
                try stderr.print("error: failed to scan directory '{s}': {}\n", .{ path, err });
                return .{ .exit_code = 1 };
            };
        } else {
            // Add the file directly (duplicate the string for consistent memory management)
            const path_copy = try allocator.dupe(u8, path);
            try file_paths.append(allocator, path_copy);
        }
    }

    if (file_paths.items.len == 0) {
        try stderr.print("error: no .lazy files found\n", .{});
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
