const std = @import("std");
const evaluator = @import("eval.zig");

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

const BraceType = enum {
    brace,
    bracket,
    paren,
};

const BraceInfo = struct {
    brace_type: BraceType,
    is_single_line: bool,
    skipped: bool = false, // True if this paren pair should be skipped in output
    context_do_indent: usize = 0, // The do_indent_level when this brace was opened
};

const TokenInfo = struct {
    token: evaluator.Token,
    source_start: usize,
    source_end: usize,
};

/// Count newlines in a slice
fn countNewlines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

/// Format a Lazylang source string
pub fn formatSource(allocator: std.mem.Allocator, source: []const u8) FormatterError!FormatterOutput {
    // Create an arena for tokenizer allocations (doc comments, etc.)
    var tokenizer_arena = std.heap.ArenaAllocator.init(allocator);
    defer tokenizer_arena.deinit();

    // First pass: collect all tokens with their source positions
    var tokens = std.ArrayList(TokenInfo){};
    defer tokens.deinit(allocator);

    var tokenizer = evaluator.Tokenizer.init(source, tokenizer_arena.allocator());
    defer tokenizer.deinit();

    while (true) {
        const token = tokenizer.next() catch {
            return FormatterError.ParseError;
        };
        if (token.kind == .eof) break;

        // Use token's offset for accurate source position tracking
        const tok_start = token.offset;
        var tok_end = tok_start + token.lexeme.len;
        if (token.kind == .string) {
            tok_end += 2; // Account for quotes
        }

        try tokens.append(allocator, .{
            .token = token,
            .source_start = tok_start,
            .source_end = tok_end,
        });
    }

    // Determine which braces/brackets are single-line
    var brace_is_single_line = std.AutoHashMap(usize, bool).init(allocator);
    defer brace_is_single_line.deinit();

    // Extract just tokens for analysis
    var token_list = std.ArrayList(evaluator.Token){};
    defer token_list.deinit(allocator);
    for (tokens.items) |info| {
        try token_list.append(allocator, info.token);
    }
    try analyzeBraces(token_list.items, &brace_is_single_line);

    // Second pass: format based on analysis
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    var indent_level: usize = 0;
    var prev_indent_level: usize = 0;
    var prev_token: ?evaluator.TokenKind = null;
    var at_line_start = true;
    var brace_stack = std.ArrayList(BraceInfo){};
    var just_closed_multiline_collection = false; // Track if we just closed a multi-line brace/bracket
    var skip_next_paren_pair = false; // Track if we should skip parens after = or :
    defer brace_stack.deinit(allocator);
    var do_indent_level: usize = 0; // Track additional indent from `do`
    var just_saw_equals_or_colon = false; // Track if we just saw = or : for continuation indent

    for (tokens.items, 0..) |info, i| {
        const token = info.token;
        // For single-line objects/brackets, handle special spacing before popping stack
        if (token.kind == .r_brace and brace_stack.items.len > 0) {
            const brace_info = brace_stack.items[brace_stack.items.len - 1];
            if (brace_info.brace_type == .brace and brace_info.is_single_line) {
                // Skip if we already wrote this brace (empty object case)
                if (brace_info.skipped) {
                    _ = brace_stack.pop();
                    prev_token = token.kind;
                    continue;
                }
                try output.appendSlice(allocator, " }");
                _ = brace_stack.pop();
                prev_token = token.kind;
                continue;
            }
        }

        // Handle closing brace/bracket/paren indentation - decrease before writing
        if (token.kind == .r_brace or token.kind == .r_bracket or token.kind == .r_paren) {
            if (brace_stack.items.len > 0) {
                const brace_info = brace_stack.items[brace_stack.items.len - 1];

                // Skip closing paren if we skipped the opening (unnecessary parens around let-bindings)
                if (token.kind == .r_paren and brace_info.brace_type == .paren and brace_info.skipped) {
                    _ = brace_stack.pop();
                    prev_token = token.kind;
                    skip_next_paren_pair = false;
                    // Restore do_indent_level to the context when this paren was opened
                    do_indent_level = brace_info.context_do_indent;
                    continue;
                }

                // For multi-line brackets/braces in comprehensions, ensure closing bracket/brace is on new line
                if ((brace_info.brace_type == .bracket or brace_info.brace_type == .brace) and !brace_info.is_single_line and !token.preceded_by_newline) {
                    // Check if we recently saw a 'for' keyword (likely a comprehension)
                    if (i > 0 and prev_token == .identifier) {
                        try output.appendSlice(allocator, "\n");
                        at_line_start = true;
                    }
                }

                _ = brace_stack.pop();
                if (!brace_info.is_single_line and indent_level > 0) {
                    indent_level -= 1;
                    // Update prev_indent_level so dedenting logic can run on closing brace line
                    prev_indent_level = indent_level;
                }
                // Restore do_indent_level to the context when this brace was opened
                do_indent_level = brace_info.context_do_indent;
                // Track if we just closed a multi-line brace/bracket
                just_closed_multiline_collection = !brace_info.is_single_line and
                    (brace_info.brace_type == .brace or brace_info.brace_type == .bracket);
            }
        }

        // Special handling for 'for' keyword in multi-line comprehensions
        // If we're in a multi-line bracket/brace and see 'for', it should be on its own line
        // Check only the INNERMOST bracket/brace, not outer ones
        if (token.kind == .identifier and std.mem.eql(u8, token.lexeme, "for")) {
            var in_multiline_comprehension = false;
            if (brace_stack.items.len > 0) {
                const innermost = brace_stack.items[brace_stack.items.len - 1];
                if ((innermost.brace_type == .bracket or innermost.brace_type == .brace) and !innermost.is_single_line) {
                    in_multiline_comprehension = true;
                }
            }

            if (in_multiline_comprehension and !token.preceded_by_newline) {
                // Add a newline before 'for' in multi-line comprehensions
                try output.appendSlice(allocator, "\n");
                at_line_start = true;
            }
        }

        // Skip unnecessary parens around let-bindings after = or : EARLY (before spacing)
        // Pattern: identifier = ( let-bindings ) should become: identifier =\n  let-bindings
        // Keep parens only if the content inside has no indentation (poorly formatted, parens are structural)
        // Trailing semicolons are stripped by the semicolon-stripping logic elsewhere
        if (token.kind == .l_paren) {
            const is_multi = !(brace_is_single_line.get(i) orelse true);
            if (is_multi and prev_token != null and (prev_token.? == .equals or prev_token.? == .colon)) {
                // Check if content is properly indented
                var has_proper_indentation = false;
                var depth: i32 = 1;
                var j = i + 1;
                while (j < tokens.items.len) : (j += 1) {
                    const t = tokens.items[j].token;
                    if (t.kind == .l_paren) {
                        depth += 1;
                    } else if (t.kind == .r_paren) {
                        depth -= 1;
                        if (depth == 0) {
                            break;
                        }
                    }
                    // Check if first content token inside parens is indented
                    if (depth == 1 and !has_proper_indentation and t.preceded_by_newline) {
                        // First token after opening paren on new line - check if it has any indentation
                        // If column > 1, it's indented (well-formatted)
                        if (t.column > 1) {
                            has_proper_indentation = true;
                        }
                    }
                }

                if (has_proper_indentation) {
                    // Skip this opening paren and mark it for skipping the close
                    // Increment do_indent_level to maintain indentation that would have come from the paren
                    // Keep prev_token as-is (don't set to .l_paren) so spacing works correctly
                    skip_next_paren_pair = true;
                    const context = do_indent_level;
                    do_indent_level += 1;
                    try brace_stack.append(allocator, BraceInfo{ .brace_type = .paren, .is_single_line = false, .skipped = true, .context_do_indent = context });
                    continue;
                }
            }
        }

        // Handle newlines
        if (token.preceded_by_newline) {
            // Special handling for `then` keyword - move it to same line as condition
            // `else` stays on its own line
            var suppress_newline = false;
            if (token.kind == .identifier and std.mem.eql(u8, token.lexeme, "then")) {
                suppress_newline = true;
            }

            // For `else`, dedent back to the level before `then`
            if (token.kind == .identifier and std.mem.eql(u8, token.lexeme, "else") and do_indent_level > 0) {
                do_indent_level -= 1;
            }

            if (suppress_newline) {
                // Don't output newline, just mark that we're not at line start
                // The spacing logic will handle adding a space if needed
                at_line_start = false;
            } else {
                // Check if this token is dedented in the source compared to expected indentation
                // Only dedent if the source appears to be intentionally dedented (not just badly formatted)
                // Don't dedent if:
                // 1. indent_level changed since last line (we just opened a brace)
                // 2. This is an object field name (identifier followed by colon at object field level)

                // Check if this is an object field name by looking ahead
                var is_object_field = false;
                if (token.kind == .identifier and i + 1 < tokens.items.len) {
                    const next_token = tokens.items[i + 1].token;
                    // If next token is a colon, this is a field name
                    if (next_token.kind == .colon) {
                        // Check if we're inside a multi-line object
                        for (brace_stack.items) |brace_info| {
                            if (brace_info.brace_type == .brace and !brace_info.is_single_line) {
                                is_object_field = true;
                                break;
                            }
                        }
                    }
                }

                // For object fields, reset do_indent_level to the context from when the object was opened
                // This preserves outer indentation (like from 'else') while removing field-value indentation
                if (is_object_field) {
                    // Find the innermost enclosing multi-line object's context (search backwards)
                    var stack_idx = brace_stack.items.len;
                    while (stack_idx > 0) {
                        stack_idx -= 1;
                        const brace_info = brace_stack.items[stack_idx];
                        if (brace_info.brace_type == .brace and !brace_info.is_single_line) {
                            do_indent_level = brace_info.context_do_indent;
                            break;
                        }
                    }
                // Don't apply source-based dedenting for control flow keywords (else, then)
                // or closing braces/brackets/parens - these should be positioned by structural rules
                } else if (do_indent_level > 0 and indent_level == prev_indent_level) {
                    const is_control_flow_keyword = token.kind == .identifier and
                        (std.mem.eql(u8, token.lexeme, "else") or std.mem.eql(u8, token.lexeme, "then"));
                    const is_closing_brace = token.kind == .r_brace or token.kind == .r_bracket or token.kind == .r_paren;

                    if (!is_control_flow_keyword and !is_closing_brace) {
                        const source_indent = if (token.column > 1) (token.column - 1) / 2 else 0;
                        const base_indent = indent_level;
                        const expected_indent = indent_level + do_indent_level;
                        // Use source indentation for dedenting:
                        // 1. If source is at or below base level, reset to 0 (explicit dedent)
                        // 2. If source is between base and expected, match source (partial dedent)
                        // 3. If source is at or above expected, keep current level (no dedent)
                        //
                        // Special case: only apply dedenting if source_indent > 0 OR if base_indent == 0
                        // (to handle closing brackets at root level)
                        if (source_indent > 0 or base_indent == 0) {
                            if (source_indent <= base_indent) {
                                do_indent_level = 0;
                            } else if (source_indent < expected_indent) {
                                do_indent_level = source_indent - base_indent;
                            }
                        }
                    }
                }

                // Remember indent level for next newline
                prev_indent_level = indent_level;

            // Check if previous token was `do`, `where`, `matches`, `then`, `else`, or `->` to increase indent
            // For `=` and `:`, only apply continuation indent for continuation operators like `\`
            if (just_saw_equals_or_colon and (token.kind == .backslash)) {
                do_indent_level += 1;
                just_saw_equals_or_colon = false;
            } else if (just_saw_equals_or_colon) {
                // Clear the flag if we're not on a continuation operator
                just_saw_equals_or_colon = false;
            }

            if (i > 0) {
                const prev_tok = tokens.items[i - 1].token;
                if (prev_tok.kind == .arrow) {
                    do_indent_level += 1;
                } else if (prev_tok.kind == .colon) {
                    // Indent after colon in object fields
                    // Check if we're in a multi-line object
                    for (brace_stack.items) |brace_info| {
                        if (brace_info.brace_type == .brace and !brace_info.is_single_line) {
                            do_indent_level += 1;
                            break;
                        }
                    }
                } else if (prev_tok.kind == .identifier and
                    (std.mem.eql(u8, prev_tok.lexeme, "do") or
                     std.mem.eql(u8, prev_tok.lexeme, "where") or
                     std.mem.eql(u8, prev_tok.lexeme, "matches") or
                     std.mem.eql(u8, prev_tok.lexeme, "then") or
                     std.mem.eql(u8, prev_tok.lexeme, "else"))) {
                    do_indent_level += 1;
                }
            }

            // Extract regular comments from the gap before this token
            const CommentLine = struct {
                text: []const u8,
                blank_line_after: bool,
            };
            var comments = std.ArrayList(CommentLine){};
            defer comments.deinit(allocator);

            // Get the text between previous token (or start of file) and current token
            const between = if (i > 0)
                source[tokens.items[i - 1].source_end..info.source_start]
            else
                source[0..info.source_start];

            if (between.len > 0) {

                var search_idx: usize = 0;
                while (search_idx < between.len) {
                    if (search_idx + 1 < between.len and between[search_idx] == '/' and between[search_idx + 1] == '/') {
                        // Check if it's a doc comment (///)
                        if (search_idx + 2 < between.len and between[search_idx + 2] == '/') {
                            // Skip doc comments - they're handled separately
                            search_idx += 3;
                            while (search_idx < between.len and between[search_idx] != '\n') {
                                search_idx += 1;
                            }
                            continue;
                        }

                        // Regular comment - extract it
                        const comment_content_start = search_idx + 2;
                        var comment_content_end = comment_content_start;
                        while (comment_content_end < between.len and between[comment_content_end] != '\n') {
                            comment_content_end += 1;
                        }
                        const comment_text = between[comment_content_start..comment_content_end];

                        // Check if there's a blank line after this comment
                        var check_idx = comment_content_end;
                        if (check_idx < between.len and between[check_idx] == '\n') {
                            check_idx += 1;
                        }
                        const blank_line_after = check_idx < between.len and between[check_idx] == '\n';

                        try comments.append(allocator, CommentLine{
                            .text = comment_text,
                            .blank_line_after = blank_line_after,
                        });

                        search_idx = comment_content_end;
                    } else {
                        search_idx += 1;
                    }
                }
            }

            // Count newlines between previous token and this one
            var newline_count: usize = 1;
            if (i > 0) {
                const prev_info = tokens.items[i - 1];
                const prev_tok = prev_info.token;
                const raw_newline_count = countNewlines(between);

                // If this token has doc comments, the space between includes those doc comment lines.
                // We only want to preserve blank lines, not count doc comment lines.
                // So limit to 2 newlines (one blank line max) when doc comments are present.
                if (token.doc_comments != null) {
                    // Special case: if previous token is opening brace/bracket, no blank lines
                    if (prev_tok.kind == .l_brace or prev_tok.kind == .l_bracket) {
                        newline_count = 1;
                    } else {
                        newline_count = @min(raw_newline_count, 2);
                    }
                } else {
                    newline_count = raw_newline_count;
                    // Still limit excessive blank lines to 2 (meaning 3 newlines)
                    if (newline_count > 3) newline_count = 3;
                }
            } else {
                // First token - check if we have leading comments
                if (comments.items.len > 0) {
                    // Count newlines for blank lines after comments
                    newline_count = countNewlines(between);
                } else if (token.doc_comments == null) {
                    // No comments and no doc comments - preserve any newlines
                    newline_count = countNewlines(between);
                } else {
                    // Has doc comments - no newlines before
                    newline_count = 0;
                }
            }

            // Determine newlines before comments block
            // Don't add extra newlines - comments preserve their blank lines internally
            var newlines_before_comments: usize = 0;

            if (i > 0 and comments.items.len > 0) {
                // For comments after a token, check if there should be a blank line before the block
                // Count blank lines that appear before the first comment
                var blank_lines_before: usize = 0;
                const total_newlines = countNewlines(between);
                // Count blank lines consumed by comments (each comment has 1 newline, plus any blank_line_after)
                var comment_newlines: usize = 0;
                for (comments.items) |comment_line| {
                    comment_newlines += 1;
                    if (comment_line.blank_line_after) comment_newlines += 1;
                }
                if (total_newlines > comment_newlines) {
                    blank_lines_before = total_newlines - comment_newlines;
                }
                newlines_before_comments = blank_lines_before;
            }

            // Output newlines before comments
            for (0..newlines_before_comments) |_| {
                try output.appendSlice(allocator, "\n");
            }

            // Output comments with proper indentation and blank lines between them
            for (comments.items) |comment_line| {
                const total_indent = indent_level + do_indent_level;
                for (0..total_indent) |_| {
                    try output.appendSlice(allocator, "  ");
                }

                try output.appendSlice(allocator, "//");
                const trimmed = std.mem.trimRight(u8, comment_line.text, " \t");
                if (trimmed.len > 0 and trimmed[0] == ' ') {
                    try output.appendSlice(allocator, trimmed);
                } else if (trimmed.len > 0) {
                    try output.appendSlice(allocator, " ");
                    try output.appendSlice(allocator, trimmed);
                }
                try output.appendSlice(allocator, "\n");

                // Add blank line after comment if it had one in the source
                if (comment_line.blank_line_after) {
                    try output.appendSlice(allocator, "\n");
                }
            }

            // If no comments were output, we still need to output newlines
            if (comments.items.len == 0) {
                // Output newlines, limiting excessive blank lines to 2
                var lines_to_output = newline_count;
                if (lines_to_output > 3) lines_to_output = 3;
                for (0..lines_to_output) |_| {
                    try output.appendSlice(allocator, "\n");
                }
            }

            at_line_start = true;
            }  // end of else block for suppress_newline
        }


        // Calculate if we need space before this token
        // Get the token before prev_token for unary operator detection
        var token_before_prev: ?evaluator.TokenKind = null;
        if (i >= 2) {
            token_before_prev = tokens.items[i - 2].token.kind;
        }
        var needs_space_before = !at_line_start and prev_token != null and
            needsSpaceBefore(token_before_prev, prev_token.?, token.kind, brace_stack.items);

        // Special case: preserve space before `.` for partial application syntax
        // e.g., `Array.sortBy .age` should keep the space before `.age`
        if (!needs_space_before and token.kind == .dot and token.preceded_by_whitespace and !at_line_start) {
            needs_space_before = true;
        }

        // Special case: array indexing vs array literal
        // envConfig[target] (no space) vs foo bar [1, 2, 3] (space for function call)
        // Indexing: arr[0], obj.field[0]
        // Function call/juxtaposition: foo [1, 2], foo bar [1, 2], [1, 2] [3, 4]
        //
        // Heuristic: if no whitespace before `[` in source, check if it's indexing:
        // - After dot: definitely indexing (obj.field[0])
        // - After identifier: only indexing if NOT a function call
        //   (function call if token_before_prev is also a value token)
        //
        // Note: We do NOT treat `arr[0][1]` or `(expr)[0]` as indexing by default,
        // because the space should be added by normal spacing rules unless the source
        // explicitly omits it. The formatter preserves source intent for these cases.
        if (needs_space_before and token.kind == .l_bracket and !token.preceded_by_whitespace and prev_token != null) {
            if (prev_token.? == .dot) {
                // Definitely indexing after field access
                needs_space_before = false;
            } else if (prev_token.? == .identifier and token_before_prev != null) {
                // Only indexing if previous identifier is NOT part of a function call
                // Function call: foo bar[...] where foo is also an identifier/value
                const is_function_call = token_before_prev.? == .identifier or
                    token_before_prev.? == .symbol or token_before_prev.? == .string or
                    token_before_prev.? == .number or token_before_prev.? == .r_bracket or
                    token_before_prev.? == .r_paren or token_before_prev.? == .r_brace;
                if (!is_function_call) {
                    needs_space_before = false;
                }
            }
        }

        // Reset do_indent_level if we're starting a new statement at array level
        if (at_line_start and token.kind == .identifier and do_indent_level > 0) {
            // Keywords that start new statements
            if (std.mem.eql(u8, token.lexeme, "it") or
                std.mem.eql(u8, token.lexeme, "describe")) {
                do_indent_level = 0;
            }
        }

        // Output doc comments before the token
        if (token.doc_comments) |docs| {
            // Split doc comments by newlines and output each line with proper indentation
            var lines = std.mem.splitScalar(u8, docs, '\n');
            while (lines.next()) |line| {
                // Write indentation if at line start
                if (at_line_start) {
                    const total_indent = indent_level + do_indent_level;
                    for (0..total_indent) |_| {
                        try output.appendSlice(allocator, "  ");
                    }
                }
                // Trim trailing whitespace from doc comment line
                const trimmed_line = std.mem.trimRight(u8, line, " \t");
                if (trimmed_line.len > 0) {
                    try output.appendSlice(allocator, "/// ");
                    try output.appendSlice(allocator, trimmed_line);
                } else {
                    // Empty line - just output ///
                    try output.appendSlice(allocator, "///");
                }
                try output.appendSlice(allocator, "\n");
                at_line_start = true;
            }
        }

        // Write indentation at line start
        if (at_line_start and token.kind != .eof) {
            const total_indent = indent_level + do_indent_level;
            for (0..total_indent) |_| {
                try output.appendSlice(allocator, "  ");
            }
            at_line_start = false;
        } else if (needs_space_before) {
            try output.appendSlice(allocator, " ");
        }

        // For single-line objects, add space after opening brace
        // For object projections (e.g., obj.{ x, y }), also add spaces
        // NOTE: If the brace has doc comments, it should always be treated as multi-line
        // Exception: Empty objects `{}` should not have spaces
        if (token.kind == .l_brace) {
            const has_docs = token.doc_comments != null;
            if (!has_docs) {
                if (brace_is_single_line.get(i)) |is_single| {
                    if (is_single) {
                        // Check if next token is closing brace (empty object)
                        const is_empty = i + 1 < tokens.items.len and tokens.items[i + 1].token.kind == .r_brace;
                        if (is_empty) {
                            try output.appendSlice(allocator, "{}");
                            // Skip the closing brace since we already wrote it
                            try brace_stack.append(allocator, BraceInfo{ .brace_type = .brace, .is_single_line = true, .skipped = true, .context_do_indent = do_indent_level });
                        } else {
                            try output.appendSlice(allocator, "{ ");
                            try brace_stack.append(allocator, BraceInfo{ .brace_type = .brace, .is_single_line = true, .context_do_indent = do_indent_level });
                        }
                        prev_token = token.kind;
                        continue;
                    }
                }
            }
        }

        // Skip semicolons in multi-line parenthesized blocks
        // (They're used for sequencing in let-bindings but shouldn't appear in formatted output)
        if (token.kind == .semicolon) {
            // Check if we're in a multi-line paren block
            var in_multiline_paren = false;
            for (brace_stack.items) |brace_info| {
                if (brace_info.brace_type == .paren and !brace_info.is_single_line) {
                    in_multiline_paren = true;
                    break;
                }
            }

            if (in_multiline_paren) {
                prev_token = token.kind;
                continue; // Skip this semicolon
            }
        }

        // Handle commas in collections
        if (token.kind == .comma) {
            // Check if the IMMEDIATE parent collection (brace/bracket/paren) is multi-line
            // We need to skip parentheses when looking for objects/arrays, but not skip them entirely
            // because function calls with parens should not have forced newlines
            var in_multiline_collection = false;
            var in_single_line_collection = false;

            // Start from the end (innermost) and find the first brace/bracket/paren
            if (brace_stack.items.len > 0) {
                const immediate_parent = brace_stack.items[brace_stack.items.len - 1];
                // Only apply multi-line formatting to braces and brackets, not parens
                if (immediate_parent.brace_type == .brace or immediate_parent.brace_type == .bracket) {
                    if (immediate_parent.is_single_line) {
                        in_single_line_collection = true;
                    } else {
                        in_multiline_collection = true;
                    }
                }
            }

            // Check if this is a trailing comma
            const is_trailing = if (i + 1 < tokens.items.len) blk: {
                const next_token = tokens.items[i + 1].token;
                break :blk next_token.kind == .r_brace or next_token.kind == .r_bracket;
            } else false;

            // Skip trailing commas in all collections
            if (is_trailing) {
                prev_token = token.kind;
                continue;
            }

            // For multi-line objects (braces) and arrays (brackets), skip all commas but force newline
            if (in_multiline_collection) {
                // Force newline if next token isn't already on one
                if (i + 1 < tokens.items.len) {
                    const next_token = tokens.items[i + 1].token;
                    if (!next_token.preceded_by_newline) {
                        try output.appendSlice(allocator, "\n");
                        at_line_start = true;
                    }
                }
                prev_token = token.kind;
                continue;
            }

            // For single-line collections, commas are written normally (below)
        }

        // Write the token
        if (token.kind == .string) {
            try output.appendSlice(allocator, "\"");
            try output.appendSlice(allocator, token.lexeme);
            try output.appendSlice(allocator, "\"");
        } else {
            try output.appendSlice(allocator, token.lexeme);
        }

        // After closing brace of a multi-line object/array, force newline if next token isn't on one
        // This ensures each closing brace is on its own line
        // Exception: if next token is a comma, keep it on the same line
        if (just_closed_multiline_collection and i + 1 < tokens.items.len) {
            const next_token = tokens.items[i + 1].token;
            if (!next_token.preceded_by_newline and next_token.kind != .comma) {
                try output.appendSlice(allocator, "\n");
                at_line_start = true;
            }
            just_closed_multiline_collection = false;
        }

        // After `then`, check if this is a multi-line if/then/else
        // If we find an `else` ahead that's on its own line, force newline after `then`
        if (token.kind == .identifier and std.mem.eql(u8, token.lexeme, "then")) {
            // Look ahead for else, tracking brace depth to skip over nested structures
            var found_multiline_else = false;
            var depth: i32 = 0;
            for (tokens.items[i + 1 ..]) |future_info| {
                const future_tok = future_info.token;

                // Track brace/bracket/paren depth
                if (future_tok.kind == .l_brace or future_tok.kind == .l_bracket or future_tok.kind == .l_paren) {
                    depth += 1;
                } else if (future_tok.kind == .r_brace or future_tok.kind == .r_bracket or future_tok.kind == .r_paren) {
                    depth -= 1;
                    // If we've closed all braces and see a closing brace at depth < 0, stop
                    if (depth < 0) break;
                }

                // Only look for else at depth 0 (not inside nested structures)
                if (depth == 0) {
                    if (future_tok.kind == .identifier and std.mem.eql(u8, future_tok.lexeme, "else")) {
                        if (future_tok.preceded_by_newline) {
                            found_multiline_else = true;
                        }
                        break;
                    }
                    // Stop at semicolon at depth 0
                    if (future_tok.kind == .semicolon) break;
                }
            }

            // If we found a multi-line else, force newline after then
            if (found_multiline_else and i + 1 < tokens.items.len) {
                const next_token = tokens.items[i + 1].token;
                if (!next_token.preceded_by_newline) {
                    try output.appendSlice(allocator, "\n");
                    at_line_start = true;
                    // Increment indent for the then branch body
                    do_indent_level += 1;
                }
            }
        }

        // After `else`, if it was on its own line, force newline for the else branch
        if (token.kind == .identifier and std.mem.eql(u8, token.lexeme, "else")) {
            // Check if this else was preceded by a newline (multi-line mode)
            if (token.preceded_by_newline and i + 1 < tokens.items.len) {
                const next_token = tokens.items[i + 1].token;
                if (!next_token.preceded_by_newline) {
                    try output.appendSlice(allocator, "\n");
                    at_line_start = true;
                    // Increment indent for the else branch body
                    do_indent_level += 1;
                }
            }
        }


        // Update indentation for opening braces/brackets
        if (token.kind == .l_brace) {
            const is_single = brace_is_single_line.get(i) orelse false;
            try brace_stack.append(allocator, BraceInfo{ .brace_type = .brace, .is_single_line = is_single, .context_do_indent = do_indent_level });
            if (!is_single) {
                indent_level += 1;
                // For multi-line objects, force newline if next token is on same line
                if (i + 1 < tokens.items.len) {
                    const next_token = tokens.items[i + 1].token;
                    if (!next_token.preceded_by_newline) {
                        try output.appendSlice(allocator, "\n");
                        at_line_start = true;
                    }
                }
            }
        } else if (token.kind == .l_bracket) {
            const is_single = brace_is_single_line.get(i) orelse false;
            try brace_stack.append(allocator, BraceInfo{ .brace_type = .bracket, .is_single_line = is_single, .context_do_indent = do_indent_level });
            if (!is_single) {
                indent_level += 1;
                // Don't reset do_indent_level - maintain accumulated indentation
            }
        } else if (token.kind == .l_paren) {
            const is_single = brace_is_single_line.get(i) orelse true;
            try brace_stack.append(allocator, BraceInfo{ .brace_type = .paren, .is_single_line = is_single, .context_do_indent = do_indent_level });
            if (!is_single) {
                indent_level += 1;
            }
        }

        // Set flag if we just saw = or : and there's content on the same line
        // (This handles continuation lines like: result = 42 \ double)
        if (token.kind == .equals or token.kind == .colon) {
            // Check if next token is on the same line
            if (i + 1 < tokens.items.len) {
                const next_token = tokens.items[i + 1].token;
                if (!next_token.preceded_by_newline) {
                    just_saw_equals_or_colon = true;
                }
            }
        }

        // Clear flag if we encounter a newline directly after = or : (handled by arrow logic)
        if (token.preceded_by_newline and prev_token != null and
            (prev_token.? == .equals or prev_token.? == .colon)) {
            just_saw_equals_or_colon = false;
        }

        prev_token = token.kind;
    }

    // Ensure file ends with newline
    if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
        try output.appendSlice(allocator, "\n");
    }

    return FormatterOutput{
        .text = try output.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Analyze which braces/brackets/parens are single-line
fn analyzeBraces(tokens: []const evaluator.Token, map: *std.AutoHashMap(usize, bool)) !void {
    var stack = std.ArrayList(usize){};
    defer stack.deinit(map.allocator);

    for (tokens, 0..) |token, i| {
        if (token.kind == .l_brace or token.kind == .l_bracket or token.kind == .l_paren) {
            try stack.append(map.allocator, i);
        } else if (token.kind == .r_brace or token.kind == .r_bracket or token.kind == .r_paren) {
            if (stack.items.len > 0) {
                const open_idx = stack.items[stack.items.len - 1];
                _ = stack.pop();
                // Check if there's a newline between open and close
                var has_newline = false;
                for (tokens[open_idx + 1 .. i]) |t| {
                    if (t.preceded_by_newline) {
                        has_newline = true;
                        break;
                    }
                }
                try map.put(open_idx, !has_newline);
            }
        }
    }
}

/// Format a file and return the formatted source
pub fn formatFile(allocator: std.mem.Allocator, file_path: []const u8) FormatterError!FormatterOutput {
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        return FormatterError.ParseError;
    };
    defer file.close();

    const source = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return FormatterError.ParseError;
    };
    defer allocator.free(source);

    return formatSource(allocator, source);
}

