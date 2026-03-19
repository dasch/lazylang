const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const tokenizer_mod = @import("tokenizer.zig");
const error_context = @import("error_context.zig");

const MAX_LINE_WIDTH: usize = 100;

pub const FormatterError = error{
    ParseError,
    FormatError,
} || std.mem.Allocator.Error;

pub const FormatterOutput = struct {
    text: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FormatterOutput) void {
        self.allocator.free(self.text);
    }
};

const Comment = struct {
    text: []const u8,
    line: usize,
    is_doc: bool,
    is_inline: bool, // true if comment appears after code on the same line
    blank_line_before: bool,
};

const Writer = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: usize,
    at_line_start: bool,
    comments: []const Comment,
    next_comment: usize,
    last_source_line: usize,
    source: []const u8,

    fn init(allocator: std.mem.Allocator, comments: []const Comment, source: []const u8) Writer {
        return .{
            .buf = std.ArrayList(u8){},
            .allocator = allocator,
            .indent = 0,
            .at_line_start = true,
            .comments = comments,
            .next_comment = 0,
            .last_source_line = 0,
            .source = source,
        };
    }

    /// Emit a blank line if the source had one before this line
    fn preserveBlankLine(self: *Writer, source_line: usize) !void {
        if (source_line > self.last_source_line + 1 and self.last_source_line > 0) {
            // Source had a gap — check if there was a blank line
            if (hasBlankLineBetween(self.source, self.last_source_line, source_line)) {
                try self.blankLine();
            }
        }
        self.last_source_line = source_line;
    }

    fn currentColumn(self: *const Writer) usize {
        if (self.at_line_start) return self.indent * 2;
        // Walk back from end to find last newline
        var i = self.buf.items.len;
        while (i > 0) {
            i -= 1;
            if (self.buf.items[i] == '\n') return self.buf.items.len - i - 1;
        }
        return self.buf.items.len;
    }

    fn write(self: *Writer, text: []const u8) !void {
        if (self.at_line_start and text.len > 0 and text[0] != '\n') {
            try self.writeIndent();
            self.at_line_start = false;
        }
        try self.buf.appendSlice(self.allocator, text);
    }

    fn writeByte(self: *Writer, byte: u8) !void {
        if (self.at_line_start and byte != '\n') {
            try self.writeIndent();
            self.at_line_start = false;
        }
        try self.buf.append(self.allocator, byte);
    }

    fn newline(self: *Writer) !void {
        try self.buf.append(self.allocator, '\n');
        self.at_line_start = true;
    }

    fn blankLine(self: *Writer) !void {
        if (!endsWith2Newlines(self.buf.items)) {
            try self.newline();
        }
    }

    fn writeIndent(self: *Writer) !void {
        for (0..self.indent) |_| {
            try self.buf.appendSlice(self.allocator, "  ");
        }
    }

    fn emitCommentsBefore(self: *Writer, before_line: usize) !void {
        while (self.next_comment < self.comments.len) {
            const comment = self.comments[self.next_comment];
            if (comment.line >= before_line) break;
            if (comment.is_doc or comment.is_inline) {
                self.next_comment += 1;
                continue;
            }
            if (comment.blank_line_before and self.buf.items.len > 0) {
                try self.blankLine();
            }
            try self.write(comment.text);
            try self.newline();
            self.next_comment += 1;
        }
    }

    /// Emit any inline comment on the given source line
    fn emitInlineComment(self: *Writer, on_line: usize) !void {
        while (self.next_comment < self.comments.len) {
            const comment = self.comments[self.next_comment];
            if (comment.line > on_line) break;
            if (comment.line == on_line and comment.is_inline) {
                try self.write(" ");
                try self.write(comment.text);
                self.next_comment += 1;
                return;
            }
            self.next_comment += 1;
        }
    }

    fn emitRemainingComments(self: *Writer) !void {
        while (self.next_comment < self.comments.len) {
            const comment = self.comments[self.next_comment];
            if (comment.is_doc) {
                self.next_comment += 1;
                continue;
            }
            try self.write(comment.text);
            try self.newline();
            self.next_comment += 1;
        }
    }

    fn toOwnedSlice(self: *Writer) ![]const u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }
};

fn hasBlankLineBetween(source: []const u8, from_line: usize, to_line: usize) bool {
    var current_line: usize = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (current_line > from_line and current_line < to_line) {
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            if (trimmed.len == 0) return true;
        }
        current_line += 1;
    }
    return false;
}

fn endsWith2Newlines(s: []const u8) bool {
    return s.len >= 2 and s[s.len - 1] == '\n' and s[s.len - 2] == '\n';
}

/// Find an inline comment in a line (code followed by //)
/// Returns the comment text (including //) or null if no inline comment
fn findInlineComment(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;
    while (i < line.len) {
        if (in_string) {
            if (line[i] == '\\') {
                i += 2; // skip escape
                continue;
            }
            if (line[i] == string_char) {
                in_string = false;
            }
            i += 1;
            continue;
        }
        if (line[i] == '"' or line[i] == '\'') {
            in_string = true;
            string_char = line[i];
            i += 1;
            continue;
        }
        if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
            // Found comment — return trimmed
            return std.mem.trimLeft(u8, line[i..], " \t");
        }
        i += 1;
    }
    return null;
}

