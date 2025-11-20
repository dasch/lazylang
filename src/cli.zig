//! Command-line interface dispatcher for Lazylang.
//!
//! This module implements the CLI dispatcher that routes subcommands to
//! specialized command handler modules.
//!
//! Commands:
//! - eval: Evaluate a Lazylang file or expression (cli_eval_cmd.zig)
//! - run: Execute a Lazylang program with system args/env (cli_run_cmd.zig)
//! - spec: Run Lazylang test files (cli_spec_cmd.zig)
//! - format: Format Lazylang source code (cli_format_cmd.zig)
//! - docs: Generate HTML documentation (cli_docs_cmd.zig)
//!
//! Each command is implemented in its own module for better organization
//! and maintainability.

const std = @import("std");
const cli_types = @import("cli_types.zig");
const cli_eval_cmd = @import("cli_eval_cmd.zig");
const cli_run_cmd = @import("cli_run_cmd.zig");
const cli_spec_cmd = @import("cli_spec_cmd.zig");
const cli_format_cmd = @import("cli_format_cmd.zig");
const cli_docs_cmd = @import("cli_docs_cmd.zig");

pub const CommandResult = cli_types.CommandResult;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    if (args.len <= 1) {
        try stderr.print("error: missing subcommand\n", .{});
        return .{ .exit_code = 1 };
    }

    const subcommand = args[1];
    if (std.mem.eql(u8, subcommand, "eval")) {
        return try cli_eval_cmd.runEval(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "spec")) {
        return try cli_spec_cmd.runSpec(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "format")) {
        return try cli_format_cmd.runFormat(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "docs")) {
        return try cli_docs_cmd.runDocs(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "run")) {
        return try cli_run_cmd.runRun(allocator, args[2..], stdout, stderr);
    }

    try stderr.print("error: unknown subcommand '{s}'\n", .{subcommand});
    return .{ .exit_code = 1 };
}
