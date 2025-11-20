const std = @import("std");
const evaluator = @import("eval.zig");

// Helper function to write common HTML header
fn writeHtmlHeader(file: anytype, title: []const u8) !void {
    try file.writeAll("<!DOCTYPE html>\n");
    try file.writeAll("<html lang=\"en\">\n");
    try file.writeAll("<head>\n");
    try file.writeAll("  <meta charset=\"UTF-8\">\n");
    try file.writeAll("  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    try file.writeAll("  <title>");
    try file.writeAll(title);
    try file.writeAll("</title>\n");
    try file.writeAll("  <style>\n");
}

// Helper function to write common CSS
fn writeCommonCss(file: anytype, sidebar_width: []const u8) !void {
    try file.writeAll(
        \\    * { margin: 0; padding: 0; box-sizing: border-box; }
        \\    body { font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, Roboto, sans-serif; line-height: 1.6; color: #333; background: #fafaf8; display: flex; }
        \\
    );

    // Sidebar styles with configurable width
    try file.writeAll("    .sidebar { width: ");
    try file.writeAll(sidebar_width);
    try file.writeAll(
        \\; background: #2c3e50; color: white; height: 100vh; position: fixed; top: 0; left: 0; display: flex; flex-direction: column; }
        \\    .sidebar-search { padding: 15px; border-bottom: 1px solid #34495e; flex-shrink: 0; }
        \\    .sidebar-search input { width: 100%; padding: 10px 12px; font-size: 14px; border: 1px solid #34495e; border-radius: 4px; background: #34495e; color: white; }
        \\    .sidebar-search input::placeholder { color: #95a5a6; }
        \\    .sidebar-search input:focus { outline: none; background: #3d5469; border-color: #3498db; }
        \\    .sidebar-content { overflow-y: auto; flex: 1; padding-bottom: 25vh; }
        \\    .sidebar-nav { list-style: none; border-bottom: 1px solid #34495e; }
        \\    .sidebar-nav li { border-bottom: none; }
        \\    .sidebar-nav .readme-link { font-weight: 500; font-size: 0.95em; }
        \\    .sidebar h2 { padding: 15px; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.5px; color: #95a5a6; border-bottom: 1px solid #34495e; }
        \\    .sidebar ul { list-style: none; }
        \\    .sidebar > ul > li { border-bottom: 1px solid #34495e; }
        \\    .sidebar a { display: block; padding: 12px 20px; color: #ecf0f1; text-decoration: none; transition: background 0.2s; }
        \\    .sidebar a:hover { background: #34495e; }
        \\    .sidebar a.active { background: #3498db; font-weight: 600; }
        \\    .main { margin-left:
    );
    try file.writeAll(sidebar_width);
    try file.writeAll(
        \\; flex: 1; }
        \\    .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        \\    header { padding: 30px 0 10px 0; margin-bottom: 10px; }
        \\    h1 { font-size: 2em; font-weight: 500; color: #333; }
        \\
    );
}

// Helper function to close HTML
fn writeHtmlFooter(file: anytype) !void {
    try file.writeAll("</body>\n");
    try file.writeAll("</html>\n");
}

// Helper function to write the sidebar HTML (used by both index and module pages)
fn writeSidebar(file: anytype, modules: []const ModuleInfo, current_module: ?[]const u8, current_module_items: ?[]const DocItem) !void {
    try file.writeAll("  <div class=\"sidebar\">\n");

    // Search box at the top
    try file.writeAll("    <div class=\"sidebar-search\">\n");
    try file.writeAll("      <input type=\"text\" id=\"sidebar-search\" placeholder=\"Search (Cmd+K)...\" />\n");
    try file.writeAll("    </div>\n");

    // Scrollable content wrapper
    try file.writeAll("    <div class=\"sidebar-content\">\n");

    // README link
    try file.writeAll("    <ul class=\"sidebar-nav\">\n");
    try file.writeAll("      <li><a href=\"index.html\" class=\"readme-link\">README</a></li>\n");
    try file.writeAll("    </ul>\n");

    // Modules section
    try file.writeAll("    <h2>Modules</h2>\n");
    try file.writeAll("    <ul>\n");

    // List all modules
    for (modules) |module| {
        const is_current = if (current_module) |curr| std.mem.eql(u8, module.name, curr) else false;

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

        // If this is the current module and we have items, show nested list
        if (is_current and current_module_items != null) {
            try file.writeAll("        <ul class=\"nested\">\n");
            for (current_module_items.?) |item| {
                try file.writeAll("          <li><a href=\"#");
                try file.writeAll(item.name);
                try file.writeAll("\" data-module=\"");
                try file.writeAll(module.name);
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
    try file.writeAll("    </div>\n"); // Close sidebar-content
    try file.writeAll("  </div>\n"); // Close sidebar
}

pub const DocItem = struct {
    name: []const u8,
    signature: []const u8, // Full signature like "min: a -> b ->"
    doc: []const u8,
    kind: DocKind,
};

pub const ModuleInfo = struct {
    name: []const u8,
    items: []const DocItem,
    module_doc: ?[]const u8, // Module-level documentation
};

pub const DocKind = enum {
    variable,
    field,
};

fn extractParamNames(pattern: *const evaluator.Pattern, names: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    switch (pattern.data) {
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
    while (current_expr.data == .lambda) {
        const lambda = current_expr.data.lambda;

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
    switch (expr.data) {
        .let => |let_expr| {
            if (let_expr.doc) |doc| {
                // Extract the name from the pattern
                const name = switch (let_expr.pattern.data) {
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
                // Only extract documentation from static keys
                const static_key = switch (field.key) {
                    .static => |k| k,
                    .dynamic => continue, // Skip dynamic keys for documentation
                };

                if (field.doc) |doc| {
                    const signature = try buildSignature(allocator, static_key, field.value);
                    try items.append(allocator, .{
                        .name = try allocator.dupe(u8, static_key),
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

pub fn syntaxHighlightCode(allocator: std.mem.Allocator, code: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    const keywords = [_][]const u8{ "let", "if", "then", "else", "when", "matches", "import", "true", "false", "null" };

    var i: usize = 0;
    while (i < code.len) {
        // Comments (// and #)
        if (code[i] == '#' or (code[i] == '/' and i + 1 < code.len and code[i + 1] == '/')) {
            try result.appendSlice(allocator, "<span style=\"color: #6a9955;\">");
            while (i < code.len and code[i] != '\n') {
                if (code[i] == '<') {
                    try result.appendSlice(allocator, "&lt;");
                } else if (code[i] == '>') {
                    try result.appendSlice(allocator, "&gt;");
                } else if (code[i] == '&') {
                    try result.appendSlice(allocator, "&amp;");
                } else {
                    try result.append(allocator, code[i]);
                }
                i += 1;
            }
            try result.appendSlice(allocator, "</span>");
            continue;
        }

        // Strings
        if (code[i] == '"' or code[i] == '\'') {
            const quote = code[i];
            try result.appendSlice(allocator, "<span style=\"color: #a31515;\">");
            try result.append(allocator, quote);
            i += 1;
            while (i < code.len and code[i] != quote) {
                if (code[i] == '\\' and i + 1 < code.len) {
                    try result.append(allocator, code[i]);
                    i += 1;
                    try result.append(allocator, code[i]);
                    i += 1;
                } else {
                    if (code[i] == '<') {
                        try result.appendSlice(allocator, "&lt;");
                    } else if (code[i] == '>') {
                        try result.appendSlice(allocator, "&gt;");
                    } else if (code[i] == '&') {
                        try result.appendSlice(allocator, "&amp;");
                    } else {
                        try result.append(allocator, code[i]);
                    }
                    i += 1;
                }
            }
            if (i < code.len) {
                try result.append(allocator, code[i]);
                i += 1;
            }
            try result.appendSlice(allocator, "</span>");
            continue;
        }

        // Numbers
        if (i < code.len and (code[i] >= '0' and code[i] <= '9')) {
            try result.appendSlice(allocator, "<span style=\"color: #098658;\">");
            while (i < code.len and ((code[i] >= '0' and code[i] <= '9') or code[i] == '.')) {
                try result.append(allocator, code[i]);
                i += 1;
            }
            try result.appendSlice(allocator, "</span>");
            continue;
        }

        // Identifiers and keywords
        if (i < code.len and ((code[i] >= 'a' and code[i] <= 'z') or (code[i] >= 'A' and code[i] <= 'Z') or code[i] == '_')) {
            const start = i;
            while (i < code.len and ((code[i] >= 'a' and code[i] <= 'z') or (code[i] >= 'A' and code[i] <= 'Z') or (code[i] >= '0' and code[i] <= '9') or code[i] == '_')) {
                i += 1;
            }
            const word = code[start..i];

            // Check if it's a keyword
            var is_keyword = false;
            for (keywords) |kw| {
                if (std.mem.eql(u8, word, kw)) {
                    is_keyword = true;
                    break;
                }
            }

            if (is_keyword) {
                try result.appendSlice(allocator, "<span style=\"color: #0000ff;\">");
                try result.appendSlice(allocator, word);
                try result.appendSlice(allocator, "</span>");
            } else {
                try result.appendSlice(allocator, word);
            }
            continue;
        }

        // Operators and symbols
        if (code[i] == '<') {
            try result.appendSlice(allocator, "&lt;");
        } else if (code[i] == '>') {
            try result.appendSlice(allocator, "&gt;");
        } else if (code[i] == '&') {
            try result.appendSlice(allocator, "&amp;");
        } else if (code[i] == '-' and i + 1 < code.len and code[i + 1] == '>') {
            try result.appendSlice(allocator, "<span style=\"color: #0000ff;\">-&gt;</span>");
            i += 2;
            continue;
        } else {
            try result.append(allocator, code[i]);
        }
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn renderInlineMarkdown(allocator: std.mem.Allocator, result: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        // Check for inline code (`)
        if (text[i] == '`') {
            const start_pos = i;
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
            // No closing marker found, reset and treat as regular character
            i = start_pos;
        }

        // Check for function references [functionname]
        if (text[i] == '[') {
            const start_pos = i;
            const start = i + 1;
            i += 1;
            while (i < text.len and text[i] != ']') : (i += 1) {}
            if (i < text.len) {
                const func_name = text[start..i];
                try result.appendSlice(allocator, "<a href=\"#");
                try result.appendSlice(allocator, func_name);
                try result.appendSlice(allocator, "\">");
                try result.appendSlice(allocator, func_name);
                try result.appendSlice(allocator, "</a>");
                i += 1;
                continue;
            }
            // No closing marker found, reset and treat as regular character
            i = start_pos;
        }

        // Check for bold (**)
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            const start_pos = i;
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
            // No closing marker found, reset and treat as regular character
            i = start_pos;
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

pub fn renderMarkdownToHtml(allocator: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var in_code_block = false;
    var code_block_start: usize = 0;
    var line_start: usize = 0;

    while (i < markdown.len) {
        // Check for code blocks (```)
        if (i + 2 < markdown.len and markdown[i] == '`' and markdown[i + 1] == '`' and markdown[i + 2] == '`') {
            if (in_code_block) {
                // End of code block - highlight and append
                const code = markdown[code_block_start..i];
                const highlighted = try syntaxHighlightCode(allocator, code);
                defer allocator.free(highlighted);

                try result.appendSlice(allocator, "<pre><code>");
                try result.appendSlice(allocator, highlighted);
                try result.appendSlice(allocator, "</code></pre>\n");
                in_code_block = false;
            } else {
                // Start of code block
                in_code_block = true;
            }
            i += 3;
            // Skip to end of line
            while (i < markdown.len and markdown[i] != '\n') : (i += 1) {}
            if (i < markdown.len) i += 1; // skip newline
            if (in_code_block) {
                code_block_start = i;
            }
            line_start = i;
            continue;
        }

        if (in_code_block) {
            i += 1;
            continue;
        }

        // Check for line breaks
        if (markdown[i] == '\n') {
            const line = markdown[line_start..i];
            const trimmed = std.mem.trimLeft(u8, line, " \t");

            // Check if it's a heading
            if (std.mem.startsWith(u8, trimmed, "#")) {
                var level: usize = 0;
                var j: usize = 0;
                while (j < trimmed.len and trimmed[j] == '#') : (j += 1) {
                    level += 1;
                }
                if (j < trimmed.len and trimmed[j] == ' ') {
                    const heading_text = std.mem.trim(u8, trimmed[j + 1 ..], " \t");
                    const tag = switch (level) {
                        1 => "h1",
                        2 => "h2",
                        3 => "h3",
                        4 => "h4",
                        5 => "h5",
                        else => "h6",
                    };
                    try result.appendSlice(allocator, "<");
                    try result.appendSlice(allocator, tag);
                    try result.appendSlice(allocator, " style=\"margin-top: 1.5em; margin-bottom: 0.5em;\">");
                    try renderInlineMarkdown(allocator, &result, heading_text);
                    try result.appendSlice(allocator, "</");
                    try result.appendSlice(allocator, tag);
                    try result.appendSlice(allocator, ">\n");
                    i += 1;
                    line_start = i;
                    continue;
                }
            }

            // Check if it's a list item
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try result.appendSlice(allocator, "<li>");
                try renderInlineMarkdown(allocator, &result, trimmed[2..]);
                try result.appendSlice(allocator, "</li>\n");
            } else if (line.len > 0) {
                try result.appendSlice(allocator, "<p>");
                try renderInlineMarkdown(allocator, &result, line);
                try result.appendSlice(allocator, "</p>\n");
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
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // Check if it's a heading
        if (std.mem.startsWith(u8, trimmed, "#")) {
            var level: usize = 0;
            var j: usize = 0;
            while (j < trimmed.len and trimmed[j] == '#') : (j += 1) {
                level += 1;
            }
            if (j < trimmed.len and trimmed[j] == ' ') {
                const heading_text = std.mem.trim(u8, trimmed[j + 1 ..], " \t");
                const tag = switch (level) {
                    1 => "h1",
                    2 => "h2",
                    3 => "h3",
                    4 => "h4",
                    5 => "h5",
                    else => "h6",
                };
                try result.appendSlice(allocator, "<");
                try result.appendSlice(allocator, tag);
                try result.appendSlice(allocator, " style=\"margin-top: 1.5em; margin-bottom: 0.5em;\">");
                try renderInlineMarkdown(allocator, &result, heading_text);
                try result.appendSlice(allocator, "</");
                try result.appendSlice(allocator, tag);
                try result.appendSlice(allocator, ">");
            }
        } else if (std.mem.startsWith(u8, trimmed, "- ")) {
            try result.appendSlice(allocator, "<li>");
            try renderInlineMarkdown(allocator, &result, trimmed[2..]);
            try result.appendSlice(allocator, "</li>");
        } else if (line.len > 0) {
            try result.appendSlice(allocator, "<p>");
            try renderInlineMarkdown(allocator, &result, line);
            try result.appendSlice(allocator, "</p>");
        }
    }

    return result.toOwnedSlice(allocator);
}

pub fn writeIndexHtmlContent(allocator: std.mem.Allocator, file: anytype, modules: []const ModuleInfo, readme_content: ?[]const u8) !void {
    try writeHtmlHeader(file, "Documentation");
    try writeCommonCss(file, "250px");

    // Index-specific CSS
    try file.writeAll(
        \\    .module-list { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; }
        \\    .module-card { padding: 15px 0; border-bottom: 1px solid #e0e0e0; }
        \\    .module-card h2 { color: #333; margin-bottom: 10px; font-size: 1.2em; font-weight: 500; }
        \\    .module-card h2 a { color: #333; text-decoration: none; }
        \\    .module-card h2 a:hover { color: #3498db; }
        \\    .module-card .item-count { color: #7f8c8d; font-size: 0.9em; margin-top: 5px; }
        \\    @media (max-width: 768px) { .sidebar { display: none; } .main { margin-left: 0; } .container { padding: 10px; } .module-list { grid-template-columns: 1fr; } }
        \\
    );
    try file.writeAll("  </style>\n");
    try file.writeAll("</head>\n");
    try file.writeAll("<body>\n");

    // Sidebar (shared between index and module pages)
    try writeSidebar(file, modules, null, null);

    // Main content
    try file.writeAll("  <div class=\"main\">\n");
    try file.writeAll("    <header>\n");
    try file.writeAll("      <div class=\"container\">\n");
    try file.writeAll("        <h1>Documentation</h1>\n");
    try file.writeAll("      </div>\n");
    try file.writeAll("    </header>\n");
    try file.writeAll("    <div class=\"container\">\n");

    // Render README content if available
    if (readme_content) |readme| {
        try file.writeAll("      <div class=\"readme-content\" style=\"line-height: 1.8; color: #333;\">\n");
        try file.writeAll("      <style>\n");
        try file.writeAll("        .readme-content h1 { font-size: 2em; color: #333; margin-top: 0 !important; margin-bottom: 0.5em; font-weight: 500; }\n");
        try file.writeAll("        .readme-content h2 { font-size: 1.8em; color: #333; margin-top: 1.5em; margin-bottom: 0.5em; font-weight: 400; }\n");
        try file.writeAll("        .readme-content h3 { font-size: 1.4em; color: #333; margin-top: 1.2em; margin-bottom: 0.4em; }\n");
        try file.writeAll("        .readme-content p { margin-bottom: 1em; color: #555; }\n");
        try file.writeAll("        .readme-content li { margin-left: 1.5em; margin-bottom: 0.5em; color: #555; }\n");
        try file.writeAll("        .readme-content code { background: #f4f4f4; padding: 2px 6px; border-radius: 3px; font-family: 'SF Mono', 'Monaco', 'Menlo', 'Consolas', 'Courier New', monospace; font-size: 0.9em; color: #c7254e; }\n");
        try file.writeAll("        .readme-content pre { background: #f9f9f9; border: 1px solid #e0e0e0; border-radius: 4px; padding: 16px; overflow-x: auto; margin: 1em 0; }\n");
        try file.writeAll("        .readme-content pre code { background: none; padding: 0; color: #333; font-size: 0.95em; }\n");
        try file.writeAll("      </style>\n");

        const html_content = try renderMarkdownToHtml(allocator, readme);
        defer allocator.free(html_content);

        try file.writeAll(html_content);
        try file.writeAll("      </div>\n");
    } else {
        // Fallback to module list if no README
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
    }
    try file.writeAll("    </div>\n");
    try file.writeAll("  </div>\n");

    // Add search functionality
    try file.writeAll("  <script>\n");
    try file.writeAll(
        \\    const searchInput = document.getElementById('sidebar-search');
        \\    const modulesList = document.querySelector('.sidebar ul');
        \\    const modules = Array.from(modulesList.querySelectorAll('li'));
        \\
        \\    searchInput.addEventListener('input', (e) => {
        \\      const query = e.target.value.toLowerCase();
        \\      modules.forEach(module => {
        \\        const text = module.textContent.toLowerCase();
        \\        module.style.display = text.includes(query) ? '' : 'none';
        \\      });
        \\    });
        \\
    );
    try file.writeAll("  </script>\n");
    try writeHtmlFooter(file);
}

pub fn writeHtmlDocs(file: anytype, module_name: []const u8, items: []const DocItem, modules: []const ModuleInfo, module_doc: ?[]const u8, allocator: std.mem.Allocator) !void {
    // Write title with module name
    try file.writeAll("<!DOCTYPE html>\n");
    try file.writeAll("<html lang=\"en\">\n");
    try file.writeAll("<head>\n");
    try file.writeAll("  <meta charset=\"UTF-8\">\n");
    try file.writeAll("  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    try file.writeAll("  <title>");
    try file.writeAll(module_name);
    try file.writeAll(" - Documentation</title>\n");
    try file.writeAll("  <style>\n");

    try writeCommonCss(file, "280px");

    // Module-specific CSS
    try file.writeAll(
        \\    .sidebar .module-link { font-weight: 500; }
        \\    .sidebar .nested { list-style: none; }
        \\    .sidebar .nested li { border-bottom: none; }
        \\    .sidebar .nested a { padding: 8px 20px 8px 35px; font-size: 0.9em; color: #bdc3c7; }
        \\    .sidebar .nested a:hover { background: #3d5469; color: #ecf0f1; }
        \\    .sidebar .nested a.active { background: #2c3e50; color: #3498db; border-left: 3px solid #3498db; padding-left: 32px; }
        \\    .doc-item { margin-bottom: 30px; padding-bottom: 20px; border-bottom: 1px solid #e0e0e0; }
        \\    .doc-item:last-child { border-bottom: none; }
        \\    .doc-item h2 { color: #333; margin-bottom: 10px; font-size: 1.2em; font-weight: 500; }
        \\    .doc-item .kind { display: inline-block; padding: 4px 10px; background: #3498db; color: white; border-radius: 4px; font-size: 0.85em; margin-bottom: 10px; }
        \\    .doc-item .doc-content { color: #555; line-height: 1.8; margin-left: 20px; }
        \\    .doc-item .doc-content code { background: #f4f4f4; padding: 2px 6px; border-radius: 3px; font-family: 'SF Mono', 'Monaco', 'Menlo', 'Consolas', 'Courier New', monospace; font-size: 0.9em; }
        \\    .doc-item .doc-content pre { background: #f9f9f9; padding: 12px; border: 1px solid #e0e0e0; border-radius: 4px; overflow-x: auto; margin: 10px 0; }
        \\    .doc-item .doc-content pre code { background: none; padding: 0; }
        \\    .doc-item .doc-content strong { font-weight: 600; color: #333; }
        \\    .doc-item .doc-content li { margin-left: 20px; margin-bottom: 5px; }
        \\    .doc-item.module-doc { border-bottom: 2px solid #e0e0e0; margin-bottom: 40px; padding-bottom: 30px; }
        \\    .doc-item.module-doc .doc-content { margin-left: 0; }
        \\    .no-results { text-align: center; padding: 40px; color: #999; }
        \\    .search-result-label { font-size: 0.85em; color: #7f8c8d; margin-left: 5px; }
        \\    @media (max-width: 768px) { .sidebar { display: none; } .main { margin-left: 0; } .container { padding: 10px; } }
        \\
    );
    try file.writeAll("  </style>\n");
    try file.writeAll("</head>\n");
    try file.writeAll("<body>\n");

    // Sidebar (shared between index and module pages)
    try writeSidebar(file, modules, module_name, items);

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

    // Render module-level documentation if available
    if (module_doc) |doc| {
        const html = try renderMarkdownToHtml(allocator, doc);
        defer allocator.free(html);

        try file.writeAll("      <div class=\"doc-item module-doc\">\n");
        try file.writeAll("        <div class=\"doc-content\">\n");
        try file.writeAll("          ");
        try file.writeAll(html);
        try file.writeAll("\n");
        try file.writeAll("        </div>\n");
        try file.writeAll("      </div>\n");
    }

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
        \\    // Highlight current section in sidebar on scroll
        \\    const docItems = Array.from(document.querySelectorAll('.doc-item'));
        \\    const sidebarLinks = Array.from(document.querySelectorAll('.sidebar .nested a'));
        \\
        \\    function updateActiveLink() {
        \\      // Find the doc item that's currently most visible
        \\      let currentItem = null;
        \\      const scrollPos = window.scrollY + 100; // Offset for header
        \\
        \\      for (let i = docItems.length - 1; i >= 0; i--) {
        \\        const item = docItems[i];
        \\        if (item.offsetTop <= scrollPos) {
        \\          currentItem = item;
        \\          break;
        \\        }
        \\      }
        \\
        \\      // Remove active class from all links
        \\      sidebarLinks.forEach(link => link.classList.remove('active'));
        \\
        \\      // Add active class to current link
        \\      if (currentItem) {
        \\        const itemName = currentItem.getAttribute('data-name');
        \\        const activeLink = sidebarLinks.find(link =>
        \\          link.getAttribute('data-item') === itemName
        \\        );
        \\        if (activeLink) {
        \\          activeLink.classList.add('active');
        \\        }
        \\      }
        \\    }
        \\
        \\    // Update on scroll and load
        \\    window.addEventListener('scroll', updateActiveLink);
        \\    window.addEventListener('load', updateActiveLink);
        \\    updateActiveLink();
        \\
    );
    try file.writeAll("  </script>\n");
    try writeHtmlFooter(file);
}

pub fn generateModuleHtml(
    allocator: std.mem.Allocator,
    module: ModuleInfo,
    all_modules: []const ModuleInfo,
    output_dir: []const u8,
) !void {
    const html_filename = try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ output_dir, module.name });
    defer allocator.free(html_filename);

    var html_file = try std.fs.cwd().createFile(html_filename, .{});
    defer html_file.close();

    try writeHtmlDocs(html_file, module.name, module.items, all_modules, module.module_doc, allocator);
}

pub fn generateIndexHtml(
    allocator: std.mem.Allocator,
    modules: []const ModuleInfo,
    output_dir: []const u8,
) !void {
    const html_filename = try std.fmt.allocPrint(allocator, "{s}/index.html", .{output_dir});
    defer allocator.free(html_filename);

    var html_file = try std.fs.cwd().createFile(html_filename, .{});
    defer html_file.close();

    // Try to read README.md from current directory
    const readme_content = std.fs.cwd().readFileAlloc(allocator, "README.md", 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (readme_content) |content| allocator.free(content);

    try writeIndexHtmlContent(allocator, html_file, modules, readme_content);
}

pub fn collectModulesFromDirectory(
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

pub fn extractModuleInfo(
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

    // Extract module-level documentation if available
    const module_doc: ?[]const u8 = switch (expression.data) {
        .object => |obj| if (obj.module_doc) |doc| try allocator.dupe(u8, doc) else null,
        else => null,
    };

    const module_name = try allocator.dupe(u8, std.fs.path.stem(input_path));

    return ModuleInfo{
        .name = module_name,
        .items = try doc_items.toOwnedSlice(allocator),
        .module_doc = module_doc,
    };
}