fn extractComments(allocator: std.mem.Allocator, source: []const u8) ![]Comment {
    var comments = std.ArrayList(Comment){};
    var line_num: usize = 1;
    var prev_was_blank = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) {
            prev_was_blank = true;
        } else if (std.mem.startsWith(u8, trimmed, "///")) {
            try comments.append(allocator, .{ .text = trimmed, .line = line_num, .is_doc = true, .is_inline = false, .blank_line_before = prev_was_blank });
            prev_was_blank = false;
        } else if (std.mem.startsWith(u8, trimmed, "//")) {
            try comments.append(allocator, .{ .text = trimmed, .line = line_num, .is_doc = false, .is_inline = false, .blank_line_before = prev_was_blank });
            prev_was_blank = false;
        } else {
            // Check for inline comment: code followed by //
            if (findInlineComment(line)) |comment_text| {
                try comments.append(allocator, .{ .text = comment_text, .line = line_num, .is_doc = false, .is_inline = true, .blank_line_before = false });
            }
            prev_was_blank = false;
        }
        line_num += 1;
    }
    return comments.toOwnedSlice(allocator);
}

// ============================================================================
// Width measurement — returns single-line width or null if inherently multi-line
// ============================================================================

fn measureExpr(expr: *const ast.Expression) ?usize {
    return switch (expr.data) {
        .integer => |v| digitCount(v),
        .float => |v| floatWidth(v),
        .boolean => |v| if (v) @as(usize, 4) else @as(usize, 5),
        .null_literal => 4,
        .string_literal => |s| s.len + 2,
        .symbol => |s| s.len,
        .identifier => |name| name.len,
        .field_access => |fa| {
            const obj_w = measureExpr(fa.object) orelse return null;
            return obj_w + 1 + fa.field.len;
        },
        .field_accessor => |fa| {
            var w: usize = 0;
            for (fa.fields, 0..) |field, i| {
                if (i > 0) w += 1;
                w += field.len;
            }
            return w + 1; // leading dot
        },
        .binary => |bin| {
            const lw = measureExpr(bin.left) orelse return null;
            const rw = measureExpr(bin.right) orelse return null;
            return lw + 3 + rw + binaryOpStr(bin.op).len - 1;
        },
        .unary => |un| {
            const ow = measureExpr(un.operand) orelse return null;
            return 1 + ow;
        },
        .application => |app| {
            if (app.is_do) return null; // do blocks are inherently multi-line
            const fw = measureExpr(app.function) orelse return null;
            const aw = measureExpr(app.argument) orelse return null;
            const needs_parens = switch (app.argument.data) {
                .application, .binary, .lambda, .let, .if_expr, .when_matches, .where_expr, .assert_expr, .unary => true,
                else => false,
            };
            return fw + 1 + aw + if (needs_parens) @as(usize, 2) else @as(usize, 0);
        },
        .operator_function => |op| binaryOpStr(op).len + 2,
        .tuple => |tup| {
            var w: usize = 2; // ( )
            for (tup.elements, 0..) |elem, i| {
                if (i > 0) w += 2;
                w += measureExpr(elem) orelse return null;
            }
            if (tup.elements.len == 1) w += 1; // trailing comma
            return w;
        },
        .array => |arr| measureArray(arr),
        .object => |obj| measureObject(obj),
        .import_expr => |imp| imp.path.len + 9, // import "..."
        .range => |r| {
            const sw = measureExpr(r.start) orelse return null;
            const ew = measureExpr(r.end) orelse return null;
            return sw + (if (r.inclusive) @as(usize, 2) else @as(usize, 3)) + ew;
        },
        .index => |idx| {
            const ow = measureExpr(idx.object) orelse return null;
            const iw = measureExpr(idx.index) orelse return null;
            return ow + iw + 2;
        },
        .if_expr => |ie| {
            const cw = measureExpr(ie.condition) orelse return null;
            const tw = measureExpr(ie.then_expr) orelse return null;
            var w: usize = 3 + cw + 6 + tw; // "if " + cond + " then " + then
            if (ie.else_expr) |ee| {
                const ew = measureExpr(ee) orelse return null;
                w += 6 + ew; // " else " + else
            }
            return w;
        },
        .string_interpolation => |interp| {
            var w: usize = 2; // quotes
            for (interp.parts) |part| {
                switch (part) {
                    .literal => |lit| w += lit.len,
                    .interpolation => |ie| {
                        if (ie.data == .identifier) {
                            w += 1 + ie.data.identifier.len;
                        } else {
                            const iw = measureExpr(ie) orelse return null;
                            w += 3 + iw; // ${ + expr + }
                        }
                    },
                }
            }
            return w;
        },
        .lambda => |lam| {
            const pw = measurePattern(lam.param) orelse return null;
            const bw = measureExpr(lam.body) orelse return null;
            return pw + 4 + bw; // " -> "
        },
        .field_projection => |fp| {
            const ow = measureExpr(fp.object) orelse return null;
            var w: usize = ow + 4; // ".{ " + " }"
            for (fp.fields, 0..) |field, i| {
                if (i > 0) w += 2;
                w += field.len;
            }
            return w;
        },
        .object_extend => |ext| {
            const bw = measureExpr(ext.base) orelse return null;
            var w: usize = bw + 4; // " { " + " }"
            for (ext.fields, 0..) |field, i| {
                if (i > 0) w += 2;
                const fw = measureFieldWidth(field) orelse return null;
                w += fw;
            }
            return w;
        },
        .array_comprehension => |comp| {
            var w: usize = 2; // [ ]
            w += measureExpr(comp.body) orelse return null;
            for (comp.clauses) |clause| {
                w += 5; // " for "
                w += measurePattern(clause.pattern) orelse return null;
                w += 4; // " in "
                w += measureExpr(clause.iterable) orelse return null;
            }
            if (comp.filter) |filter| {
                w += 6; // " when "
                w += measureExpr(filter) orelse return null;
            }
            return w;
        },
        .object_comprehension => |comp| {
            var w: usize = 6; // "{ [" + "]: " + " }"
            w += measureExpr(comp.key) orelse return null;
            w += measureExpr(comp.value) orelse return null;
            for (comp.clauses) |clause| {
                w += 5;
                w += measurePattern(clause.pattern) orelse return null;
                w += 4;
                w += measureExpr(clause.iterable) orelse return null;
            }
            if (comp.filter) |filter| {
                w += 6;
                w += measureExpr(filter) orelse return null;
            }
            return w;
        },
        // These are inherently multi-line
        .let, .when_matches, .where_expr, .assert_expr => null,
    };
}

