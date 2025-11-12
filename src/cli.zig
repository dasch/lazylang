const std = @import("std");
const evaluator = @import("eval.zig");
const spec = @import("spec.zig");
const error_reporter = @import("error_reporter.zig");
const error_context = @import("error_context.zig");
const json_error = @import("json_error.zig");
const formatter = @import("formatter.zig");

pub const CommandResult = struct {
    exit_code: u8,
};

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
        return try runEval(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "spec")) {
        return try runSpec(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "format")) {
        return try runFormat(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "docs")) {
        return try runDocs(allocator, args[2..], stdout, stderr);
    }

    if (std.mem.eql(u8, subcommand, "run")) {
        return try runRun(allocator, args[2..], stdout, stderr);
    }

    try stderr.print("error: unknown subcommand '{s}'\n", .{subcommand});
    return .{ .exit_code = 1 };
}

fn runEval(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    var inline_expr: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var json_output = false;
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--expr") or std.mem.eql(u8, arg, "-e")) {
            if (index + 1 >= args.len) {
                try stderr.print("error: --expr requires a value\n", .{});
                return .{ .exit_code = 1 };
            }
            if (inline_expr != null) {
                try stderr.print("error: --expr can only be specified once\n", .{});
                return .{ .exit_code = 1 };
            }
            inline_expr = args[index + 1];
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
            continue;
        }

        // Positional argument - treat as file path
        if (file_path != null) {
            try stderr.print("error: unexpected argument '{s}'\n", .{arg});
            return .{ .exit_code = 1 };
        }
        file_path = arg;
    }

    // --expr takes precedence over file path
    if (inline_expr != null) {
        if (file_path != null) {
            try stderr.print("error: cannot specify both --expr and a file path\n", .{});
            return .{ .exit_code = 1 };
        }

        var result = evaluator.evalInlineWithContext(allocator, inline_expr.?) catch |err| {
            if (json_output) {
                try json_error.reportErrorAsJson(stderr, "<inline>", &error_context.ErrorContext.init(allocator), @errorName(err), @errorName(err), null);
            } else {
                try reportError(stderr, "<inline>", inline_expr.?, err, null);
            }
            return .{ .exit_code = 1 };
        };
        defer result.deinit();

        if (result.output) |output| {
            try stdout.print("{s}\n", .{output.text});
            return .{ .exit_code = 0 };
        } else {
            // Error occurred
            if (json_output) {
                try json_error.reportErrorAsJson(stderr, "<inline>", &result.error_ctx, "ParseError", "An error occurred at this location.", null);
            } else {
                try reportErrorWithContext(stderr, "<inline>", inline_expr.?, &result.error_ctx);
            }
            return .{ .exit_code = 1 };
        }
    }

    if (file_path == null) {
        try stderr.print("error: missing file path or --expr option\n", .{});
        return .{ .exit_code = 1 };
    }

    // Read the file content first for error reporting
    const file_content = std.fs.cwd().readFileAlloc(allocator, file_path.?, std.math.maxInt(usize)) catch |read_err| {
        try stderr.print("error: failed to read file '{s}': {}\n", .{ file_path.?, read_err });
        return .{ .exit_code = 1 };
    };
    defer allocator.free(file_content);

    var result = evaluator.evalFileWithContext(allocator, file_path.?) catch |err| {
        // For file I/O errors, we don't have source context
        if (json_output) {
            try json_error.reportErrorAsJson(stderr, file_path.?, &error_context.ErrorContext.init(allocator), @errorName(err), @errorName(err), null);
        } else {
            try reportError(stderr, file_path.?, file_content, err, null);
        }
        return .{ .exit_code = 1 };
    };
    defer result.deinit();

    if (result.output) |output| {
        try stdout.print("{s}\n", .{output.text});
        return .{ .exit_code = 0 };
    } else {
        // Error occurred during parsing/evaluation
        // Use the file content we read, not the one from error context (which might be deallocated)
        if (json_output) {
            try json_error.reportErrorAsJson(stderr, file_path.?, &result.error_ctx, "ParseError", "An error occurred at this location.", null);
        } else {
            try reportErrorWithContext(stderr, file_path.?, file_content, &result.error_ctx);
        }
        return .{ .exit_code = 1 };
    }
}

