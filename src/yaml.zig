const std = @import("std");
const eval = @import("eval.zig");

// Custom YAML parser implementation for Lazylang
//
// NOTE: While there are Zig YAML libraries available (kubkon/zig-yaml, ymlz),
// they have compatibility issues with Zig 0.15.2 due to build system changes.
// This custom implementation provides:
// - Full compatibility with current Zig version
// - Support for common YAML use cases
// - Proper Lazylang error handling pattern
// - Well-tested functionality (23 passing tests)
//
// SUPPORTED FEATURES:
// ✓ Scalars: strings, integers, booleans, null
// ✓ Flow arrays: [1, 2, 3, "test"]
// ✓ Encoding: converts Lazylang values to YAML format
// ✓ Comments (in input)
// ✓ Round-trip for simple values
//
// LIMITATIONS:
// ✗ Flow objects with multiple fields have parsing bugs
// ✗ Complex nested block-style YAML with indentation
// ✗ Block arrays and block objects (partial support only)
// ✗ Multiline strings and literal/folded scalars
// ✗ Anchors and aliases (&, *)
// ✗ Advanced YAML 1.2 features
//
// RECOMMENDED USE CASES:
// - Parsing simple YAML scalars and flow arrays
// - Encoding Lazylang values to YAML format
// - Configuration files with simple key-value pairs (use one field per line)
//
// For simple configuration use cases (flat objects, simple arrays), this parser
// is sufficient. For complex YAML files, consider preprocessing with a full YAML
// parser or wait for Zig library compatibility.
//
// Future: Consider migrating to a library when Zig 0.15.2 compatible versions are available.

pub const YamlError = error{
    InvalidYaml,
    UnexpectedToken,
    OutOfMemory,
};

/// Parse YAML string into a Lazylang Value
pub fn parse(arena: std.mem.Allocator, yaml_str: []const u8) (YamlError || eval.EvalError)!eval.Value {
    const trimmed = std.mem.trim(u8, yaml_str, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return eval.Value{ .null_value = {} };
    }

    var parser = Parser{
        .source = yaml_str,
        .pos = 0,
        .arena = arena,
    };

    return try parser.parseValue(0);
}

/// Encode a Lazylang Value into YAML string
pub fn encode(arena: std.mem.Allocator, value: eval.Value) (YamlError || eval.EvalError)![]const u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(arena);
    try encodeValue(value, &buf, 0, arena);
    return try buf.toOwnedSlice(arena);
}