fn needsSpaceBefore(token_before_prev: ?evaluator.TokenKind, prev: evaluator.TokenKind, current: evaluator.TokenKind, brace_stack: []const BraceInfo) bool {
    _ = brace_stack; // Not currently used, but may be needed for future rules

    // Space before opening paren after number/identifier/string/symbol (function call)
    if (current == .l_paren and (prev == .number or prev == .identifier or prev == .string or prev == .symbol)) {
        return true;
    }

    // No space after opening brackets/parens
    if (prev == .l_paren or prev == .l_bracket) {
        return false;
    }

    // Space before opening bracket after identifier/number/string/symbol/r_paren
    if (current == .l_bracket and (prev == .identifier or prev == .number or prev == .string or prev == .symbol or prev == .r_paren)) {
        return true;
    }

    // Space before opening brace after identifier/string/symbol/r_paren/r_bracket
    if (current == .l_brace and (prev == .identifier or prev == .string or prev == .symbol or prev == .r_paren or prev == .r_bracket)) {
        return true;
    }

    // Space after opening brace only handled specially in main loop
    if (prev == .l_brace) {
        return false;
    }

    // No space before closing brackets/parens
    if (current == .r_paren or current == .r_bracket) {
        return false;
    }

    // Space before closing brace only handled specially in main loop
    if (current == .r_brace) {
        return false;
    }

    // No space before comma, colon, or semicolon
    if (current == .comma or current == .colon or current == .semicolon) {
        return false;
    }

    // Space after comma, colon, semicolon
    if (prev == .comma or prev == .semicolon) {
        return true;
    }

    // Space after colon
    if (prev == .colon) {
        return true;
    }

    // Space around equals and arrow
    if (prev == .equals or current == .equals) {
        return true;
    }
    if (prev == .arrow or current == .arrow) {
        return true;
    }

    // Space between identifiers, numbers, strings, symbols
    if ((prev == .identifier or prev == .number or prev == .string or prev == .symbol) and
        (current == .identifier or current == .number or current == .string or current == .symbol))
    {
        return true;
    }

    // Space before unary operators after identifiers/numbers/strings/symbols
    if ((prev == .identifier or prev == .number or prev == .string or prev == .symbol) and
        (current == .bang or current == .minus))
    {
        return true;
    }

    // Space between closing and opening brackets/parens/braces
    if ((prev == .r_paren or prev == .r_bracket or prev == .r_brace) and
        (current == .l_paren or current == .l_bracket or current == .l_brace or
        current == .identifier or current == .number or current == .string or current == .symbol))
    {
        return true;
    }

    // Unary operators: no space after ! or - when used as unary
    // Unary context: after =, :, ->, (, [, ,, or other operators
    const prev_is_unary_context = if (token_before_prev) |before|
        before == .equals or before == .colon or before == .arrow or before == .l_paren or before == .l_bracket or
            before == .comma or before == .l_brace or
            before == .plus or before == .minus or before == .star or before == .slash or
            before == .ampersand_ampersand or before == .pipe_pipe
    else
        true; // At start of expression, treat as unary context

    // No space after unary ! or -
    if (prev_is_unary_context and (prev == .bang or prev == .minus)) {
        return false;
    }

    // Space around arithmetic operators (binary)
    if (prev == .plus or prev == .minus or prev == .star or prev == .slash or
        current == .plus or current == .minus or current == .star or current == .slash)
    {
        return true;
    }

    // Space around comparison operators
    if (prev == .less or prev == .greater or prev == .less_equals or prev == .greater_equals or
        prev == .equals_equals or prev == .bang_equals or
        current == .less or current == .greater or current == .less_equals or current == .greater_equals or
        current == .equals_equals or current == .bang_equals)
    {
        return true;
    }

    // Space around logical operators (binary operators only)
    // Note: .bang is unary only, not binary, so it's not included here
    if (prev == .ampersand_ampersand or prev == .pipe_pipe or
        current == .ampersand_ampersand or current == .pipe_pipe)
    {
        return true;
    }

    // Space around & (merge operator)
    if (prev == .ampersand or current == .ampersand) {
        return true;
    }

    // Space around \ (backslash/pipeline operator)
    if (prev == .backslash or current == .backslash) {
        return true;
    }

    // No space before opening paren after closing paren (function call result)
    // e.g., `(f x)(y)` not `(f x) (y)`
    if (current == .l_paren and prev == .r_paren) {
        return false;
    }

    return false;
}