fn measureArray(arr: ast.ArrayLiteral) ?usize {
    if (arr.elements.len == 0) return 2;
    var w: usize = 2; // [ ]
    for (arr.elements, 0..) |elem, i| {
        if (i > 0) w += 2;
        switch (elem) {
            .normal => |e| w += measureExpr(e) orelse return null,
            .spread, .conditional_if, .conditional_unless => return null,
        }
    }
    return w;
}

fn measureObject(obj: ast.ObjectLiteral) ?usize {
    if (obj.fields.len == 0) return 2;
    if (obj.fields.len > 2) return null; // 3+ fields always multi-line
    if (obj.module_doc != null) return null;
    var w: usize = 4; // "{ " + " }"
    for (obj.fields, 0..) |field, i| {
        if (i > 0) w += 2; // ", "
        if (field.doc != null) return null;
        if (field.is_patch) return null;
        if (field.condition != .none) return null;
        switch (field.key) {
            .static => |key| {
                if (needsQuoting(key)) {
                    w += key.len + 4; // "\"key\": "
                } else {
                    w += key.len + 2; // "key: "
                }
            },
            .dynamic => |key_expr| {
                // For dynamic keys: [expr]: adds brackets + ": "
                if (key_expr.data == .array) {
                    // Array literal as dynamic key: ["a", "b"]
                    w += (measureArray(key_expr.data.array) orelse return null) + 2; // ": "
                } else {
                    w += 1 + (measureExpr(key_expr) orelse return null) + 3; // "[" + expr + "]: "
                }
            },
        }
        w += measureExpr(field.value) orelse return null;
    }
    return w;
}

fn measureFieldWidth(field: ast.ObjectField) ?usize {
    if (field.doc != null) return null;
    if (field.condition != .none) return null;
    var w: usize = 0;
    switch (field.key) {
        .static => |key| {
            if (needsQuoting(key)) {
                w += key.len + 4;
            } else {
                w += key.len + 2;
            }
        },
        .dynamic => |key_expr| {
            if (key_expr.data == .array) {
                w += (measureArray(key_expr.data.array) orelse return null) + 2;
            } else {
                w += 1 + (measureExpr(key_expr) orelse return null) + 3;
            }
        },
    }
    if (field.is_patch) w -= 1;
    w += measureExpr(field.value) orelse return null;
    return w;
}

fn measurePattern(pat: *const ast.Pattern) ?usize {
    return switch (pat.data) {
        .identifier => |name| name.len,
        .integer => |v| digitCount(v),
        .float => |v| floatWidth(v),
        .boolean => |v| if (v) @as(usize, 4) else @as(usize, 5),
        .null_literal => 4,
        .symbol => |s| s.len,
        .string_literal => |s| s.len + 2,
        .tuple => |tup| {
            var w: usize = 2;
            for (tup.elements, 0..) |elem, i| {
                if (i > 0) w += 2;
                w += measurePattern(elem) orelse return null;
            }
            return w;
        },
        .array => |arr| {
            var w: usize = 2;
            for (arr.elements, 0..) |elem, i| {
                if (i > 0) w += 2;
                w += measurePattern(elem) orelse return null;
            }
            if (arr.rest) |rest| {
                if (arr.elements.len > 0) w += 2;
                w += 3 + rest.len;
            }
            return w;
        },
        .object => |obj| {
            var w: usize = 4;
            for (obj.fields, 0..) |field, i| {
                if (i > 0) w += 2;
                w += field.key.len;
                if (field.pattern.data != .identifier or
                    !std.mem.eql(u8, field.pattern.data.identifier, field.key))
                {
                    w += 2 + (measurePattern(field.pattern) orelse return null);
                }
            }
            return w;
        },
    };
}

