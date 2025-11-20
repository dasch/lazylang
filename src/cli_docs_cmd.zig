//! Docs command handler for Lazylang CLI.
//!
//! This module implements the 'docs' subcommand which generates HTML
//! documentation from doc comments in Lazylang modules.
//!
//! Usage:
//!   lazylang docs                    - Generate docs from lib/ directory
//!   lazylang docs <path>             - Generate docs from specific file/dir
//!   lazylang docs --output <dir>     - Specify output directory (default: docs/)

const std = @import("std");
const docs = @import("docs.zig");

const cli_types = @import("cli_types.zig");
pub const CommandResult = cli_types.CommandResult;

pub fn runDocs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    var output_dir: []const u8 = "docs";
    var input_path: ?[]const u8 = null;
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            if (index + 1 >= args.len) {
                try stderr.print("error: --output requires a value\n", .{});
                return .{ .exit_code = 1 };
            }
            output_dir = args[index + 1];
            index += 1;
            continue;
        }

        // Positional argument - treat as input path
        if (input_path != null) {
            try stderr.print("error: unexpected argument '{s}'\n", .{arg});
            return .{ .exit_code = 1 };
        }
        input_path = arg;
    }

    // Default to "lib" directory if no input path specified
    if (input_path == null) {
        input_path = "lib";
    }

    // Create output directory if it doesn't exist
    std.fs.cwd().makePath(output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Collect all module info
    var modules_list = std.ArrayList(docs.ModuleInfo){};
    defer {
        for (modules_list.items) |module| {
            allocator.free(module.name);
            for (module.items) |item| {
                allocator.free(item.name);
                allocator.free(item.signature);
                allocator.free(item.doc);
            }
            allocator.free(module.items);
        }
        modules_list.deinit(allocator);
    }

    // Check if input is a directory or file
    const stat = std.fs.cwd().statFile(input_path.?) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print("error: path not found: {s}\n", .{input_path.?});
            return .{ .exit_code = 1 };
        },
        else => return err,
    };

    if (stat.kind == .directory) {
        // Collect all modules from directory
        try docs.collectModulesFromDirectory(allocator, input_path.?, &modules_list, stdout);
    } else {
        // Collect single module
        try stdout.print("Extracting docs from {s}...\n", .{input_path.?});
        const module_info = try docs.extractModuleInfo(allocator, input_path.?);
        try modules_list.append(allocator, module_info);
    }

    // Generate index.html
    try docs.generateIndexHtml(allocator, modules_list.items, output_dir);

    // Generate HTML for each module
    for (modules_list.items) |module| {
        try stdout.print("Generating HTML for {s}...\n", .{module.name});
        try docs.generateModuleHtml(allocator, module, modules_list.items, output_dir);
    }

    try stdout.print("Documentation generated in {s}/\n", .{output_dir});
    return .{ .exit_code = 0 };
}