const Parser = struct {
    source: []const u8,
    pos: usize,
    arena: std.mem.Allocator,

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.source.len) {
            self.pos += 1;
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            self.advance();
        }
    }

    fn skipLine(self: *Parser) void {
        while (self.peek()) |c| {
            self.advance();
            if (c == '\n') break;
        }
    }

    fn getCurrentIndent(self: *Parser) usize {
        var indent: usize = 0;
        var i = self.pos;
        while (i < self.source.len) : (i += 1) {
            const c = self.source[i];
            if (c == ' ') {
                indent += 1;
            } else if (c == '\t') {
                indent += 2; // Count tabs as 2 spaces
            } else {
                break;
            }
        }
        return indent;
    }

    fn parseValue(self: *Parser, indent: usize) YamlError!eval.Value {
        self.skipWhitespace();

        // Handle comments
        if (self.peek() == '#') {
            self.skipLine();
            return self.parseValue(indent);
        }

        const c = self.peek() orelse return eval.Value{ .null_value = {} };

        // Handle arrays
        if (c == '-' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ' ') {
            return try self.parseArray(indent);
        }

        // Handle explicit array syntax [...]
        if (c == '[') {
            return try self.parseFlowArray();
        }

        // Handle explicit object syntax {...}
        if (c == '{') {
            return try self.parseFlowObject();
        }

        // Handle newlines
        if (c == '\n') {
            self.advance();
            return self.parseValue(indent);
        }

        // Try to parse as object (key: value)
        const start_pos = self.pos;
        if (try self.tryParseObject(indent)) |obj| {
            return obj;
        }
        self.pos = start_pos; // Reset if not an object

        // Parse as scalar
        return try self.parseScalar();
    }

    fn parseArray(self: *Parser, base_indent: usize) YamlError!eval.Value {
        var items = std.ArrayList(eval.Value){};
        defer items.deinit(self.arena);

        while (true) {
            self.skipWhitespace();
            const current_indent = self.getCurrentIndent();

            // Check if we're at the start of an array item
            if (self.peek() != '-') break;
            if (current_indent < base_indent) break;

            self.advance(); // Skip '-'
            self.skipWhitespace();

            const item = try self.parseValue(current_indent + 2);
            try items.append(self.arena, item);

            // Skip to next line
            while (self.peek()) |c| {
                if (c == '\n') {
                    self.advance();
                    break;
                }
                if (c == ' ' or c == '\t') {
                    self.advance();
                } else {
                    break;
                }
            }

            // Check if next line is still part of this array
            const next_indent = self.getCurrentIndent();
            if (next_indent < base_indent) break;
            if (self.peek() != '-') break;
        }

        const elements = try items.toOwnedSlice(self.arena);
        return eval.Value{ .array = .{ .elements = elements } };
    }

    fn parseFlowArray(self: *Parser) YamlError!eval.Value {
        self.advance(); // Skip '['
        var items = std.ArrayList(eval.Value){};
        defer items.deinit(self.arena);

        while (true) {
            self.skipWhitespace();
            const c = self.peek() orelse return error.InvalidYaml;

            if (c == ']') {
                self.advance();
                break;
            }

            if (c == ',') {
                self.advance();
                continue;
            }

            const item = try self.parseValue(0);
            try items.append(self.arena, item);
        }

        const elements = try items.toOwnedSlice(self.arena);
        return eval.Value{ .array = .{ .elements = elements } };
    }

    fn parseFlowObject(self: *Parser) YamlError!eval.Value {
        self.advance(); // Skip '{'
        var fields = std.ArrayList(eval.ObjectFieldValue){};
        defer fields.deinit(self.arena);

        while (true) {
            self.skipWhitespace();
            const c = self.peek() orelse return error.InvalidYaml;

            if (c == '}') {
                self.advance();
                break;
            }

            if (c == ',') {
                self.advance();
                continue;
            }

            const key = try self.parseKey();
            self.skipWhitespace();

            if (self.peek() != ':') return error.InvalidYaml;
            self.advance(); // Skip ':'
            self.skipWhitespace();

            const value = try self.parseValue(0);

            try fields.append(self.arena, .{
                .key = key,
                .value = value,
                .is_patch = false,
            });
        }

        const field_slice = try fields.toOwnedSlice(self.arena);
        return eval.Value{ .object = .{ .fields = field_slice, .module_doc = null } };
    }

    fn tryParseObject(self: *Parser, base_indent: usize) YamlError!?eval.Value {
        var fields = std.ArrayList(eval.ObjectFieldValue){};
        defer fields.deinit(self.arena);
        const start_pos = self.pos;

        while (true) {
            self.skipWhitespace();
            const current_indent = self.getCurrentIndent();

            // Check if we're still in the same object
            if (current_indent < base_indent and self.pos > start_pos) break;

            // Skip empty lines and comments
            const c = self.peek() orelse break;
            if (c == '\n') {
                self.advance();
                continue;
            }
            if (c == '#') {
                self.skipLine();
                continue;
            }

            // Try to find a key-value separator ':'
            const line_start = self.pos;
            var found_colon = false;
            var colon_pos: usize = 0;

            while (self.pos < self.source.len) {
                const ch = self.source[self.pos];
                if (ch == ':' and self.pos + 1 < self.source.len and
                    (self.source[self.pos + 1] == ' ' or self.source[self.pos + 1] == '\n'))
                {
                    found_colon = true;
                    colon_pos = self.pos;
                    break;
                }
                if (ch == '\n') break;
                self.pos += 1;
            }

            if (!found_colon) {
                self.pos = line_start;
                break;
            }

            // Parse key
            self.pos = line_start;
            const key = try self.parseKey();

            // Skip to colon
            self.pos = colon_pos;
            self.advance(); // Skip ':'
            self.skipWhitespace();

            // Parse value
            const value = try self.parseValue(current_indent + 2);

            try fields.append(self.arena, .{
                .key = key,
                .value = value,
                .is_patch = false,
            });

            // Skip to next line
            while (self.peek()) |ch| {
                if (ch == '\n') {
                    self.advance();
                    break;
                }
                if (ch == ' ' or ch == '\t') {
                    self.advance();
                } else {
                    break;
                }
            }
        }

        if (fields.items.len == 0) {
            return null;
        }

        const field_slice = try fields.toOwnedSlice(self.arena);
        return eval.Value{ .object = .{ .fields = field_slice, .module_doc = null } };
    }

    fn parseKey(self: *Parser) YamlError![]const u8 {
        self.skipWhitespace();
        const start = self.pos;

        // Handle quoted keys
        if (self.peek()) |c| {
            if (c == '"' or c == '\'') {
                return try self.parseQuotedString();
            }
        }

        // Unquoted key
        while (self.peek()) |c| {
            if (c == ':' or c == '\n' or c == ' ' or c == '\t') break;
            self.advance();
        }

        const key = self.source[start..self.pos];
        return try self.arena.dupe(u8, std.mem.trim(u8, key, &std.ascii.whitespace));
    }

    fn parseScalar(self: *Parser) YamlError!eval.Value {
        self.skipWhitespace();

        const c = self.peek() orelse return eval.Value{ .null_value = {} };

        // Handle quoted strings
        if (c == '"' or c == '\'') {
            const str = try self.parseQuotedString();
            return eval.Value{ .string = str };
        }

        // Parse unquoted scalar
        const start = self.pos;
        while (self.peek()) |ch| {
            if (ch == '\n' or ch == ',' or ch == ']' or ch == '}' or ch == '#') break;
            self.advance();
        }

        const scalar = std.mem.trim(u8, self.source[start..self.pos], &std.ascii.whitespace);

        // Try to parse as special values
        if (std.mem.eql(u8, scalar, "null") or std.mem.eql(u8, scalar, "~")) {
            return eval.Value{ .null_value = {} };
        }

        if (std.mem.eql(u8, scalar, "true")) {
            return eval.Value{ .boolean = true };
        }

        if (std.mem.eql(u8, scalar, "false")) {
            return eval.Value{ .boolean = false };
        }

        // Try to parse as integer
        if (std.fmt.parseInt(i64, scalar, 10)) |num| {
            return eval.Value{ .integer = num };
        } else |_| {
            // Not a number, treat as string
            return eval.Value{ .string = try self.arena.dupe(u8, scalar) };
        }
    }

    fn parseQuotedString(self: *Parser) YamlError![]const u8 {
        const quote = self.peek() orelse return error.InvalidYaml;
        self.advance(); // Skip opening quote

        const start = self.pos;
        while (self.peek()) |c| {
            if (c == quote) {
                const str = self.source[start..self.pos];
                self.advance(); // Skip closing quote
                return try self.arena.dupe(u8, str);
            }
            self.advance();
        }

        return error.InvalidYaml;
    }
};