fn reportErrorWithContext(stderr: anytype, filename: []const u8, source: []const u8, err_ctx: *const error_context.ErrorContext) !void {
    // Check if it's a user crash
    if (evaluator.getUserCrashMessage()) |crash_message| {
        const error_info = error_reporter.ErrorInfo{
            .title = "Runtime error",
            .location = null,
            .message = crash_message,
            .suggestion = null,
        };
        try error_reporter.reportError(stderr, source, filename, error_info);
        evaluator.clearUserCrashMessage();
        return;
    }

    // Determine which error to report (we don't have the error type here, so use the location)
    const error_info = if (err_ctx.last_error_location) |loc| blk: {
        // We have location info - show it!
        break :blk error_reporter.ErrorInfo{
            .title = "Parse or evaluation error",
            .location = loc,
            .message = if (err_ctx.last_error_token_lexeme) |_|
                "An error occurred at this location."
            else
                "An error occurred at this location.",
            .suggestion = null,
        };
    } else error_reporter.ErrorInfo{
        .title = "Error",
        .location = null,
        .message = "An error occurred during evaluation.",
        .suggestion = null,
    };

    try error_reporter.reportError(stderr, source, filename, error_info);
}

fn reportError(stderr: anytype, filename: []const u8, source: []const u8, err: anyerror, err_ctx: ?*const error_context.ErrorContext) !void {
    const location = if (err_ctx) |ctx| ctx.last_error_location else null;

    const error_info = switch (err) {
        error.UnexpectedCharacter => error_reporter.ErrorInfo{
            .title = "Unexpected character",
            .location = location,
            .message = "Found an unexpected character in the source code.",
            .suggestion = "Remove the invalid character or check for typos.",
        },
        error.UnterminatedString => error_reporter.ErrorInfo{
            .title = "Unterminated string",
            .location = location,
            .message = error_reporter.ErrorMessages.unterminatedString(),
            .suggestion = error_reporter.ErrorSuggestions.unterminatedString(),
        },
        error.ExpectedExpression => error_reporter.ErrorInfo{
            .title = "Expected expression",
            .location = location,
            .message = error_reporter.ErrorMessages.expectedExpression(),
            .suggestion = "Add an expression here.",
        },
        error.UnexpectedToken => error_reporter.ErrorInfo{
            .title = "Unexpected token",
            .location = location,
            .message = "Found an unexpected token.",
            .suggestion = "Check the syntax at this location.",
        },
        error.UnknownIdentifier => error_reporter.ErrorInfo{
            .title = "Unknown identifier",
            .location = null,
            .message = "This identifier is not defined in the current scope.",
            .suggestion = "Check the spelling or define this variable before using it.",
        },
        error.TypeMismatch => error_reporter.ErrorInfo{
            .title = "Type mismatch",
            .location = null,
            .message = error_reporter.ErrorMessages.typeMismatch("", ""),
            .suggestion = error_reporter.ErrorSuggestions.typeMismatch(),
        },
        error.ExpectedFunction => error_reporter.ErrorInfo{
            .title = "Expected function",
            .location = null,
            .message = error_reporter.ErrorMessages.expectedFunction(),
            .suggestion = error_reporter.ErrorSuggestions.expectedFunction(),
        },
        error.ModuleNotFound => error_reporter.ErrorInfo{
            .title = "Module not found",
            .location = null,
            .message = "Could not find the imported module.",
            .suggestion = "Make sure the module file exists in the correct location.",
        },
        error.WrongNumberOfArguments => error_reporter.ErrorInfo{
            .title = "Wrong number of arguments",
            .location = null,
            .message = "Function called with wrong number of arguments.",
            .suggestion = "Check the function signature and call it with the correct number of arguments.",
        },
        error.InvalidArgument => error_reporter.ErrorInfo{
            .title = "Invalid argument",
            .location = null,
            .message = error_reporter.ErrorMessages.invalidArgument(),
            .suggestion = "Check that the argument value is valid for this operation.",
        },
        error.UserCrash => blk: {
            const crash_message = evaluator.getUserCrashMessage() orelse "Program crashed with no message.";
            break :blk error_reporter.ErrorInfo{
                .title = "Runtime error",
                .location = null,
                .message = crash_message,
                .suggestion = null,
            };
        },
        error.CyclicReference => error_reporter.ErrorInfo{
            .title = "Cyclic reference",
            .location = null,
            .message = "A cyclic reference was detected during evaluation. This usually means a value depends on itself in an invalid way.",
            .suggestion = "Check for circular dependencies in your definitions.",
        },
        else => error_reporter.ErrorInfo{
            .title = "Error",
            .location = null,
            .message = @errorName(err),
            .suggestion = null,
        },
    };

    try error_reporter.reportError(stderr, source, filename, error_info);

    // Clear the crash message after reporting
    evaluator.clearUserCrashMessage();
}

