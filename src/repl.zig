const std = @import("std");
const evaluator = @import("eval.zig");
const formatter = @import("formatter.zig");

const Color = enum {
    reset,
    green,
    red,
    blue,
    yellow,
    cyan,
    gray,

    fn code(self: Color) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .green => "\x1b[32m",
            .red => "\x1b[31m",
            .blue => "\x1b[34m",
            .yellow => "\x1b[33m",
            .cyan => "\x1b[36m",
            .gray => "\x1b[90m",
        };
    }
};

const PrintContext = struct {
    file: *std.fs.File,
    allocator: std.mem.Allocator,

    pub fn print(self: *const PrintContext, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        _ = try self.file.writeAll(text);
    }
};

fn colored(color: Color, text: []const u8, ctx: *const PrintContext) !void {
    try ctx.print("{s}{s}{s}", .{ color.code(), text, Color.reset.code() });
}

pub fn runReplDirect(
    allocator: std.mem.Allocator,
    stdout_file: *std.fs.File,
    stderr_file: *std.fs.File,
) !void {
    var stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };

    // Create print contexts that write directly to files
    const stdout = PrintContext{ .file = stdout_file, .allocator = allocator };
    const stderr = PrintContext{ .file = stderr_file, .allocator = allocator };
    // Create an arena allocator for the REPL session
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Initialize evaluation context that persists across inputs
    var global_env: ?*evaluator.Environment = null;
    var eval_ctx = evaluator.EvalContext{
        .allocator = allocator,
        .lazy_paths = &[_][]const u8{},
    };

    // Print welcome message
    try colored(.cyan, "Lazylang REPL", &stdout);
    try stdout.print(" v0.1.0\n", .{});
    try colored(.gray, "Type ", &stdout);
    try colored(.yellow, ":help", &stdout);
    try colored(.gray, " for help, ", &stdout);
    try colored(.yellow, ":quit", &stdout);
    try colored(.gray, " to exit\n\n", &stdout);

    var input_buffer = std.ArrayList(u8){};
    defer input_buffer.deinit(allocator);

    // Command history
    var history = std.ArrayList([]const u8){};
    defer {
        for (history.items) |cmd| {
            allocator.free(cmd);
        }
        history.deinit(allocator);
    }
    var history_index: ?usize = null;

    while (true) {
        // Show prompt
        if (input_buffer.items.len == 0) {
            try colored(.green, "> ", &stdout);
        } else {
            try colored(.gray, ".. ", &stdout);
        }

        // Read a line with arrow key support
        const line = try readLineWithHistory(
            allocator,
            &stdin_file,
            &stdout,
            &history,
            &history_index,
        );
        defer allocator.free(line);

        // Handle EOF
        if (line.len == 0 and input_buffer.items.len == 0) {
            try stdout.print("\n", .{});
            break;
        }

        // Check for special commands
        if (input_buffer.items.len == 0) {
            if (std.mem.eql(u8, line, ":quit") or std.mem.eql(u8, line, ":q")) {
                break;
            }
            if (std.mem.eql(u8, line, ":help") or std.mem.eql(u8, line, ":h")) {
                try printHelp(stdout);
                continue;
            }
            if (std.mem.eql(u8, line, ":clear") or std.mem.eql(u8, line, ":c")) {
                // Reset the environment
                global_env = null;
                arena.deinit();
                arena = std.heap.ArenaAllocator.init(allocator);
                try colored(.gray, "Environment cleared\n", &stdout);
                continue;
            }
        }

        // Accumulate input
        if (input_buffer.items.len > 0) {
            try input_buffer.append(allocator, '\n');
        }
        try input_buffer.appendSlice(allocator, line);

        // Skip empty lines
        if (std.mem.trim(u8, input_buffer.items, " \t\r\n").len == 0) {
            input_buffer.clearRetainingCapacity();
            continue;
        }

        // Try to parse and evaluate
        const input = input_buffer.items;

        // Check if input looks incomplete (very basic heuristic)
        if (isIncompleteInput(input)) {
            continue;
        }

        // Check if this looks like a top-level binding (e.g., "x = 42")
        // If so, we'll transform it to "x = 42; x" so the parser creates a proper let expression
        const transformed_input = blk: {
            var temp_input = input;
            // Try to detect pattern: identifier = expression
            if (std.mem.indexOfScalar(u8, input, '=')) |eq_pos| {
                // Extract the identifier before the equals sign
                const before_eq = std.mem.trim(u8, input[0..eq_pos], " \t\n");
                // Check if it's a simple identifier
                if (isSimpleIdentifier(before_eq)) {
                    // Check if there's already something after the value
                    const after_eq = std.mem.trim(u8, input[eq_pos + 1 ..], " \t\n");
                    if (after_eq.len > 0 and !std.mem.containsAtLeast(u8, after_eq, 1, "\n")) {
                        // Single line binding - append the identifier to return it
                        // Use arena_allocator so the string persists for the environment
                        var transformed = std.ArrayList(u8){};
                        errdefer transformed.deinit(arena_allocator);
                        try transformed.appendSlice(arena_allocator, input);
                        try transformed.append(arena_allocator, '\n');
                        try transformed.appendSlice(arena_allocator, before_eq);
                        temp_input = try transformed.toOwnedSlice(arena_allocator);
                        break :blk temp_input;
                    }
                }
            }
            break :blk input;
        };

        // Try to parse
        var parser = evaluator.Parser.init(arena_allocator, transformed_input) catch |err| {
            try printError(stderr, "Parse error", @errorName(err));
            input_buffer.clearRetainingCapacity();
            continue;
        };

        const expression = parser.parse() catch |err| {
            // Check if this might be an incomplete input
            if (err == error.UnexpectedToken or err == error.ExpectedExpression) {
                // Try adding more lines
                continue;
            }
            try printError(stderr, "Parse error", @errorName(err));
            input_buffer.clearRetainingCapacity();
            continue;
        };

        // Evaluate the expression
        // For let expressions, we need to handle them specially to preserve bindings
        const value = if (expression.* == .let) blk: {
            const let_expr = expression.let;
            // Evaluate the value
            const bound_value = evaluator.evaluateExpression(
                arena_allocator,
                let_expr.value,
                global_env,
                ".",
                &eval_ctx,
            ) catch |err| {
                try printError(stderr, "Evaluation error", @errorName(err));
                input_buffer.clearRetainingCapacity();
                continue;
            };

            // Update the global environment with the new binding
            global_env = evaluator.matchPattern(
                arena_allocator,
                let_expr.pattern,
                bound_value,
                global_env,
            ) catch |err| {
                try printError(stderr, "Pattern match error", @errorName(err));
                input_buffer.clearRetainingCapacity();
                continue;
            };

            // Return the bound value as the result
            break :blk bound_value;
        } else evaluator.evaluateExpression(
            arena_allocator,
            expression,
            global_env,
            ".", // current directory
            &eval_ctx,
        ) catch |err| {
            try printError(stderr, "Evaluation error", @errorName(err));
            input_buffer.clearRetainingCapacity();
            continue;
        };

        // Format and print the result
        const formatted = try evaluator.formatValue(allocator, value);
        defer allocator.free(formatted);

        try colored(.blue, "=> ", &stdout);

        // Try to format the output nicely
        if (shouldFormatAsMultiline(formatted)) {
            try stdout.print("\n", .{});
            var formatted_output = formatter.formatSource(allocator, formatted) catch {
                // If formatting fails, just print the raw output
                try stdout.print("{s}\n", .{formatted});
                input_buffer.clearRetainingCapacity();
                continue;
            };
            defer formatted_output.deinit();
            try stdout.print("{s}", .{formatted_output.text});
        } else {
            try stdout.print("{s}\n", .{formatted});
        }

        input_buffer.clearRetainingCapacity();
    }

    try colored(.cyan, "Goodbye!\n", &stdout);
}

