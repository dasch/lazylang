//! Module resolution for Lazylang imports.
//!
//! This module handles the resolution of import paths to actual files on disk:
//!
//! - collectLazyPaths: Parses LAZYLANG_PATH environment variable
//! - normalizedImportPath: Adds .lazy extension if needed
//! - openImportFile: Searches for module files in multiple locations
//!
//! Import search order:
//! 1. Relative to current file's directory (if current_dir provided)
//! 2. Relative to current working directory
//! 3. Each path in LAZYLANG_PATH (colon-separated on Unix, semicolon on Windows)
//! 4. Default: stdlib/lib
//!
//! The actual module loading and evaluation happens in the evaluator.

const std = @import("std");
const error_context = @import("error_context.zig");
const value = @import("value.zig");

// Re-export needed types
pub const EvalContext = value.EvalContext;
pub const EvalError = value.EvalError;

/// Module file handle for imports
pub const ModuleFile = struct {
    path: []u8,
    file: std.fs.File,
};

/// Collect module search paths from LAZYLANG_PATH environment variable.
/// Always includes stdlib/lib as the default search path.
/// Returns paths in the order they should be searched.
pub fn collectLazyPaths(arena: std.mem.Allocator) EvalError![][]const u8 {
    var list = std.ArrayList([]const u8){};
    defer list.deinit(arena);

    // Always include ./stdlib/lib as a default search path
    const default_lib = try arena.dupe(u8, "stdlib/lib");
    try list.append(arena, default_lib);

    const env_value = std.process.getEnvVarOwned(arena, "LAZYLANG_PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return try list.toOwnedSlice(arena),
        else => return err,
    };

    if (env_value.len == 0) {
        return try list.toOwnedSlice(arena);
    }

    var parts = std.mem.splitScalar(u8, env_value, std.fs.path.delimiter);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const copy = try arena.dupe(u8, part);
        try list.append(arena, copy);
    }

    return try list.toOwnedSlice(arena);
}

/// Normalize an import path by adding .lazy extension if not present.
/// Caller owns the returned memory.
pub fn normalizedImportPath(allocator: std.mem.Allocator, import_path: []const u8) ![]u8 {
    if (std.fs.path.extension(import_path).len == 0) {
        return try std.fmt.allocPrint(allocator, "{s}.lazy", .{import_path});
    }
    return try allocator.dupe(u8, import_path);
}

/// Open an import file by searching in multiple locations.
/// Search order:
/// 1. Relative to current_dir (if provided)
/// 2. Relative to cwd
/// 3. Each path in ctx.lazy_paths
/// Returns the opened file and its full path.
/// Sets error context on failure.
pub fn openImportFile(ctx: *const EvalContext, import_path: []const u8, current_dir: ?[]const u8) EvalError!ModuleFile {
    const normalized = try normalizedImportPath(ctx.allocator, import_path);
    errdefer ctx.allocator.free(normalized);

    // 1. Try relative to current file's directory
    if (current_dir) |dir| {
        const candidate = try std.fs.path.join(ctx.allocator, &.{ dir, normalized });
        const maybe_file = std.fs.cwd().openFile(candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (maybe_file) |file| {
            ctx.allocator.free(normalized);
            return .{ .path = candidate, .file = file };
        }
        ctx.allocator.free(candidate);
    }

    // 2. Try relative to current working directory
    const relative_file = std.fs.cwd().openFile(normalized, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (relative_file) |file| {
        return .{ .path = normalized, .file = file };
    }

    // 3. Try each path in LAZYLANG_PATH
    for (ctx.lazy_paths) |base| {
        const candidate = try std.fs.path.join(ctx.allocator, &.{ base, normalized });
        const maybe_file = std.fs.cwd().openFile(candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (maybe_file) |file| {
            ctx.allocator.free(normalized);
            return .{ .path = candidate, .file = file };
        }
        ctx.allocator.free(candidate);
    }

    // Module not found - set error context
    if (ctx.error_ctx) |err_ctx| {
        const module_name_copy = try err_ctx.allocator.dupe(u8, import_path);
        err_ctx.setErrorData(.{ .module_not_found = .{ .module_name = module_name_copy } });
    }

    return error.ModuleNotFound;
}