fn runSpec(
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

fn runFormat(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    if (args.len == 0) {
        try stderr.print("error: missing file path\n", .{});
        try stderr.print("usage: lazy format <path>\n", .{});
        return .{ .exit_code = 1 };
    }

    if (args.len > 1) {
        try stderr.print("error: too many arguments\n", .{});
        try stderr.print("usage: lazy format <path>\n", .{});
        return .{ .exit_code = 1 };
    }

    const file_path = args[0];

    var format_output = formatter.formatFile(allocator, file_path) catch |err| {
        try stderr.print("error: failed to format file: {}\n", .{err});
        return .{ .exit_code = 1 };
    };
    defer format_output.deinit();

    try stdout.print("{s}", .{format_output.text});
    return .{ .exit_code = 0 };
}

fn runRun(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !CommandResult {
    // Parse arguments: file_path [-- arg1 arg2 ...]
    if (args.len == 0) {
        try stderr.print("error: missing file path\n", .{});
        return .{ .exit_code = 1 };
    }

    const file_path = args[0];
    var run_args_start: usize = 1;
    var found_separator = false;

    // Find the -- separator
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            run_args_start = i + 1;
            found_separator = true;
            break;
        }
    }

    // Get the run arguments (everything after --)
    const run_args = if (found_separator) args[run_args_start..] else &[_][]const u8{};

    // Read the file content for error reporting
    const file_content = std.fs.cwd().readFileAlloc(allocator, file_path, std.math.maxInt(usize)) catch |read_err| {
        try stderr.print("error: failed to read file '{s}': {}\n", .{ file_path, read_err });
        return .{ .exit_code = 1 };
    };
    defer allocator.free(file_content);

    // Create an arena allocator for the evaluation
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    // Parse the file
    var parser = evaluator.Parser.init(arena, file_content) catch |err| {
        try reportError(stderr, file_path, file_content, err, null);
        return .{ .exit_code = 1 };
    };

    const expression = parser.parse() catch {
        var err_ctx = error_context.ErrorContext.init(allocator);
        try reportErrorWithContext(stderr, file_path, file_content, &err_ctx);
        return .{ .exit_code = 1 };
    };

    // Evaluate the expression to get a value
    const directory = std.fs.path.dirname(file_path);
    var eval_ctx = evaluator.EvalContext{
        .allocator = allocator,
        .lazy_paths = &[_][]const u8{},
    };

    const value = evaluator.evaluateExpression(arena, expression, null, directory, &eval_ctx) catch |err| {
        try reportError(stderr, file_path, file_content, err, null);
        return .{ .exit_code = 1 };
    };

    // Check that the value is a function
    const function = switch (value) {
        .function => |f| f,
        else => {
            try stderr.print("error: file must evaluate to a function, got {s}\n", .{@tagName(value)});
            return .{ .exit_code = 1 };
        },
    };

    // Create the system object with args and env
    // First, create the args array
    const args_values = try arena.alloc(evaluator.Value, run_args.len);
    for (run_args, 0..) |arg, i| {
        const arg_copy = try arena.dupe(u8, arg);
        args_values[i] = evaluator.Value{ .string = arg_copy };
    }

    // Create the env object
    var env_fields = std.ArrayList(evaluator.ObjectFieldValue){};
    defer env_fields.deinit(arena);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var env_iter = env_map.iterator();
    while (env_iter.next()) |entry| {
        const key_copy = try arena.dupe(u8, entry.key_ptr.*);
        const value_copy = try arena.dupe(u8, entry.value_ptr.*);
        try env_fields.append(arena, .{
            .key = key_copy,
            .value = evaluator.Value{ .string = value_copy },
        });
    }

    const env_object = evaluator.Value{
        .object = .{
            .fields = try env_fields.toOwnedSlice(arena),
        },
    };

    // Create the system object
    const system_fields = try arena.alloc(evaluator.ObjectFieldValue, 2);
    system_fields[0] = .{
        .key = "args",
        .value = evaluator.Value{ .array = .{ .elements = args_values } },
    };
    system_fields[1] = .{
        .key = "env",
        .value = env_object,
    };

    const system_value = evaluator.Value{
        .object = .{ .fields = system_fields },
    };

    // Call the function with the system value
    const bound_env = evaluator.matchPattern(arena, function.param, system_value, function.env) catch |err| {
        try stderr.print("error: failed to bind function parameter: {}\n", .{err});
        return .{ .exit_code = 1 };
    };

    const result = evaluator.evaluateExpression(arena, function.body, bound_env, directory, &eval_ctx) catch |err| {
        try reportError(stderr, file_path, file_content, err, null);
        return .{ .exit_code = 1 };
    };

    // Format and print the result
    const formatted = try evaluator.formatValue(allocator, result);
    defer allocator.free(formatted);

    try stdout.print("{s}\n", .{formatted});
    return .{ .exit_code = 0 };
}

fn runDocs(
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

    if (input_path == null) {
        try stderr.print("error: missing input path\n", .{});
        return .{ .exit_code = 1 };
    }

    // Create output directory if it doesn't exist
    std.fs.cwd().makePath(output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Collect all module info
    var modules_list = std.ArrayList(ModuleInfo){};
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
        try collectModulesFromDirectory(allocator, input_path.?, &modules_list, stdout);
    } else {
        // Collect single module
        try stdout.print("Extracting docs from {s}...\n", .{input_path.?});
        const module_info = try extractModuleInfo(allocator, input_path.?);
        try modules_list.append(allocator, module_info);
    }

    // Generate index.html
    try generateIndexHtml(allocator, modules_list.items, output_dir);

    // Generate HTML for each module
    for (modules_list.items) |module| {
        try stdout.print("Generating HTML for {s}...\n", .{module.name});
        try generateModuleHtml(allocator, module, modules_list.items, output_dir);
    }

    try stdout.print("Documentation generated in {s}/\n", .{output_dir});
    return .{ .exit_code = 0 };
}