fn digitCount(v: i64) usize {
    if (v == 0) return 1;
    var n = if (v < 0) ~v + 1 else v;
    var count: usize = if (v < 0) 1 else 0;
    while (n > 0) : (n = @divTrunc(n, 10)) count += 1;
    return count;
}

fn floatWidth(v: f64) usize {
    _ = v;
    return 8; // rough estimate
}

// ============================================================================
// Public API
// ============================================================================

pub fn formatSource(allocator: std.mem.Allocator, source: []const u8) FormatterError!FormatterOutput {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var err_ctx = error_context.ErrorContext.init(allocator);
    defer err_ctx.deinit();

    var parser = parser_mod.Parser.initWithContext(arena.allocator(), source, &err_ctx) catch {
        return FormatterError.ParseError;
    };
    const expression = parser.parse() catch {
        return FormatterError.ParseError;
    };

    const comments = try extractComments(arena.allocator(), source);

    var w = Writer.init(arena.allocator(), comments, source);

    try formatExpr(&w, expression, false);
    try w.emitRemainingComments();

    if (w.buf.items.len > 0 and w.buf.items[w.buf.items.len - 1] != '\n') {
        try w.newline();
    }

    // Copy output to caller's allocator (arena will be freed)
    const text = try allocator.dupe(u8, w.buf.items);
    return FormatterOutput{ .text = text, .allocator = allocator };
}

pub fn formatFile(allocator: std.mem.Allocator, path: []const u8) FormatterError!FormatterOutput {
    const file = std.fs.cwd().openFile(path, .{}) catch return FormatterError.FormatError;
    defer file.close();
    const source = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return FormatterError.FormatError;
    defer allocator.free(source);
    return formatSource(allocator, source);
}

// ============================================================================
// AST Pretty Printer
// ============================================================================