fn isIncompleteInput(input: []const u8) bool {
    // Very basic heuristic: check for unbalanced brackets/braces
    var brace_count: i32 = 0;
    var bracket_count: i32 = 0;
    var paren_count: i32 = 0;
    var in_string = false;
    var escape_next = false;

    for (input) |c| {
        if (escape_next) {
            escape_next = false;
            continue;
        }

        if (c == '\\') {
            escape_next = true;
            continue;
        }

        if (c == '"') {
            in_string = !in_string;
            continue;
        }

        if (in_string) continue;

        switch (c) {
            '{' => brace_count += 1,
            '}' => brace_count -= 1,
            '[' => bracket_count += 1,
            ']' => bracket_count -= 1,
            '(' => paren_count += 1,
            ')' => paren_count -= 1,
            else => {},
        }
    }

    return brace_count > 0 or bracket_count > 0 or paren_count > 0;
}

fn shouldFormatAsMultiline(text: []const u8) bool {
    // Format as multiline if it contains newlines or is long
    if (std.mem.indexOf(u8, text, "\n") != null) return true;
    if (text.len > 60) return true;
    // Also format if it starts with { or [
    if (text.len > 0 and (text[0] == '{' or text[0] == '[')) {
        return text.len > 20;
    }
    return false;
}