fn collectModulesFromDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    modules: *std.ArrayList(ModuleInfo),
    stdout: anytype,
) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Check if file has .lazy extension
        if (!std.mem.endsWith(u8, entry.basename, ".lazy")) continue;

        // Build full path
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.path });
        defer allocator.free(full_path);

        try stdout.print("Extracting docs from {s}...\n", .{full_path});
        const module_info = try extractModuleInfo(allocator, full_path);
        try modules.append(allocator, module_info);
    }
}

fn extractModuleInfo(
    allocator: std.mem.Allocator,
    input_path: []const u8,
) !ModuleInfo {
    // Parse the file to extract documentation
    const source = try std.fs.cwd().readFileAlloc(allocator, input_path, 100 * 1024 * 1024);
    defer allocator.free(source);

    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var parser = try evaluator.Parser.init(arena, source);
    const expression = try parser.parse();

    // Extract documentation from the expression
    var doc_items = std.ArrayListUnmanaged(DocItem){};

    try extractDocs(expression, &doc_items, allocator);

    const module_name = try allocator.dupe(u8, std.fs.path.stem(input_path));

    return ModuleInfo{
        .name = module_name,
        .items = try doc_items.toOwnedSlice(allocator),
    };
}

fn generateModuleHtml(
    allocator: std.mem.Allocator,
    module: ModuleInfo,
    all_modules: []const ModuleInfo,
    output_dir: []const u8,
) !void {
    const html_filename = try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ output_dir, module.name });
    defer allocator.free(html_filename);

    var html_file = try std.fs.cwd().createFile(html_filename, .{});
    defer html_file.close();

    try writeHtmlDocs(html_file, module.name, module.items, all_modules);
}

fn generateIndexHtml(
    allocator: std.mem.Allocator,
    modules: []const ModuleInfo,
    output_dir: []const u8,
) !void {
    const html_filename = try std.fmt.allocPrint(allocator, "{s}/index.html", .{output_dir});
    defer allocator.free(html_filename);

    var html_file = try std.fs.cwd().createFile(html_filename, .{});
    defer html_file.close();

    try writeIndexHtmlContent(html_file, modules);
}

const DocItem = struct {
    name: []const u8,
    signature: []const u8, // Full signature like "min: a -> b ->"
    doc: []const u8,
    kind: DocKind,
};

const ModuleInfo = struct {
    name: []const u8,
    items: []const DocItem,
};

const DocKind = enum {
    variable,
    field,
};

fn extractParamNames(pattern: *const evaluator.Pattern, names: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    switch (pattern.*) {
        .identifier => |ident| {
            try names.append(allocator, ident);
        },
        .tuple => |tuple| {
            for (tuple.elements) |elem| {
                try extractParamNames(elem, names, allocator);
            }
        },
        else => {},
    }
}

fn buildSignature(allocator: std.mem.Allocator, field_name: []const u8, value: *const evaluator.Expression) ![]const u8 {
    var signature = std.ArrayList(u8){};
    defer signature.deinit(allocator);

    try signature.appendSlice(allocator, field_name);
    try signature.appendSlice(allocator, ": ");

    // Extract parameter names if it's a lambda
    var current_expr = value;
    while (current_expr.* == .lambda) {
        const lambda = current_expr.lambda;

        var param_names = std.ArrayList([]const u8){};
        defer param_names.deinit(allocator);
        try extractParamNames(lambda.param, &param_names, allocator);

        for (param_names.items) |param_name| {
            try signature.appendSlice(allocator, param_name);
            try signature.appendSlice(allocator, " → ");
        }

        current_expr = lambda.body;
    }

    return signature.toOwnedSlice(allocator);
}

fn extractDocs(expr: *const evaluator.Expression, items: *std.ArrayListUnmanaged(DocItem), allocator: std.mem.Allocator) !void {
    switch (expr.*) {
        .let => |let_expr| {
            if (let_expr.doc) |doc| {
                // Extract the name from the pattern
                const name = switch (let_expr.pattern.*) {
                    .identifier => |ident| ident,
                    else => "unknown",
                };
                const signature = try buildSignature(allocator, name, let_expr.value);
                try items.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .signature = signature,
                    .doc = try allocator.dupe(u8, doc),
                    .kind = .variable,
                });
            }
            try extractDocs(let_expr.body, items, allocator);
        },
        .object => |obj| {
            for (obj.fields) |field| {
                if (field.doc) |doc| {
                    const signature = try buildSignature(allocator, field.key, field.value);
                    try items.append(allocator, .{
                        .name = try allocator.dupe(u8, field.key),
                        .signature = signature,
                        .doc = try allocator.dupe(u8, doc),
                        .kind = .field,
                    });
                } else {
                    // Also check if the field value is documented (for nested objects)
                    try extractDocs(field.value, items, allocator);
                }
            }
        },
        else => {},
    }
}