fn formatExpr(w: *Writer, expr: *const ast.Expression, parens_needed: bool) FormatterError!void {
    // Track source line for blank line preservation
    if (expr.location.line > 0) {
        w.last_source_line = expr.location.line;
    }

    // Wrap in parens if needed (except binary which handles its own parens)
    if (parens_needed and expr.data != .binary) {
        try w.writeByte('(');
    }
    defer if (parens_needed and expr.data != .binary) {
        w.writeByte(')') catch {};
    };

    switch (expr.data) {
        .integer => |v| {
            try w.write(try std.fmt.allocPrint(w.allocator, "{d}", .{v}));
        },
        .float => |v| {
            const s = try std.fmt.allocPrint(w.allocator, "{d}", .{v});
            if (std.mem.indexOf(u8, s, ".")) |dot| {
                var end = s.len;
                while (end > dot + 1 and s[end - 1] == '0') end -= 1;
                if (end == dot + 1) end = dot + 2;
                try w.write(s[0..end]);
            } else {
                // Always include .0 for floats (4.0 not 4)
                try w.write(s);
                try w.write(".0");
            }
        },
        .boolean => |v| try w.write(if (v) "true" else "false"),
        .null_literal => try w.write("null"),
        .string_literal => |s| {
            try w.writeByte('"');
            try writeEscapedString(w, s);
            try w.writeByte('"');
        },
        .symbol => |s| try w.write(s),
        .string_interpolation => |interp| {
            try w.writeByte('"');
            for (interp.parts) |part| {
                switch (part) {
                    .literal => |lit| try writeEscapedString(w, lit),
                    .interpolation => |ie| {
                        if (ie.data == .identifier) {
                            try w.writeByte('$');
                            try w.write(ie.data.identifier);
                        } else {
                            try w.write("${");
                            try formatExpr(w, ie, false);
                            try w.writeByte('}');
                        }
                    },
                }
            }
            try w.writeByte('"');
        },
        .identifier => |name| try w.write(name),
        .lambda => |lam| {
            try formatPattern(w, lam.param);
            // Check if the body fits on the same line
            const body_width = measureExpr(lam.body);
            const col = w.currentColumn();
            const param_width = measurePattern(lam.param) orelse 0;
            const fits = if (body_width) |bw| (col + param_width + 4 + bw <= MAX_LINE_WIDTH) else false;
            if (fits) {
                try w.write(" -> ");
                try formatExpr(w, lam.body, false);
            } else {
                try w.write(" ->");
                w.indent += 1;
                try w.newline();
                try formatExpr(w, lam.body, false);
                w.indent -= 1;
            }
        },
        .let => |let_expr| try formatLet(w, let_expr),
        .where_expr => |where| {
            try formatExpr(w, where.expr, false);
            try w.write(" where ");
            // Measure if all bindings fit on one line
            var total_width: ?usize = @as(usize, 0);
            for (where.bindings, 0..) |binding, i| {
                if (total_width) |*tw| {
                    if (i > 0) tw.* += 2; // "; "
                    tw.* += measurePattern(binding.pattern) orelse {
                        total_width = null;
                        break;
                    };
                    tw.* += 3; // " = "
                    tw.* += measureExpr(binding.value) orelse {
                        total_width = null;
                        break;
                    };
                }
            }
            const col = w.currentColumn();
            const fits = if (total_width) |tw| (col + tw <= MAX_LINE_WIDTH) else false;
            if (fits) {
                for (where.bindings, 0..) |binding, i| {
                    if (i > 0) try w.write("; ");
                    try formatPattern(w, binding.pattern);
                    try w.write(" = ");
                    try formatExpr(w, binding.value, false);
                }
            } else {
                w.indent += 1;
                for (where.bindings, 0..) |binding, i| {
                    if (i > 0) try w.newline();
                    try formatPattern(w, binding.pattern);
                    try w.write(" = ");
                    try formatExpr(w, binding.value, false);
                }
                w.indent -= 1;
            }
        },
        .unary => |un| {
            switch (un.op) {
                .logical_not => {
                    try w.writeByte('!');
                    try formatExpr(w, un.operand, true);
                },
            }
        },
        .binary => |bin| {
            if (parens_needed) try w.writeByte('(');
            try formatExpr(w, bin.left, needsParens(bin.left, bin.op));
            try w.writeByte(' ');
            try w.write(binaryOpStr(bin.op));
            try w.writeByte(' ');
            try formatExpr(w, bin.right, needsParens(bin.right, bin.op));
            if (parens_needed) try w.writeByte(')');
        },
        .application => |app| try formatApplication(w, app),
        .if_expr => |if_e| try formatIf(w, if_e),
        .when_matches => |wm| {
            try w.write("when ");
            try formatExpr(w, wm.value, false);
            try w.write(" matches");
            w.indent += 1;
            for (wm.branches) |branch| {
                try w.newline();
                try formatPattern(w, branch.pattern);
                try w.write(" then ");
                try formatExpr(w, branch.expression, false);
            }
            if (wm.otherwise) |otherwise| {
                try w.newline();
                try w.write("otherwise ");
                try formatExpr(w, otherwise, false);
            }
            w.indent -= 1;
        },
        .array => |arr| try formatArray(w, arr),
        .tuple => |tup| {
            try w.writeByte('(');
            for (tup.elements, 0..) |elem, i| {
                if (i > 0) try w.write(", ");
                try formatExpr(w, elem, false);
            }
            if (tup.elements.len == 1) try w.writeByte(',');
            try w.writeByte(')');
        },
        .object => |obj| try formatObject(w, obj),
        .object_extend => |ext| {
            try formatExpr(w, ext.base, false);
            try w.write(" { ");
            for (ext.fields, 0..) |field, i| {
                if (i > 0) try w.write(", ");
                try formatObjectField(w, field);
            }
            try w.write(" }");
        },
        .import_expr => |imp| {
            try w.write("import \"");
            try w.write(imp.path);
            try w.writeByte('"');
        },
        .array_comprehension => |comp| {
            try w.writeByte('[');
            try formatExpr(w, comp.body, false);
            for (comp.clauses) |clause| {
                try w.write(" for ");
                try formatPattern(w, clause.pattern);
                try w.write(" in ");
                try formatExpr(w, clause.iterable, false);
            }
            if (comp.filter) |filter| {
                try w.write(" when ");
                try formatExpr(w, filter, false);
            }
            try w.writeByte(']');
        },
        .object_comprehension => |comp| {
            try w.write("{ [");
            try formatExpr(w, comp.key, false);
            try w.write("]: ");
            try formatExpr(w, comp.value, false);
            for (comp.clauses) |clause| {
                try w.write(" for ");
                try formatPattern(w, clause.pattern);
                try w.write(" in ");
                try formatExpr(w, clause.iterable, false);
            }
            if (comp.filter) |filter| {
                try w.write(" when ");
                try formatExpr(w, filter, false);
            }
            try w.write(" }");
        },
        .field_access => |fa| {
            try formatExpr(w, fa.object, false);
            try w.writeByte('.');
            try w.write(fa.field);
        },
        .index => |idx| {
            try formatExpr(w, idx.object, false);
            try w.writeByte('[');
            try formatExpr(w, idx.index, false);
            try w.writeByte(']');
        },
        .field_accessor => |fa| {
            try w.writeByte('.');
            for (fa.fields, 0..) |field, i| {
                if (i > 0) try w.writeByte('.');
                try w.write(field);
            }
        },
        .field_projection => |fp| {
            try formatExpr(w, fp.object, false);
            try w.write(".{ ");
            for (fp.fields, 0..) |field, i| {
                if (i > 0) try w.write(", ");
                try w.write(field);
            }
            try w.write(" }");
        },
        .operator_function => |op| {
            try w.writeByte('(');
            try w.write(binaryOpStr(op));
            try w.writeByte(')');
        },
        .range => |r| {
            try formatExpr(w, r.start, false);
            try w.write(if (r.inclusive) ".." else "...");
            try formatExpr(w, r.end, false);
        },
        .assert_expr => |ae| {
            try w.write("assert ");
            try formatExpr(w, ae.condition, false);
            try w.write(": ");
            try formatExpr(w, ae.message, false);
            try w.newline();
            try formatExpr(w, ae.body, false);
        },
    }
}

