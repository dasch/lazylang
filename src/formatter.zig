const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const tokenizer_mod = @import("tokenizer.zig");
const error_context = @import("error_context.zig");

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
    line: usize, // 1-indexed source line
    is_doc: bool, // true for /// comments
    blank_line_before: bool,
};

const Writer = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indent: usize,
    at_line_start: bool,
    source: []const u8,
    comments: []const Comment,
    next_comment: usize,

    fn init(allocator: std.mem.Allocator, source: []const u8, comments: []const Comment) Writer {
        return .{
            .buf = std.ArrayList(u8){},
            .allocator = allocator,
            .indent = 0,
            .at_line_start = true,
            .source = source,
            .comments = comments,
            .next_comment = 0,
        };
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

    fn writeIndent(self: *Writer) !void {
        for (0..self.indent) |_| {
            try self.buf.appendSlice(self.allocator, "  ");
        }
    }

    /// Emit any comments that appear before the given source line
    fn emitCommentsBefore(self: *Writer, before_line: usize) !void {
        while (self.next_comment < self.comments.len) {
            const comment = self.comments[self.next_comment];
            if (comment.line >= before_line) break;
            if (comment.is_doc) {
                self.next_comment += 1;
                continue; // Doc comments are handled by AST nodes
            }
            if (comment.blank_line_before and self.buf.items.len > 0) {
                // Ensure blank line before this comment
                if (!endsWith2Newlines(self.buf.items)) {
                    try self.newline();
                }
            }
            try self.write(comment.text);
            try self.newline();
            self.next_comment += 1;
        }
    }

    /// Emit remaining comments at end of file
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

fn endsWith2Newlines(s: []const u8) bool {
    return s.len >= 2 and s[s.len - 1] == '\n' and s[s.len - 2] == '\n';
}

/// Extract comments from source text
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
            try comments.append(allocator, .{
                .text = trimmed,
                .line = line_num,
                .is_doc = true,
                .blank_line_before = prev_was_blank,
            });
            prev_was_blank = false;
        } else if (std.mem.startsWith(u8, trimmed, "//")) {
            try comments.append(allocator, .{
                .text = trimmed,
                .line = line_num,
                .is_doc = false,
                .blank_line_before = prev_was_blank,
            });
            prev_was_blank = false;
        } else {
            prev_was_blank = false;
        }
        line_num += 1;
    }

    return comments.toOwnedSlice(allocator);
}

/// Format a Lazylang source string
pub fn formatSource(allocator: std.mem.Allocator, source: []const u8) FormatterError!FormatterOutput {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Parse the source to AST
    var err_ctx = error_context.ErrorContext.init(allocator);
    defer err_ctx.deinit();

    var parser = parser_mod.Parser.initWithContext(arena.allocator(), source, &err_ctx) catch {
        return FormatterError.ParseError;
    };
    const expression = parser.parse() catch {
        return FormatterError.ParseError;
    };

    // Extract comments from source
    const comments = try extractComments(allocator, source);
    defer allocator.free(comments);

    // Pretty-print from AST
    var w = Writer.init(allocator, source, comments);

    try formatExpr(&w, expression, false);

    // Emit any trailing comments
    try w.emitRemainingComments();

    // Ensure trailing newline
    if (w.buf.items.len > 0 and w.buf.items[w.buf.items.len - 1] != '\n') {
        try w.newline();
    }

    return FormatterOutput{
        .text = try w.toOwnedSlice(),
        .allocator = allocator,
    };
}