fn renderMarkdownToHtml(allocator: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var in_code_block = false;
    var line_start: usize = 0;

    while (i < markdown.len) {
        // Check for code blocks (```)
        if (i + 2 < markdown.len and markdown[i] == '`' and markdown[i + 1] == '`' and markdown[i + 2] == '`') {
            if (in_code_block) {
                try result.appendSlice(allocator, "</code></pre>\n");
                in_code_block = false;
            } else {
                try result.appendSlice(allocator, "<pre><code>");
                in_code_block = true;
            }
            i += 3;
            // Skip to end of line
            while (i < markdown.len and markdown[i] != '\n') : (i += 1) {}
            if (i < markdown.len) i += 1; // skip newline
            line_start = i;
            continue;
        }

        if (in_code_block) {
            if (markdown[i] == '<') {
                try result.appendSlice(allocator, "&lt;");
            } else if (markdown[i] == '>') {
                try result.appendSlice(allocator, "&gt;");
            } else if (markdown[i] == '&') {
                try result.appendSlice(allocator, "&amp;");
            } else {
                try result.append(allocator, markdown[i]);
            }
            i += 1;
            continue;
        }

        // Check for line breaks
        if (markdown[i] == '\n') {
            const line = markdown[line_start..i];

            // Check if it's a list item
            if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "- ")) {
                const trimmed = std.mem.trimLeft(u8, line, " \t");
                try result.appendSlice(allocator, "<li>");
                try renderInlineMarkdown(allocator, &result, trimmed[2..]);
                try result.appendSlice(allocator, "</li>\n");
            } else if (line.len > 0) {
                try renderInlineMarkdown(allocator, &result, line);
                try result.appendSlice(allocator, "<br>\n");
            } else {
                try result.appendSlice(allocator, "\n");
            }

            i += 1;
            line_start = i;
            continue;
        }

        i += 1;
    }

    // Handle remaining text
    if (line_start < markdown.len) {
        const line = markdown[line_start..];
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "- ")) {
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            try result.appendSlice(allocator, "<li>");
            try renderInlineMarkdown(allocator, &result, trimmed[2..]);
            try result.appendSlice(allocator, "</li>");
        } else if (line.len > 0) {
            try renderInlineMarkdown(allocator, &result, line);
        }
    }

    return result.toOwnedSlice(allocator);
}

fn renderInlineMarkdown(allocator: std.mem.Allocator, result: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        // Check for inline code (`)
        if (text[i] == '`') {
            const start = i + 1;
            i += 1;
            while (i < text.len and text[i] != '`') : (i += 1) {}
            if (i < text.len) {
                try result.appendSlice(allocator, "<code>");
                try result.appendSlice(allocator, text[start..i]);
                try result.appendSlice(allocator, "</code>");
                i += 1;
                continue;
            }
        }

        // Check for bold (**)
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            const start = i + 2;
            i += 2;
            while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '*')) : (i += 1) {}
            if (i + 1 < text.len) {
                try result.appendSlice(allocator, "<strong>");
                try result.appendSlice(allocator, text[start..i]);
                try result.appendSlice(allocator, "</strong>");
                i += 2;
                continue;
            }
        }

        // Regular character
        if (text[i] == '<') {
            try result.appendSlice(allocator, "&lt;");
        } else if (text[i] == '>') {
            try result.appendSlice(allocator, "&gt;");
        } else if (text[i] == '&') {
            try result.appendSlice(allocator, "&amp;");
        } else {
            try result.append(allocator, text[i]);
        }
        i += 1;
    }
}

