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
//! - docspec: Test code examples in documentation (cli_docspec_cmd.zig)
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
const cli_docspec_cmd = @import("cli_docspec_cmd.zig");

pub const CommandResult = cli_types.CommandResult;

const CommandInfo = struct {
    name: []const u8,
    description: []const u8,
    usage: []const u8,
    help_text: []const u8,
};

const commands = [_]CommandInfo{
    .{
        .name = "eval",
        .description = "Evaluate a Lazylang file or expression",
        .usage = "lazy eval [options] [<file>]",
        .help_text =
        \\Evaluate a Lazylang file or expression and print the result.
        \\
        \\Usage:
        \\  lazy eval <file>                 Evaluate a file
        \\  lazy eval -e <expr>              Evaluate an inline expression
        \\  lazy eval --expr <expr>          Evaluate an inline expression
        \\
        \\Options:
        \\  -e, --expr <expr>    Evaluate an inline expression instead of a file
        \\  --json               Output as JSON
        \\  --yaml               Output as YAML
        \\  --manifest           Write object fields to files (requires object output)
        \\  --color              Force colored output
        \\  --no-color           Disable colored output
        \\  -h, --help           Show this help message
        \\
        \\Examples:
        \\  lazy eval script.lazy
        \\  lazy eval -e "1 + 2"
        \\  lazy eval --json data.lazy
        \\  lazy eval --manifest --yaml config.lazy
        ,
    },
    .{
        .name = "run",
        .description = "Execute a Lazylang program with system args and env",
        .usage = "lazy run <file> [-- <args>...]",
        .help_text =
        \\Execute a Lazylang program that takes system arguments and environment.
        \\
        \\The program must evaluate to a function that takes a single object parameter
        \\with 'args' (array of strings) and 'env' (object of strings).
        \\
        \\Usage:
        \\  lazy run <file>                  Run with no arguments
        \\  lazy run <file> -- arg1 arg2     Run with arguments
        \\
        \\Options:
        \\  -h, --help           Show this help message
        \\
        \\Examples:
        \\  lazy run script.lazy
        \\  lazy run script.lazy -- --input data.json --output result.json
        ,
    },
    .{
        .name = "spec",
        .description = "Run Lazylang test files",
        .usage = "lazy spec [options] [<path>]",
        .help_text =
        \\Run Lazylang test files (spec files).
        \\
        \\Usage:
        \\  lazy spec                        Run all specs in spec/ directory
        \\  lazy spec <dir>                  Run all specs in directory
        \\  lazy spec <file>                 Run specific spec file
        \\  lazy spec <file>:<line>          Run specific test at line number
        \\
        \\Options:
        \\  -v, --verbose        Show all passing tests (verbose mode)
        \\  -h, --help           Show this help message
        \\
        \\Examples:
        \\  lazy spec
        \\  lazy spec stdlib/tests
        \\  lazy spec stdlib/tests/ArraySpec.lazy
        \\  lazy spec stdlib/tests/ArraySpec.lazy:42
        ,
    },
    .{
        .name = "format",
        .description = "Format Lazylang source code",
        .usage = "lazy format <path>",
        .help_text =
        \\Format Lazylang source code by normalizing whitespace and indentation.
        \\
        \\Usage:
        \\  lazy format <file>               Format a file and print to stdout
        \\
        \\Options:
        \\  -h, --help           Show this help message
        \\
        \\Examples:
        \\  lazy format script.lazy
        \\  lazy format script.lazy > formatted.lazy
        ,
    },
    .{
        .name = "docs",
        .description = "Generate HTML documentation from doc comments",
        .usage = "lazy docs [options] [<path>]",
        .help_text =
        \\Generate HTML documentation from doc comments (///) in Lazylang modules.
        \\
        \\Usage:
        \\  lazy docs                        Generate docs from lib/ directory
        \\  lazy docs <path>                 Generate docs from specific file/dir
        \\
        \\Options:
        \\  -o, --output <dir>   Output directory (default: docs)
        \\  -h, --help           Show this help message
        \\
        \\Examples:
        \\  lazy docs
        \\  lazy docs stdlib/lib
        \\  lazy docs --output public/docs stdlib/lib
        ,
    },
    .{
        .name = "docspec",
        .description = "Test code examples in documentation comments",
        .usage = "lazy docspec [<path>]",
        .help_text =
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
        ,
    },
};

fn printHelp(stderr: anytype) !void {
    try stderr.print(
        \\Lazylang - A pure, lazy functional language for configuration
        \\
        \\Usage: lazy <command> [options] [arguments]
        \\
        \\Commands:
        \\
    , .{});

    for (commands) |cmd| {
        try stderr.print("  {s: <12} {s}\n", .{ cmd.name, cmd.description });
    }

    try stderr.print(
        \\
        \\Use 'lazy help <command>' or 'lazy <command> -h' for more information about a command.
        \\
    , .{});
}

fn printCommandHelp(command_name: []const u8, stderr: anytype) !CommandResult {
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, command_name)) {
            try stderr.print("{s}\n", .{cmd.help_text});
            return .{ .exit_code = 0 };
        }
    }

    try stderr.print("error: unknown command '{s}'\n\n", .{command_name});
    try printHelp(stderr);
    return .{ .exit_code = 1 };
}

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    if (args.len <= 1) {
        try printHelp(stderr);
        return .{ .exit_code = 1 };
    }

    const subcommand = args[1];

    // Handle help command
    if (std.mem.eql(u8, subcommand, "help")) {
        if (args.len <= 2) {
            try printHelp(stderr);
            return .{ .exit_code = 0 };
        }
        return try printCommandHelp(args[2], stderr);
    }

    // Check for -h or --help flag in the subcommand args
    if (args.len > 2) {
        for (args[2..]) |arg| {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                return try printCommandHelp(subcommand, stderr);
            }
        }
    }

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

    if (std.mem.eql(u8, subcommand, "docspec")) {
        return try cli_docspec_cmd.runDocSpec(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "run")) {
        return try cli_run_cmd.runRun(allocator, args[2..], stdout, stderr);
    }

    try stderr.print("error: unknown subcommand '{s}'\n\n", .{subcommand});
    try printHelp(stderr);
    return .{ .exit_code = 1 };
}