fn formatLet(w: *Writer, let_expr: ast.Let) FormatterError!void {
    if (let_expr.doc) |doc| {
        var doc_lines = std.mem.splitScalar(u8, doc, '\n');
        while (doc_lines.next()) |doc_line| {
            const trimmed_doc = std.mem.trimRight(u8, doc_line, " \t");
            if (trimmed_doc.len == 0) {
                try w.write("///");
            } else {
                try w.write("/// ");
                try w.write(trimmed_doc);
            }
            try w.newline();
        }
    }

    // Check if this is a sorted import destructuring
    if (isImportDestructuring(let_expr)) {
        try formatSortedImportPattern(w, let_expr.pattern);
    } else {
        try formatPattern(w, let_expr.pattern);
    }
    // Decide if value goes on same line or indented next line
    const value_width = measureExpr(let_expr.value);
    const col = w.currentColumn() + 3; // " = " width
    const fits_on_line = if (value_width) |vw| (col + vw <= MAX_LINE_WIDTH) else false;

    if (fits_on_line) {
        try w.write(" = ");
        try formatExpr(w, let_expr.value, false);
    } else if (let_expr.value.data == .lambda or
        let_expr.value.data == .object or
        let_expr.value.data == .array or
        let_expr.value.data == .when_matches)
    {
        // These values have their own multi-line formatting with opening delimiter
        // on the same line: "= x -> ...", "= { ... }", "= [ ... ]", "= when ..."
        try w.write(" = ");
        try formatExpr(w, let_expr.value, false);
    } else {
        try w.write(" =");
        w.indent += 1;
        try w.newline();
        try formatExpr(w, let_expr.value, false);
        w.indent -= 1;
    }

    // Emit any inline comment on the value's line
    try w.emitInlineComment(let_expr.value.location.line);

    // Body — skip if body is same as value (EOF let binding)
    if (let_expr.body != let_expr.value) {
        if (let_expr.blank_line_before_body) {
            try w.newline();
        }
        try w.newline();
        try w.emitCommentsBefore(let_expr.body.location.line);
        try formatExpr(w, let_expr.body, false);
    }
}

fn isImportDestructuring(let_expr: ast.Let) bool {
    if (let_expr.pattern.data != .object) return false;
    return let_expr.value.data == .import_expr;
}

fn formatSortedImportPattern(w: *Writer, pat: *const ast.Pattern) FormatterError!void {
    const obj = pat.data.object;
    // Collect and sort field names
    const sorted = try w.allocator.alloc([]const u8, obj.fields.len);
    for (obj.fields, 0..) |field, i| sorted[i] = field.key;
    std.mem.sort([]const u8, sorted, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);
    try w.write("{ ");
    for (sorted, 0..) |key, i| {
        if (i > 0) try w.write(", ");
        try w.write(key);
    }
    try w.write(" }");
}

fn formatIf(w: *Writer, if_e: ast.If) FormatterError!void {
    // Measure single-line width
    const single_line = measureIfWidth(if_e);
    const col = w.currentColumn();
    const fits = if (single_line) |sw| (col + sw <= MAX_LINE_WIDTH) else false;

    if (fits or if_e.else_expr == null) {
        // Single-line format
        try w.write("if ");
        try formatExpr(w, if_e.condition, false);
        try w.write(" then ");
        try formatExpr(w, if_e.then_expr, false);
        if (if_e.else_expr) |else_expr| {
            try w.write(" else ");
            try formatExpr(w, else_expr, false);
        }
    } else {
        // Multi-line format
        try w.write("if ");
        try formatExpr(w, if_e.condition, false);
        try w.write(" then");
        w.indent += 1;
        try w.newline();
        try formatExpr(w, if_e.then_expr, false);
        w.indent -= 1;
        if (if_e.else_expr) |else_expr| {
            try w.newline();
            try w.write("else");
            w.indent += 1;
            try w.newline();
            try formatExpr(w, else_expr, false);
            w.indent -= 1;
        }
    }
}

fn measureIfWidth(if_e: ast.If) ?usize {
    const cw = measureExpr(if_e.condition) orelse return null;
    const tw = measureExpr(if_e.then_expr) orelse return null;
    var w: usize = 3 + cw + 6 + tw; // "if " + cond + " then " + then
    if (if_e.else_expr) |ee| {
        const ew = measureExpr(ee) orelse return null;
        w += 6 + ew; // " else " + else
    }
    return w;
}

