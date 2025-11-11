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
        else => error_reporter.ErrorInfo{
            .title = "Error",
            .location = null,
            .message = @errorName(err),
            .suggestion = null,
        },
    };

    try error_reporter.reportError(stderr, source, filename, error_info);
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
        const path = args[0];

        // Check if it's a directory
        const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr.print("error: path not found: {s}\n", .{path});
                return .{ .exit_code = 1 };
            },
            else => return err,
        };

        if (stat.kind == .directory) {
            // Run all specs in the directory recursively
            const result = spec.runAllSpecs(allocator, path, stdout) catch |err| {
                try stderr.print("error: failed to run specs: {}\n", .{err});
                return .{ .exit_code = 1 };
            };
            return .{ .exit_code = result.exitCode() };
        } else {
            // Run the specific spec file
            const result = spec.runSpec(allocator, path, stdout) catch |err| {
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

    // Check if input is a directory or file
    const stat = std.fs.cwd().statFile(input_path.?) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print("error: path not found: {s}\n", .{input_path.?});
            return .{ .exit_code = 1 };
        },
        else => return err,
    };

    if (stat.kind == .directory) {
        // Process directory recursively
        try generateDocsForDirectory(allocator, input_path.?, output_dir, stdout, stderr);
    } else {
        // Process single file
        try generateDocs(allocator, input_path.?, output_dir, stdout, stderr);
    }

    try stdout.print("Documentation generated in {s}/\n", .{output_dir});
    return .{ .exit_code = 0 };
}

fn generateDocsForDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    output_dir: []const u8,
    stdout: anytype,
    stderr: anytype,
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

        try stdout.print("Generating docs for {s}...\n", .{full_path});
        try generateDocs(allocator, full_path, output_dir, stdout, stderr);
    }
}

fn generateDocs(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_dir: []const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    _ = stdout;
    _ = stderr;

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

    // Generate HTML
    const module_name = std.fs.path.stem(input_path);
    const html_filename = try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ output_dir, module_name });
    defer allocator.free(html_filename);

    const html_file = try std.fs.cwd().createFile(html_filename, .{});
    defer html_file.close();

    try writeHtmlDocs(&html_file, module_name, doc_items.items);

    doc_items.deinit(allocator);
}

const DocItem = struct {
    name: []const u8,
    doc: []const u8,
    kind: DocKind,
};

const DocKind = enum {
    variable,
    field,
};

fn extractDocs(expr: *const evaluator.Expression, items: *std.ArrayListUnmanaged(DocItem), allocator: std.mem.Allocator) !void {
    switch (expr.*) {
        .let => |let_expr| {
            if (let_expr.doc) |doc| {
                // Extract the name from the pattern
                const name = switch (let_expr.pattern.*) {
                    .identifier => |ident| ident,
                    else => "unknown",
                };
                try items.append(allocator, .{
                    .name = name,
                    .doc = doc,
                    .kind = .variable,
                });
            }
            try extractDocs(let_expr.body, items, allocator);
        },
        .object => |obj| {
            for (obj.fields) |field| {
                if (field.doc) |doc| {
                    try items.append(allocator, .{
                        .name = field.key,
                        .doc = doc,
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

fn writeHtmlDocs(file: anytype, module_name: []const u8, items: []const DocItem) !void {
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
        \\    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; background: #f5f5f5; }
        \\    .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        \\    header { background: #2c3e50; color: white; padding: 30px 0; margin-bottom: 30px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        \\    h1 { font-size: 2.5em; font-weight: 300; }
        \\    .search-box { margin: 20px 0; }
        \\    .search-box input { width: 100%; padding: 12px 20px; font-size: 16px; border: 2px solid #ddd; border-radius: 6px; }
        \\    .search-box input:focus { outline: none; border-color: #3498db; }
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
        \\    @media (max-width: 768px) { .container { padding: 10px; } .doc-item { padding: 15px; } }
        \\
    );
    try file.writeAll("  </style>\n");
    try file.writeAll("</head>\n");
    try file.writeAll("<body>\n");
    try file.writeAll("  <header>\n");
    try file.writeAll("    <div class=\"container\">\n");
    try file.writeAll("      <h1>");
    try file.writeAll(module_name);
    try file.writeAll("</h1>\n");
    try file.writeAll("    </div>\n");
    try file.writeAll("  </header>\n");
    try file.writeAll("  <div class=\"container\">\n");
    try file.writeAll("    <div class=\"search-box\">\n");
    try file.writeAll("      <input type=\"text\" id=\"search\" placeholder=\"Search functions and values...\" />\n");
    try file.writeAll("    </div>\n");
    try file.writeAll("    <div id=\"docs\">\n");

    // We need access to allocator for markdown rendering
    // For now, let's use a stack allocator approach with a larger buffer
    var buffer: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const temp_allocator = fba.allocator();

    for (items) |item| {
        try file.writeAll("      <div class=\"doc-item\" data-name=\"");
        try file.writeAll(item.name);
        try file.writeAll("\">\n");
        try file.writeAll("        <h2>");
        try file.writeAll(item.name);
        try file.writeAll("</h2>\n");
        try file.writeAll("        <span class=\"kind\">");
        try file.writeAll(@tagName(item.kind));
        try file.writeAll("</span>\n");
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
    try file.writeAll("  </div>\n");
    try file.writeAll("  <script>\n");
    try file.writeAll(
        \\    const searchInput = document.getElementById('search');
        \\    const docItems = document.querySelectorAll('.doc-item');
        \\    searchInput.addEventListener('input', (e) => {
        \\      const query = e.target.value.toLowerCase();
        \\      docItems.forEach(item => {
        \\        const name = item.dataset.name.toLowerCase();
        \\        const text = item.textContent.toLowerCase();
        \\        item.style.display = (name.includes(query) || text.includes(query)) ? 'block' : 'none';
        \\      });
        \\    });
        \\
    );
    try file.writeAll("  </script>\n");
    try file.writeAll("</body>\n");
    try file.writeAll("</html>\n");
}