fn printHelp(stdout: anytype) !void {
    try colored(.cyan, "Lazylang REPL Help\n", &stdout);
    try stdout.print("\n", .{});
    try colored(.yellow, "Commands:\n", &stdout);
    try stdout.print("  ", .{});
    try colored(.green, ":help", &stdout);
    try stdout.print(" or ", .{});
    try colored(.green, ":h", &stdout);
    try stdout.print("      Show this help message\n", .{});
    try stdout.print("  ", .{});
    try colored(.green, ":quit", &stdout);
    try stdout.print(" or ", .{});
    try colored(.green, ":q", &stdout);
    try stdout.print("      Exit the REPL\n", .{});
    try stdout.print("  ", .{});
    try colored(.green, ":clear", &stdout);
    try stdout.print(" or ", .{});
    try colored(.green, ":c", &stdout);
    try stdout.print("     Clear the environment\n", .{});
    try stdout.print("\n", .{});
    try colored(.yellow, "Usage:\n", &stdout);
    try stdout.print("  Type any Lazylang expression and press Enter\n", .{});
    try stdout.print("  Multi-line expressions are supported\n", .{});
    try stdout.print("  Variables persist between commands\n", .{});
    try stdout.print("\n", .{});
    try colored(.yellow, "Examples:\n", &stdout);
    try stdout.print("  ", .{});
    try colored(.gray, ">", &stdout);
    try stdout.print(" 1 + 2\n", .{});
    try stdout.print("  ", .{});
    try colored(.gray, ">", &stdout);
    try stdout.print(" x = 42\n", .{});
    try stdout.print("  ", .{});
    try colored(.gray, ">", &stdout);
    try stdout.print(" x * 2\n", .{});
    try stdout.print("  ", .{});
    try colored(.gray, ">", &stdout);
    try stdout.print(" {{ name: \"Alice\", age: 30 }}\n", .{});
    try stdout.print("\n", .{});
}

fn printError(stderr: anytype, title: []const u8, message: []const u8) !void {
    try colored(.red, "Error: ", &stderr);
    try stderr.print("{s}\n", .{title});
    try colored(.gray, "  ", &stderr);
    try stderr.print("{s}\n", .{message});
}

fn isSimpleIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    // Check if it's a valid identifier: starts with letter or underscore, contains only alphanumeric or underscore
    for (text, 0..) |c, i| {
        if (i == 0) {
            if (!std.ascii.isAlphabetic(c) and c != '_') return false;
        } else {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
    }
    return true;
}