fn formatApplication(w: *Writer, app: ast.Application) FormatterError!void {
    try formatExpr(w, app.function, false);

    if (app.is_do) {
        // `do` syntax: function do\n  body
        try w.write(" do");
        w.indent += 1;
        try w.newline();
        try formatExpr(w, app.argument, false);
        w.indent -= 1;
        return;
    }

    try w.writeByte(' ');
    // In a curried application chain (f a b), some argument types need parens:
    // - f a Module.field  → (f a Module).field without parens
    // - f a { x: 1 }     → object extension of (f a) without parens
    // - f a [1, 2]        → array indexing of (f a) without parens
    const in_chain = app.function.data == .application;
    const needs_parens = switch (app.argument.data) {
        .application, .binary, .lambda, .let, .if_expr, .when_matches, .where_expr, .assert_expr, .unary, .object_extend, .range => true,
        // field_access: dot binds tighter than application, so f Module.field is fine
        .object => in_chain, // f a { x: 1 } is object extension without parens
        else => false,
    };
    if (needs_parens) {
        try w.writeByte('(');
        try formatExpr(w, app.argument, false);
        try w.writeByte(')');
    } else {
        try formatExpr(w, app.argument, false);
    }
}

fn formatArray(w: *Writer, arr: ast.ArrayLiteral) FormatterError!void {
    if (arr.elements.len == 0) {
        try w.write("[]");
        return;
    }
    const single_line_width = measureArray(arr);
    const col = w.currentColumn();
    if (single_line_width) |width| {
        if (col + width <= MAX_LINE_WIDTH) {
            try w.writeByte('[');
            for (arr.elements, 0..) |elem, i| {
                if (i > 0) try w.write(", ");
                try formatArrayElement(w, elem);
            }
            try w.writeByte(']');
            return;
        }
    }
    // Multi-line
    try w.writeByte('[');
    w.indent += 1;
    for (arr.elements, 0..) |elem, i| {
        // Add blank line between multi-line array elements (like describe/it blocks)
        if (i > 0 and isMultiLineElement(elem)) {
            try w.newline();
        }
        try w.newline();
        const elem_line = switch (elem) {
            .normal => |e| e.location.line,
            .spread => |e| e.location.line,
            .conditional_if => |ce| ce.expr.location.line,
            .conditional_unless => |ce| ce.expr.location.line,
        };
        try w.emitCommentsBefore(elem_line);
        try formatArrayElement(w, elem);
    }
    w.indent -= 1;
    try w.newline();
    try w.writeByte(']');
}

fn isMultiLineElement(elem: ast.ArrayElement) bool {
    return switch (elem) {
        .normal => |e| measureExpr(e) == null,
        else => false,
    };
}

fn formatArrayElement(w: *Writer, elem: ast.ArrayElement) FormatterError!void {
    switch (elem) {
        .normal => |e| try formatExpr(w, e, false),
        .spread => |e| {
            try w.write("...");
            try formatExpr(w, e, false);
        },
        .conditional_if => |ce| {
            try formatExpr(w, ce.expr, false);
            try w.write(" if ");
            try formatExpr(w, ce.condition, false);
        },
        .conditional_unless => |ce| {
            try formatExpr(w, ce.expr, false);
            try w.write(" unless ");
            try formatExpr(w, ce.condition, false);
        },
    }
}

fn formatObject(w: *Writer, obj: ast.ObjectLiteral) FormatterError!void {
    if (obj.module_doc) |doc| {
        var doc_lines = std.mem.splitScalar(u8, doc, '\n');
        while (doc_lines.next()) |doc_line| {
            const trimmed_doc = std.mem.trimRight(u8, doc_line, " \t");
            if (trimmed_doc.len == 0) {
                try w.write("///");
            } else {
                try w.write("/// ");
                try w.write(trimmed_doc);
            }
            try w.newline();
        }
    }
    if (obj.fields.len == 0) {
        try w.write("{}");
        return;
    }
    const single_line_width = measureObject(obj);
    const col = w.currentColumn();
    if (single_line_width) |width| {
        if (col + width <= MAX_LINE_WIDTH) {
            try w.write("{ ");
            for (obj.fields, 0..) |field, i| {
                if (i > 0) try w.write(", ");
                try formatObjectField(w, field);
            }
            try w.write(" }");
            return;
        }
    }
    // Multi-line
    try w.writeByte('{');
    w.indent += 1;
    for (obj.fields, 0..) |field, i| {
        if (i > 0 and field.doc != null) try w.newline();
        try w.newline();
        // Emit any regular comments before this field
        const field_line = switch (field.key) {
            .static => field.key_location.?.line,
            .dynamic => |ke| ke.location.line,
        };
        try w.emitCommentsBefore(field_line);
        try formatObjectField(w, field);
    }
    w.indent -= 1;
    try w.newline();
    try w.writeByte('}');
}