/// Format a file (read, format, return)
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
    try w.emitCommentsBefore(expr.location.line);

    switch (expr.data) {
        .integer => |v| {
            const s = try std.fmt.allocPrint(w.allocator, "{d}", .{v});
            try w.write(s);
        },
        .float => |v| {
            const s = try std.fmt.allocPrint(w.allocator, "{d}", .{v});
            // Strip trailing zeros after decimal
            if (std.mem.indexOf(u8, s, ".")) |dot| {
                var end = s.len;
                while (end > dot + 1 and s[end - 1] == '0') end -= 1;
                if (end == dot + 1) end = dot + 2;
                try w.write(s[0..end]);
            } else {
                try w.write(s);
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
                    .interpolation => |interp_expr| {
                        // Check if it's a simple identifier
                        if (interp_expr.data == .identifier) {
                            try w.writeByte('$');
                            try w.write(interp_expr.data.identifier);
                        } else {
                            try w.write("${");
                            try formatExpr(w, interp_expr, false);
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
            try w.write(" -> ");
            try formatExpr(w, lam.body, false);
        },
        .let => |let_expr| {
            try formatLet(w, let_expr, expr.location.line);
        },
        .where_expr => |where| {
            try formatExpr(w, where.expr, false);
            try w.write(" where");
            if (where.bindings.len == 1) {
                try w.writeByte(' ');
                try formatPattern(w, where.bindings[0].pattern);
                try w.write(" = ");
                try formatExpr(w, where.bindings[0].value, false);
            } else {
                w.indent += 1;
                for (where.bindings) |binding| {
                    try w.newline();
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
            try formatExpr(w, bin.left, needsParens(bin.left, .left, bin.op));
            try w.writeByte(' ');
            try w.write(binaryOpStr(bin.op));
            try w.writeByte(' ');
            try formatExpr(w, bin.right, needsParens(bin.right, .right, bin.op));
            if (parens_needed) try w.writeByte(')');
        },
        .application => |app| {
            try formatApplication(w, app);
        },
        .if_expr => |if_e| {
            try formatIf(w, if_e);
        },
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
        .array => |arr| {
            try formatArray(w, arr, expr.location.line);
        },
        .tuple => |tup| {
            try w.writeByte('(');
            for (tup.elements, 0..) |elem, i| {
                if (i > 0) try w.write(", ");
                try formatExpr(w, elem, false);
            }
            if (tup.elements.len == 1) try w.writeByte(',');
            try w.writeByte(')');
        },
        .object => |obj| {
            try formatObject(w, obj);
        },
        .object_extend => |ext| {
            try formatExpr(w, ext.base, false);
            try w.write(" { ");
            for (ext.fields, 0..) |field, i| {
                if (i > 0) try w.write(", ");
                try formatObjectField(w, field, true);
            }
            try w.write(" }");
        },
        .import_expr => |imp| {
            try w.write("import ");
            try w.writeByte('"');
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
        .assert_expr => |assert_e| {
            try w.write("assert ");
            try formatExpr(w, assert_e.condition, false);
            try w.write(" : ");
            try formatExpr(w, assert_e.message, false);
            try w.newline();
            try formatExpr(w, assert_e.body, false);
        },
    }
}

fn formatLet(w: *Writer, let_expr: ast.Let, start_line: usize) FormatterError!void {
    // Emit doc comment if present
    if (let_expr.doc) |doc| {
        var doc_lines = std.mem.splitScalar(u8, doc, '\n');
        while (doc_lines.next()) |doc_line| {
            try w.write("/// ");
            try w.write(std.mem.trimRight(u8, doc_line, " \t"));
            try w.newline();
        }
    }

    _ = start_line;
    try formatPattern(w, let_expr.pattern);
    try w.write(" = ");

    // Check if the value is a multi-line construct that needs indentation
    const value_needs_indent = switch (let_expr.value.data) {
        .let => true,
        .if_expr => |ie| ie.else_expr != null,
        .when_matches => true,
        else => false,
    };

    if (value_needs_indent) {
        w.indent += 1;
        try w.newline();
        try formatExpr(w, let_expr.value, false);
        w.indent -= 1;
    } else {
        try formatExpr(w, let_expr.value, false);
    }

    // Body — skip if body is same as value (EOF let binding)
    if (let_expr.body != let_expr.value) {
        try w.newline();
        try formatExpr(w, let_expr.body, false);
    }
}

fn formatIf(w: *Writer, if_e: ast.If) FormatterError!void {
    try w.write("if ");
    try formatExpr(w, if_e.condition, false);
    try w.write(" then ");
    try formatExpr(w, if_e.then_expr, false);
    if (if_e.else_expr) |else_expr| {
        try w.write(" else ");
        try formatExpr(w, else_expr, false);
    }
}

fn formatApplication(w: *Writer, app: ast.Application) FormatterError!void {
    // Flatten left-associative application chain: f a b c
    try formatExpr(w, app.function, false);
    try w.writeByte(' ');

    // Check if argument needs parens (is it a complex expression?)
    const needs_parens = switch (app.argument.data) {
        .application, .binary, .lambda, .let, .if_expr, .when_matches, .where_expr, .assert_expr => true,
        .unary => true,
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

fn formatArray(w: *Writer, arr: ast.ArrayLiteral, _: usize) FormatterError!void {
    if (arr.elements.len == 0) {
        try w.write("[]");
        return;
    }

    // Check if all elements are simple and short enough for single line
    const single_line = shouldArrayBeSingleLine(arr);

    if (single_line) {
        try w.writeByte('[');
        for (arr.elements, 0..) |elem, i| {
            if (i > 0) try w.write(", ");
            try formatArrayElement(w, elem);
        }
        try w.writeByte(']');
    } else {
        try w.writeByte('[');
        w.indent += 1;
        for (arr.elements) |elem| {
            try w.newline();
            try formatArrayElement(w, elem);
        }
        w.indent -= 1;
        try w.newline();
        try w.writeByte(']');
    }
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

fn shouldArrayBeSingleLine(arr: ast.ArrayLiteral) bool {
    if (arr.elements.len > 5) return false;
    for (arr.elements) |elem| {
        switch (elem) {
            .normal => |e| {
                if (!isSimpleExpr(e)) return false;
            },
            .spread => return false,
            .conditional_if, .conditional_unless => return false,
        }
    }
    return true;
}

fn formatObject(w: *Writer, obj: ast.ObjectLiteral) FormatterError!void {
    if (obj.fields.len == 0) {
        try w.write("{}");
        return;
    }

    // Single-line for simple objects with few fields
    const single_line = shouldObjectBeSingleLine(obj);

    if (single_line) {
        try w.write("{ ");
        for (obj.fields, 0..) |field, i| {
            if (i > 0) try w.write(", ");
            try formatObjectField(w, field, true);
        }
        try w.write(" }");
    } else {
        try w.writeByte('{');
        w.indent += 1;
        for (obj.fields, 0..) |field, i| {
            // Blank line between fields that have doc comments (except first)
            if (i > 0 and field.doc != null) {
                try w.newline();
            }
            try w.newline();
            try formatObjectField(w, field, false);
        }
        w.indent -= 1;
        try w.newline();
        try w.writeByte('}');
    }
}

fn formatObjectField(w: *Writer, field: ast.ObjectField, _: bool) FormatterError!void {
    // Doc comment
    if (field.doc) |doc| {
        var doc_lines = std.mem.splitScalar(u8, doc, '\n');
        while (doc_lines.next()) |doc_line| {
            try w.write("/// ");
            try w.write(std.mem.trimRight(u8, doc_line, " \t"));
            try w.newline();
        }
    }

    switch (field.key) {
        .static => |key| {
            try w.write(key);
            if (field.is_patch) {
                try w.writeByte(' ');
            } else {
                try w.write(": ");
            }
        },
        .dynamic => |key_expr| {
            try w.writeByte('[');
            try formatExpr(w, key_expr, false);
            try w.write("]: ");
        },
    }
    try formatExpr(w, field.value, false);

    // Conditional
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
}

fn shouldObjectBeSingleLine(obj: ast.ObjectLiteral) bool {
    if (obj.fields.len > 2) return false;
    if (obj.module_doc != null) return false;
    for (obj.fields) |field| {
        if (field.doc != null) return false;
        if (field.is_patch) return false;
        if (field.condition != .none) return false;
        switch (field.key) {
            .dynamic => return false,
            .static => {},
        }
        if (!isSimpleExpr(field.value)) return false;
    }
    return true;
}

fn isSimpleExpr(expr: *const ast.Expression) bool {
    return switch (expr.data) {
        .integer, .float, .boolean, .null_literal, .string_literal, .symbol, .identifier => true,
        .field_access => true,
        .field_accessor => true,
        .unary => |u| isSimpleExpr(u.operand),
        .binary => |b| isSimpleExpr(b.left) and isSimpleExpr(b.right),
        .application => |a| isSimpleExpr(a.function) and isSimpleExpr(a.argument),
        .object => |o| shouldObjectBeSingleLine(o),
        .array => |a| shouldArrayBeSingleLine(a),
        .tuple => |t| blk: {
            for (t.elements) |e| {
                if (!isSimpleExpr(e)) break :blk false;
            }
            break :blk t.elements.len <= 5;
        },
        else => false,
    };
}

// ============================================================================
// Pattern Formatting
// ============================================================================

fn formatPattern(w: *Writer, pat: *const ast.Pattern) FormatterError!void {
    switch (pat.data) {
        .identifier => |name| try w.write(name),
        .integer => |v| {
            const s = try std.fmt.allocPrint(w.allocator, "{d}", .{v});
            try w.write(s);
        },
        .float => |v| {
            const s = try std.fmt.allocPrint(w.allocator, "{d}", .{v});
            try w.write(s);
        },
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
                // Check if pattern is different from key (literal value match)
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

const Side = enum { left, right };

fn needsParens(expr: *const ast.Expression, side: Side, parent_op: ast.BinaryOp) bool {
    _ = side;
    return switch (expr.data) {
        .binary => |inner| opPrecedence(inner.op) < opPrecedence(parent_op),
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