fn readLineWithHistory(
    allocator: std.mem.Allocator,
    stdin_file: *std.fs.File,
    stdout: *const PrintContext,
    history: *std.ArrayList([]const u8),
    history_index: *?usize,
) ![]const u8 {
    var line_buffer = std.ArrayList(u8){};
    // DON'T defer deinit - we're returning a slice from it
    // defer line_buffer.deinit(allocator);

    var cursor_pos: usize = 0;
    var eof_seen = false;

    while (true) {
        var byte: [1]u8 = undefined;
        const n = stdin_file.read(&byte) catch |err| {
            return err;
        };

        if (n == 0) {
            eof_seen = true;
            break;
        }

        const ch = byte[0];

        // Handle newline
        if (ch == '\n') {
            try stdout.print("\n", .{});
            break;
        }

        // Handle escape sequences (arrow keys)
        if (ch == 0x1b) {
            // Read next two bytes for escape sequence
            var seq: [2]u8 = undefined;
            const seq_n = stdin_file.read(&seq) catch break;

            if (seq_n >= 2 and seq[0] == '[') {
                // Arrow keys
                if (seq[1] == 'A') { // Up arrow
                    if (history.items.len > 0) {
                        // Clear current line
                        try clearLine(stdout, line_buffer.items.len);

                        // Get history item
                        if (history_index.*) |idx| {
                            if (idx > 0) {
                                history_index.* = idx - 1;
                            }
                        } else {
                            history_index.* = history.items.len - 1;
                        }

                        if (history_index.*) |idx| {
                            const hist_cmd = history.items[idx];
                            line_buffer.clearRetainingCapacity();
                            try line_buffer.appendSlice(allocator, hist_cmd);
                            cursor_pos = line_buffer.items.len;
                            try stdout.print("{s}", .{hist_cmd});
                        }
                    }
                    continue;
                } else if (seq[1] == 'B') { // Down arrow
                    if (history_index.*) |idx| {
                        // Clear current line
                        try clearLine(stdout, line_buffer.items.len);

                        if (idx < history.items.len - 1) {
                            history_index.* = idx + 1;
                            const hist_cmd = history.items[idx + 1];
                            line_buffer.clearRetainingCapacity();
                            try line_buffer.appendSlice(allocator, hist_cmd);
                            cursor_pos = line_buffer.items.len;
                            try stdout.print("{s}", .{hist_cmd});
                        } else {
                            // At the end of history, clear line
                            history_index.* = null;
                            line_buffer.clearRetainingCapacity();
                            cursor_pos = 0;
                        }
                    }
                    continue;
                }
            }
            continue;
        }

        // Handle backspace (127 or 8)
        if (ch == 127 or ch == 8) {
            if (cursor_pos > 0 and line_buffer.items.len > 0) {
                _ = line_buffer.pop();
                cursor_pos -= 1;
                // Move cursor back, write space, move back again
                try stdout.print("\x08 \x08", .{});
            }
            continue;
        }

        // Handle Ctrl+C
        if (ch == 3) {
            try stdout.print("^C\n", .{});
            line_buffer.clearRetainingCapacity();
            return "";
        }

        // Handle Ctrl+D (EOF)
        if (ch == 4) {
            if (line_buffer.items.len == 0) {
                return "";
            }
            continue;
        }

        // Regular character
        if (ch >= 32 and ch < 127) {
            try line_buffer.append(allocator, ch);
            cursor_pos += 1;
            try stdout.print("{c}", .{ch});
        }
    }

    // If we saw EOF with no input, return empty to signal exit
    if (eof_seen and line_buffer.items.len == 0) {
        line_buffer.deinit(allocator);
        return "";
    }

    // Trim whitespace
    const trimmed = std.mem.trim(u8, line_buffer.items, " \t\r");

    // Make a copy since we're going to free line_buffer
    const result = try allocator.dupe(u8, trimmed);
    line_buffer.deinit(allocator);

    // Add non-empty, non-command lines to history
    if (result.len > 0 and result[0] != ':') {
        // Don't add if it's the same as the last command
        const should_add = if (history.items.len > 0)
            !std.mem.eql(u8, history.items[history.items.len - 1], result)
        else
            true;

        if (should_add) {
            const hist_copy = try allocator.dupe(u8, result);
            try history.append(allocator, hist_copy);
        }
    }

    // Reset history index
    history_index.* = null;

    return result;
}

fn clearLine(stdout: *const PrintContext, len: usize) !void {
    // Move cursor to beginning of line
    try stdout.print("\r", .{});
    // Print spaces to clear
    for (0..len + 2) |_| { // +2 for prompt
        try stdout.print(" ", .{});
    }
    // Move cursor back to beginning
    try stdout.print("\r", .{});
    // Reprint prompt
    try colored(.green, "> ", stdout);
}
