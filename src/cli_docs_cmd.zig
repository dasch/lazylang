//! Docs command handler for Lazylang CLI.
//!
//! Generates a single self-contained HTML documentation page from doc
//! comments in Lazylang modules.
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

        if (input_path != null) {
            try stderr.print("error: unexpected argument '{s}'\n", .{arg});
            return .{ .exit_code = 1 };
        }
        input_path = arg;
    }

    if (input_path == null) {
        input_path = "lib";
    }

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

    const stat = std.fs.cwd().statFile(input_path.?) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print("error: path not found: {s}\n", .{input_path.?});
            return .{ .exit_code = 1 };
        },
        else => return err,
    };

    if (stat.kind == .directory) {
        try docs.collectModulesFromDirectory(allocator, input_path.?, &modules_list, stdout);
    } else {
        try stdout.print("Extracting docs from {s}...\n", .{input_path.?});
        const module_info = try docs.extractModuleInfo(allocator, input_path.?);
        try modules_list.append(allocator, module_info);
    }

    // Sort modules alphabetically
    std.sort.insertion(docs.ModuleInfo, modules_list.items, {}, struct {
        fn lessThan(_: void, a: docs.ModuleInfo, b: docs.ModuleInfo) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    // Generate single self-contained HTML file
    const html_filename = try std.fmt.allocPrint(allocator, "{s}/index.html", .{output_dir});
    defer allocator.free(html_filename);

    var html_file = try std.fs.cwd().createFile(html_filename, .{});
    defer html_file.close();

    try docs.writeSinglePageDocs(html_file, modules_list.items, allocator);

    try stdout.print("Documentation generated: {s}\n", .{html_filename});
    return .{ .exit_code = 0 };
}
