//! Spec command handler for Lazylang CLI.
//!
//! This module implements the 'spec' subcommand which runs Lazylang test files.
//! Supports running individual tests by line number and colored output.
//!
//! Usage:
//!   lazylang spec                  - Run all specs in spec/ directory
//!   lazylang spec <dir>            - Run all specs in directory
//!   lazylang spec <file>           - Run specific spec file
//!   lazylang spec <file>:<line>    - Run specific test at line number

const std = @import("std");
const spec = @import("spec.zig");

const cli_types = @import("cli_types.zig");
pub const CommandResult = cli_types.CommandResult;

pub fn runSpec(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    // If no arguments, run all specs in spec/ directory
    if (args.len == 0) {
        const result = spec.runAllSpecs(allocator, "spec", stdout) catch |err| {
            try stderr.print("error: failed to run specs: {}\n", .{err});
            return .{ .exit_code = 1 };
        };
        return .{ .exit_code = result.exitCode() };
    }

    // If one argument, check if it's a directory or file
    if (args.len == 1) {
        const path_arg = args[0];

        // Check if the path contains a line number (format: path:line)
        var path = path_arg;
        var line_number: ?usize = null;

        if (std.mem.lastIndexOfScalar(u8, path_arg, ':')) |colon_idx| {
            // Try to parse the part after the colon as a line number
            const line_str = path_arg[colon_idx + 1 ..];
            if (std.fmt.parseInt(usize, line_str, 10)) |line| {
                path = path_arg[0..colon_idx];
                line_number = line;
            } else |_| {
                // Not a valid line number, treat the whole thing as a path
            }
        }

        // Check if it's a directory
        const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr.print("error: path not found: {s}\n", .{path});
                return .{ .exit_code = 1 };
            },
            else => return err,
        };

        if (stat.kind == .directory) {
            if (line_number != null) {
                try stderr.print("error: cannot specify line number for directory\n", .{});
                return .{ .exit_code = 1 };
            }
            // Run all specs in the directory recursively
            const result = spec.runAllSpecs(allocator, path, stdout) catch |err| {
                try stderr.print("error: failed to run specs: {}\n", .{err});
                return .{ .exit_code = 1 };
            };
            return .{ .exit_code = result.exitCode() };
        } else {
            // Run the specific spec file
            const result = spec.runSpec(allocator, path, line_number, stdout) catch |err| {
                try stderr.print("error: failed to run spec: {}\n", .{err});
                return .{ .exit_code = 1 };
            };
            return .{ .exit_code = result.exitCode() };
        }
    }

    try stderr.print("error: unexpected arguments\n", .{});
    return .{ .exit_code = 1 };
}