fn writeIndexHtmlContent(file: anytype, modules: []const ModuleInfo) !void {
    try file.writeAll("<!DOCTYPE html>\n");
    try file.writeAll("<html lang=\"en\">\n");
    try file.writeAll("<head>\n");
    try file.writeAll("  <meta charset=\"UTF-8\">\n");
    try file.writeAll("  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    try file.writeAll("  <title>Documentation</title>\n");
    try file.writeAll("  <style>\n");
    try file.writeAll(
        \\    * { margin: 0; padding: 0; box-sizing: border-box; }
        \\    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; background: #f5f5f5; display: flex; }
        \\    .sidebar { width: 250px; background: #2c3e50; color: white; min-height: 100vh; position: fixed; top: 0; left: 0; overflow-y: auto; }
        \\    .sidebar h2 { padding: 20px; font-size: 1.2em; border-bottom: 1px solid #34495e; }
        \\    .sidebar ul { list-style: none; }
        \\    .sidebar li { border-bottom: 1px solid #34495e; }
        \\    .sidebar a { display: block; padding: 12px 20px; color: #ecf0f1; text-decoration: none; transition: background 0.2s; }
        \\    .sidebar a:hover { background: #34495e; }
        \\    .sidebar a.active { background: #3498db; font-weight: 600; }
        \\    .main { margin-left: 250px; flex: 1; }
        \\    .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        \\    header { background: #2c3e50; color: white; padding: 30px 0; margin-bottom: 30px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        \\    h1 { font-size: 2.5em; font-weight: 300; }
        \\    .module-list { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; }
        \\    .module-card { background: white; padding: 25px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        \\    .module-card h2 { color: #2c3e50; margin-bottom: 15px; font-size: 1.5em; }
        \\    .module-card h2 a { color: #2c3e50; text-decoration: none; }
        \\    .module-card h2 a:hover { color: #3498db; }
        \\    .module-card .item-count { color: #7f8c8d; font-size: 0.9em; margin-top: 10px; }
        \\    @media (max-width: 768px) { .sidebar { display: none; } .main { margin-left: 0; } .container { padding: 10px; } .module-list { grid-template-columns: 1fr; } }
        \\
    );
    try file.writeAll("  </style>\n");
    try file.writeAll("</head>\n");
    try file.writeAll("<body>\n");

    // Sidebar with module list
    try file.writeAll("  <div class=\"sidebar\">\n");
    try file.writeAll("    <h2>Modules</h2>\n");
    try file.writeAll("    <ul>\n");
    for (modules) |module| {
        try file.writeAll("      <li><a href=\"");
        try file.writeAll(module.name);
        try file.writeAll(".html\">");
        try file.writeAll(module.name);
        try file.writeAll("</a></li>\n");
    }
    try file.writeAll("    </ul>\n");
    try file.writeAll("  </div>\n");

    // Main content
    try file.writeAll("  <div class=\"main\">\n");
    try file.writeAll("    <header>\n");
    try file.writeAll("      <div class=\"container\">\n");
    try file.writeAll("        <h1>Documentation</h1>\n");
    try file.writeAll("      </div>\n");
    try file.writeAll("    </header>\n");
    try file.writeAll("    <div class=\"container\">\n");
    try file.writeAll("      <div class=\"module-list\">\n");

    // Module cards
    for (modules) |module| {
        try file.writeAll("        <div class=\"module-card\">\n");
        try file.writeAll("          <h2><a href=\"");
        try file.writeAll(module.name);
        try file.writeAll(".html\">");
        try file.writeAll(module.name);
        try file.writeAll("</a></h2>\n");
        try file.writeAll("          <div class=\"item-count\">");

        // Count items
        var buffer: [32]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&buffer, "{d}", .{module.items.len});
        try file.writeAll(count_str);
        try file.writeAll(" ");
        if (module.items.len == 1) {
            try file.writeAll("item");
        } else {
            try file.writeAll("items");
        }
        try file.writeAll("</div>\n");
        try file.writeAll("        </div>\n");
    }

    try file.writeAll("      </div>\n");
    try file.writeAll("    </div>\n");
    try file.writeAll("  </div>\n");
    try file.writeAll("</body>\n");
    try file.writeAll("</html>\n");
}

fn writeHtmlDocs(file: anytype, module_name: []const u8, items: []const DocItem, modules: []const ModuleInfo) !void {
    try file.writeAll("<!DOCTYPE html>\n");
    try file.writeAll("<html lang=\"en\">\n");
    try file.writeAll("<head>\n");
    try file.writeAll("  <meta charset=\"UTF-8\">\n");
    try file.writeAll("  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    try file.writeAll("  <title>");
    try file.writeAll(module_name);
    try file.writeAll(" - Documentation</title>\n");
    try file.writeAll("  <style>\n");
    try file.writeAll(
        \\    * { margin: 0; padding: 0; box-sizing: border-box; }
        \\    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; background: #f5f5f5; display: flex; }
        \\    .sidebar { width: 280px; background: #2c3e50; color: white; min-height: 100vh; position: fixed; top: 0; left: 0; overflow-y: auto; }
        \\    .sidebar-search { padding: 15px; border-bottom: 1px solid #34495e; }
        \\    .sidebar-search input { width: 100%; padding: 10px 12px; font-size: 14px; border: 1px solid #34495e; border-radius: 4px; background: #34495e; color: white; }
        \\    .sidebar-search input::placeholder { color: #95a5a6; }
        \\    .sidebar-search input:focus { outline: none; background: #3d5469; border-color: #3498db; }
        \\    .sidebar h2 { padding: 15px; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.5px; color: #95a5a6; border-bottom: 1px solid #34495e; }
        \\    .sidebar ul { list-style: none; }
        \\    .sidebar > ul > li { border-bottom: 1px solid #34495e; }
        \\    .sidebar a { display: block; padding: 12px 20px; color: #ecf0f1; text-decoration: none; transition: background 0.2s; }
        \\    .sidebar a:hover { background: #34495e; }
        \\    .sidebar a.active { background: #3498db; font-weight: 600; }
        \\    .sidebar .module-link { font-weight: 500; }
        \\    .sidebar .nested { list-style: none; }
        \\    .sidebar .nested li { border-bottom: none; }
        \\    .sidebar .nested a { padding: 8px 20px 8px 35px; font-size: 0.9em; color: #bdc3c7; }
        \\    .sidebar .nested a:hover { background: #3d5469; color: #ecf0f1; }
        \\    .main { margin-left: 280px; flex: 1; }
        \\    .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        \\    header { background: #2c3e50; color: white; padding: 30px 0; margin-bottom: 30px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        \\    h1 { font-size: 2.5em; font-weight: 300; }
        \\    .doc-item { background: white; padding: 25px; margin-bottom: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        \\    .doc-item h2 { color: #2c3e50; margin-bottom: 10px; font-size: 1.5em; }
        \\    .doc-item .kind { display: inline-block; padding: 4px 10px; background: #3498db; color: white; border-radius: 4px; font-size: 0.85em; margin-bottom: 10px; }
        \\    .doc-item .doc-content { color: #555; line-height: 1.8; }
        \\    .doc-item .doc-content code { background: #f4f4f4; padding: 2px 6px; border-radius: 3px; font-family: 'Courier New', monospace; font-size: 0.9em; }
        \\    .doc-item .doc-content pre { background: #f4f4f4; padding: 12px; border-radius: 4px; overflow-x: auto; margin: 10px 0; }
        \\    .doc-item .doc-content pre code { background: none; padding: 0; }
        \\    .doc-item .doc-content strong { font-weight: 600; color: #2c3e50; }
        \\    .doc-item .doc-content li { margin-left: 20px; margin-bottom: 5px; }
        \\    .no-results { text-align: center; padding: 40px; color: #999; }
        \\    .search-result-label { font-size: 0.85em; color: #7f8c8d; margin-left: 5px; }
        \\    @media (max-width: 768px) { .sidebar { display: none; } .main { margin-left: 0; } .container { padding: 10px; } .doc-item { padding: 15px; } }
        \\
    );
    try file.writeAll("  </style>\n");
    try file.writeAll("</head>\n");
    try file.writeAll("<body>\n");

    // Sidebar
    try file.writeAll("  <div class=\"sidebar\">\n");

    // Search box at the top
    try file.writeAll("    <div class=\"sidebar-search\">\n");
    try file.writeAll("      <input type=\"text\" id=\"sidebar-search\" placeholder=\"Search (Cmd+K)...\" />\n");
    try file.writeAll("    </div>\n");

    // Modules section
    try file.writeAll("    <h2>Modules</h2>\n");
    try file.writeAll("    <ul>\n");

    // List all modules
    for (modules) |module| {
        const is_current = std.mem.eql(u8, module.name, module_name);

        try file.writeAll("      <li>\n");
        try file.writeAll("        <a href=\"");
        try file.writeAll(module.name);
        try file.writeAll(".html\" class=\"module-link");
        if (is_current) {
            try file.writeAll(" active");
        }
        try file.writeAll("\">");
        try file.writeAll(module.name);
        try file.writeAll("</a>\n");

        // If this is the current module, show its items
        if (is_current) {
            try file.writeAll("        <ul class=\"nested\">\n");
            for (items) |item| {
                try file.writeAll("          <li><a href=\"#");
                try file.writeAll(item.name);
                try file.writeAll("\" data-module=\"");
                try file.writeAll(module_name);
                try file.writeAll("\" data-item=\"");
                try file.writeAll(item.name);
                try file.writeAll("\">");
                try file.writeAll(item.name);
                try file.writeAll("</a></li>\n");
            }
            try file.writeAll("        </ul>\n");
        }

        try file.writeAll("      </li>\n");
    }

    try file.writeAll("    </ul>\n");
    try file.writeAll("  </div>\n");

    // Main content
    try file.writeAll("  <div class=\"main\">\n");
    try file.writeAll("    <header>\n");
    try file.writeAll("      <div class=\"container\">\n");
    try file.writeAll("        <h1>");
    try file.writeAll(module_name);
    try file.writeAll("</h1>\n");
    try file.writeAll("      </div>\n");
    try file.writeAll("    </header>\n");
    try file.writeAll("    <div class=\"container\">\n");
    try file.writeAll("    <div id=\"docs\">\n");

    // We need access to allocator for markdown rendering
    // For now, let's use a stack allocator approach with a larger buffer
    var buffer: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const temp_allocator = fba.allocator();

    for (items) |item| {
        try file.writeAll("      <div class=\"doc-item\" id=\"");
        try file.writeAll(item.name);
        try file.writeAll("\" data-name=\"");
        try file.writeAll(item.name);
        try file.writeAll("\">\n");
        try file.writeAll("        <h2>");
        try file.writeAll(item.signature);
        try file.writeAll("</h2>\n");
        try file.writeAll("        <div class=\"doc-content\">\n");

        // Render markdown to HTML
        fba.reset();
        const html = renderMarkdownToHtml(temp_allocator, item.doc) catch {
            // Fallback to plain text if markdown rendering fails
            try file.writeAll("          ");
            try file.writeAll(item.doc);
            try file.writeAll("\n");
            try file.writeAll("        </div>\n");
            try file.writeAll("      </div>\n");
            continue;
        };
        try file.writeAll("          ");
        try file.writeAll(html);
        try file.writeAll("\n");

        try file.writeAll("        </div>\n");
        try file.writeAll("      </div>\n");
    }

    if (items.len == 0) {
        try file.writeAll("      <div class=\"no-results\">No documentation found</div>\n");
    }

    try file.writeAll("    </div>\n");
    try file.writeAll("    </div>\n");
    try file.writeAll("  </div>\n");
    try file.writeAll("  <script>\n");

    // Generate search data for all modules
    try file.writeAll("    const searchData = [\n");
    for (modules, 0..) |module, i| {
        for (module.items, 0..) |item, j| {
            try file.writeAll("      { module: '");
            try file.writeAll(module.name);
            try file.writeAll("', name: '");
            // Escape single quotes in name
            for (item.name) |c| {
                if (c == '\'') {
                    try file.writeAll("\\'");
                } else {
                    const char_slice = &[_]u8{c};
                    try file.writeAll(char_slice);
                }
            }
            try file.writeAll("', signature: '");
            // Escape single quotes in signature
            for (item.signature) |c| {
                if (c == '\'') {
                    try file.writeAll("\\'");
                } else {
                    const char_slice = &[_]u8{c};
                    try file.writeAll(char_slice);
                }
            }
            try file.writeAll("' }");
            if (!(i == modules.len - 1 and j == module.items.len - 1)) {
                try file.writeAll(",\n");
            }
        }
    }
    try file.writeAll("\n    ];\n");

    try file.writeAll(
        \\
        \\    const currentModule = document.querySelector('.sidebar .module-link.active').textContent;
        \\    const searchInput = document.getElementById('sidebar-search');
        \\    const modulesList = document.querySelector('.sidebar > ul');
        \\    const originalModulesList = modulesList.innerHTML;
        \\
        \\    // CMD+K / Ctrl+K to focus search
        \\    document.addEventListener('keydown', (e) => {
        \\      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        \\        e.preventDefault();
        \\        searchInput.focus();
        \\      }
        \\    });
        \\
        \\    // Search functionality
        \\    searchInput.addEventListener('input', (e) => {
        \\      const query = e.target.value.toLowerCase().trim();
        \\
        \\      if (!query) {
        \\        // Restore original sidebar
        \\        modulesList.innerHTML = originalModulesList;
        \\        return;
        \\      }
        \\
        \\      // Search across all modules
        \\      const results = searchData.filter(item =>
        \\        item.name.toLowerCase().includes(query) ||
        \\        item.signature.toLowerCase().includes(query) ||
        \\        item.module.toLowerCase().includes(query)
        \\      );
        \\
        \\      // Group results by module
        \\      const resultsByModule = {};
        \\      results.forEach(result => {
        \\        if (!resultsByModule[result.module]) {
        \\          resultsByModule[result.module] = [];
        \\        }
        \\        resultsByModule[result.module].push(result);
        \\      });
        \\
        \\      // Rebuild sidebar with search results
        \\      let html = '';
        \\      Object.keys(resultsByModule).sort().forEach(moduleName => {
        \\        const isActive = moduleName === currentModule;
        \\        html += '<li>';
        \\        html += `<a href="${moduleName}.html" class="module-link${isActive ? ' active' : ''}">${moduleName}</a>`;
        \\        html += '<ul class="nested">';
        \\        resultsByModule[moduleName].forEach(item => {
        \\          const href = isActive ? `#${item.name}` : `${moduleName}.html#${item.name}`;
        \\          html += `<li><a href="${href}">${item.name}</a></li>`;
        \\        });
        \\        html += '</ul>';
        \\        html += '</li>';
        \\      });
        \\
        \\      modulesList.innerHTML = html;
        \\    });
        \\
    );
    try file.writeAll("  </script>\n");
    try file.writeAll("</body>\n");
    try file.writeAll("</html>\n");
}