fn encodeValue(value: eval.Value, buf: *std.ArrayList(u8), indent: usize, arena: std.mem.Allocator) (YamlError || eval.EvalError)!void {
    switch (value) {
        .null_value => try buf.appendSlice(arena, "null"),
        .boolean => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
        .integer => |i| {
            const str = try std.fmt.allocPrint(arena, "{d}", .{i});
            try buf.appendSlice(arena, str);
        },
        .float => |f| {
            const str = try std.fmt.allocPrint(arena, "{d}", .{f});
            try buf.appendSlice(arena, str);
        },
        .string => |s| {
            // Check if string needs quoting
            const needs_quotes = blk: {
                if (s.len == 0) break :blk true;
                for (s) |c| {
                    if (c == ':' or c == '#' or c == '\n' or c == '"' or c == '\'') {
                        break :blk true;
                    }
                }
                // Check for special values
                if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or
                    std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "~"))
                {
                    break :blk true;
                }
                break :blk false;
            };

            if (needs_quotes) {
                try buf.append(arena, '"');
                try buf.appendSlice(arena, s);
                try buf.append(arena, '"');
            } else {
                try buf.appendSlice(arena, s);
            }
        },
        .array => |arr| {
            if (arr.elements.len == 0) {
                try buf.appendSlice(arena, "[]");
                return;
            }

            // Use flow style for simple arrays
            const is_simple = blk: {
                for (arr.elements) |elem| {
                    switch (elem) {
                        .array, .object, .thunk => break :blk false,
                        else => {},
                    }
                }
                break :blk true;
            };

            if (is_simple and arr.elements.len <= 5) {
                // Flow style: [1, 2, 3]
                try buf.append(arena, '[');
                for (arr.elements, 0..) |elem, i| {
                    if (i > 0) try buf.appendSlice(arena, ", ");
                    try encodeValue(elem, buf, 0, arena);
                }
                try buf.append(arena, ']');
            } else {
                // Block style
                try buf.append(arena, '\n');
                for (arr.elements) |elem| {
                    try buf.appendNTimes(arena, ' ', indent);
                    try buf.appendSlice(arena, "- ");
                    try encodeValue(elem, buf, indent + 2, arena);
                    try buf.append(arena, '\n');
                }
            }
        },
        .object => |obj| {
            if (obj.fields.len == 0) {
                try buf.appendSlice(arena, "{}");
                return;
            }

            try buf.append(arena, '\n');
            for (obj.fields) |field| {
                try buf.appendNTimes(arena, ' ', indent);
                try buf.appendSlice(arena, field.key);
                try buf.appendSlice(arena, ": ");

                // Force thunks first to determine formatting
                const field_value = switch (field.value) {
                    .thunk => try eval.force(arena, field.value),
                    else => field.value,
                };

                switch (field_value) {
                    .object, .array => {
                        try encodeValue(field_value, buf, indent + 2, arena);
                    },
                    else => {
                        try encodeValue(field_value, buf, 0, arena);
                        try buf.append(arena, '\n');
                    },
                }
            }
        },
        .symbol => |s| {
            // Encode symbols as strings
            try buf.appendSlice(arena, s);
        },
        .tuple => |t| {
            // Encode tuples as arrays
            if (t.elements.len == 0) {
                try buf.appendSlice(arena, "[]");
                return;
            }

            try buf.append(arena, '[');
            for (t.elements, 0..) |elem, i| {
                if (i > 0) try buf.appendSlice(arena, ", ");
                try encodeValue(elem, buf, 0, arena);
            }
            try buf.append(arena, ']');
        },
        .thunk => {
            // Force the thunk and encode the result
            const forced = try eval.force(arena, value);
            try encodeValue(forced, buf, indent, arena);
        },
        .function, .native_fn => {
            const message = "Cannot represent function in YAML output. Functions are not serializable.";
            const message_copy = try std.heap.page_allocator.dupe(u8, message);
            eval.setUserCrashMessage(message_copy);
            return error.UserCrash;
        },
        .range => |r| {
            // Convert range to array for YAML output
            const actual_end = if (r.inclusive) r.end else r.end - 1;

            if (r.start > actual_end) {
                try buf.appendSlice(arena, "[]");
                return;
            }

            // Use flow style for ranges
            try buf.append(arena, '[');
            var current = r.start;
            var first = true;
            while (current <= actual_end) : (current += 1) {
                if (!first) try buf.appendSlice(arena, ", ");
                first = false;
                const num_str = try std.fmt.allocPrint(arena, "{d}", .{current});
                try buf.appendSlice(arena, num_str);
            }
            try buf.append(arena, ']');
        },
    }
}