fn formatObjectField(w: *Writer, field: ast.ObjectField) FormatterError!void {
    if (field.doc) |doc| {
        var doc_lines = std.mem.splitScalar(u8, doc, '\n');
        while (doc_lines.next()) |doc_line| {
            const trimmed_doc = std.mem.trimRight(u8, doc_line, " \t");
            if (trimmed_doc.len == 0) {
                try w.write("///");
            } else {
                try w.write("/// ");
                try w.write(trimmed_doc);
            }
            try w.newline();
        }
    }
    switch (field.key) {
        .static => |key| {
            if (needsQuoting(key)) {
                try w.writeByte('"');
                try writeEscapedString(w, key);
                try w.writeByte('"');
            } else {
                try w.write(key);
            }
            if (field.is_patch) {
                try w.writeByte(' ');
            } else if (field.is_hidden) {
                try w.write(":: ");
            } else {
                try w.write(": ");
            }
        },
        .dynamic => |key_expr| {
            // If the dynamic key is an array literal, format it directly without extra brackets
            if (key_expr.data == .array) {
                try formatExpr(w, key_expr, false);
            } else {
                try w.writeByte('[');
                try formatExpr(w, key_expr, false);
                try w.writeByte(']');
            }
            try w.write(": ");
        },
    }
    try formatExpr(w, field.value, false);
    switch (field.condition) {
        .none => {},
        .if_cond => |cond| {
            try w.write(" if ");
            try formatExpr(w, cond, false);
        },
        .unless_cond => |cond| {
            try w.write(" unless ");
            try formatExpr(w, cond, false);
        },
    }

    // Emit any inline comment on the field value's line
    try w.emitInlineComment(field.value.location.line);
}

// ============================================================================
// Pattern Formatting
// ============================================================================

fn formatPattern(w: *Writer, pat: *const ast.Pattern) FormatterError!void {
    switch (pat.data) {
        .identifier => |name| try w.write(name),
        .integer => |v| try w.write(try std.fmt.allocPrint(w.allocator, "{d}", .{v})),
        .float => |v| try w.write(try std.fmt.allocPrint(w.allocator, "{d}", .{v})),
        .boolean => |v| try w.write(if (v) "true" else "false"),
        .null_literal => try w.write("null"),
        .symbol => |s| try w.write(s),
        .string_literal => |s| {
            try w.writeByte('"');
            try writeEscapedString(w, s);
            try w.writeByte('"');
        },
        .tuple => |tup| {
            try w.writeByte('(');
            for (tup.elements, 0..) |elem, i| {
                if (i > 0) try w.write(", ");
                try formatPattern(w, elem);
            }
            try w.writeByte(')');
        },
        .array => |arr| {
            try w.writeByte('[');
            for (arr.elements, 0..) |elem, i| {
                if (i > 0) try w.write(", ");
                try formatPattern(w, elem);
            }
            if (arr.rest) |rest| {
                if (arr.elements.len > 0) try w.write(", ");
                try w.write("...");
                try w.write(rest);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.write("{ ");
            for (obj.fields, 0..) |field, i| {
                if (i > 0) try w.write(", ");
                try w.write(field.key);
                if (field.pattern.data != .identifier or
                    !std.mem.eql(u8, field.pattern.data.identifier, field.key))
                {
                    try w.write(": ");
                    try formatPattern(w, field.pattern);
                }
            }
            try w.write(" }");
        },
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn needsQuoting(key: []const u8) bool {
    if (key.len == 0) return true;
    for (key) |c| {
        if (c == ' ' or c == '"' or c == '\n' or c == '\t' or c == '\\' or c == ':' or c == '{' or c == '}' or c == '[' or c == ']') return true;
    }
    return false;
}

fn writeEscapedString(w: *Writer, s: []const u8) FormatterError!void {
    for (s) |c| {
        switch (c) {
            '"' => try w.write("\\\""),
            '\\' => try w.write("\\\\"),
            '\n' => try w.write("\\n"),
            '\t' => try w.write("\\t"),
            '\r' => try w.write("\\r"),
            else => try w.writeByte(c),
        }
    }
}

fn binaryOpStr(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .subtract => "-",
        .multiply => "*",
        .divide => "/",
        .logical_and => "&&",
        .logical_or => "||",
        .pipeline => "\\",
        .equal => "==",
        .not_equal => "!=",
        .less_than => "<",
        .greater_than => ">",
        .less_or_equal => "<=",
        .greater_or_equal => ">=",
        .merge => "&",
    };
}

fn needsParens(expr: *const ast.Expression, parent_op: ast.BinaryOp) bool {
    return switch (expr.data) {
        .binary => |inner| opPrecedence(inner.op) < opPrecedence(parent_op),
        // Lambdas in pipeline: parser now handles \ terminating lambda body, no parens needed
        else => false,
    };
}

fn opPrecedence(op: ast.BinaryOp) u8 {
    return switch (op) {
        .pipeline => 1,
        .logical_or => 2,
        .logical_and => 3,
        .equal, .not_equal => 4,
        .less_than, .greater_than, .less_or_equal, .greater_or_equal => 5,
        .merge => 6,
        .add, .subtract => 7,
        .multiply, .divide => 8,
    };
}
