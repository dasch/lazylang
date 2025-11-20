const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const evaluator = @import("evaluator");

/// LSP Server state
pub const Server = struct {
    allocator: std.mem.Allocator,
    handler: *json_rpc.MessageHandler,
    initialized: bool = false,
    documents: std.StringHashMap(TextDocument),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, handler: *json_rpc.MessageHandler) !Self {
        return Self{
            .allocator = allocator,
            .handler = handler,
            .documents = std.StringHashMap(TextDocument).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.text);
        }
        self.documents.deinit();
    }

    /// Main server loop
    pub fn run(self: *Self) !void {
        while (true) {
            const message = self.handler.readMessage() catch |err| {
                if (err == error.EndOfStream) break;
                std.log.err("Failed to read message: {}", .{err});
                continue;
            };
            defer message.deinit();

            try self.handleMessage(message.value);
        }
    }

    /// Handle a JSON-RPC message
    fn handleMessage(self: *Self, message: std.json.Value) !void {
        const kind = json_rpc.parseMessageKind(message) catch {
            try self.handler.writeErrorResponse(null, json_rpc.ErrorCode.InvalidRequest, "Invalid JSON-RPC message");
            return;
        };

        switch (kind) {
            .request => try self.handleRequest(message),
            .notification => try self.handleNotification(message),
            .response, .error_response => {
                // We don't send requests, so we shouldn't get responses
                std.log.warn("Unexpected response message", .{});
            },
        }
    }

    /// Handle a JSON-RPC request
    fn handleRequest(self: *Self, message: std.json.Value) !void {
        const obj = message.object;
        const id = obj.get("id");
        const method_opt = obj.get("method");
        if (method_opt == null) return;
        const method = method_opt.?.string;

        // Catch all errors to prevent LSP crashes
        if (std.mem.eql(u8, method, "initialize")) {
            self.handleInitialize(id) catch |err| {
                std.log.err("Error in initialize: {}", .{err});
                return;
            };
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.handleShutdown(id) catch |err| {
                std.log.err("Error in shutdown: {}", .{err});
                return;
            };
        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            if (!self.initialized) {
                try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.ServerNotInitialized, "Server not initialized");
                return;
            }
            self.handleSemanticTokensFull(id, message) catch |err| {
                std.log.err("Error in semanticTokens: {}", .{err});
                self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InternalError, "Internal error") catch {};
            };
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            if (!self.initialized) {
                try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.ServerNotInitialized, "Server not initialized");
                return;
            }
            self.handleCompletion(id, message) catch |err| {
                std.log.err("Error in completion: {}", .{err});
                self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InternalError, "Internal error") catch {};
            };
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            if (!self.initialized) {
                try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.ServerNotInitialized, "Server not initialized");
                return;
            }
            self.handleDefinition(id, message) catch |err| {
                std.log.err("Error in definition: {}", .{err});
                self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InternalError, "Internal error") catch {};
            };
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            if (!self.initialized) {
                try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.ServerNotInitialized, "Server not initialized");
                return;
            }
            self.handleHover(id, message) catch |err| {
                std.log.err("Error in hover: {}", .{err});
                self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InternalError, "Internal error") catch {};
            };
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            if (!self.initialized) {
                try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.ServerNotInitialized, "Server not initialized");
                return;
            }
            self.handleDocumentSymbol(id, message) catch |err| {
                std.log.err("Error in documentSymbol: {}", .{err});
                self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InternalError, "Internal error") catch {};
            };
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            if (!self.initialized) {
                try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.ServerNotInitialized, "Server not initialized");
                return;
            }
            self.handleReferences(id, message) catch |err| {
                std.log.err("Error in references: {}", .{err});
                self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InternalError, "Internal error") catch {};
            };
        } else if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
            if (!self.initialized) {
                try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.ServerNotInitialized, "Server not initialized");
                return;
            }
            self.handleDocumentHighlight(id, message) catch |err| {
                std.log.err("Error in documentHighlight: {}", .{err});
                self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InternalError, "Internal error") catch {};
            };
        } else if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
            if (!self.initialized) {
                try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.ServerNotInitialized, "Server not initialized");
                return;
            }
            self.handleFoldingRange(id, message) catch |err| {
                std.log.err("Error in foldingRange: {}", .{err});
                self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InternalError, "Internal error") catch {};
            };
        } else {
            try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.MethodNotFound, "Method not found");
        }
    }

    /// Handle a JSON-RPC notification
    fn handleNotification(self: *Self, message: std.json.Value) !void {
        const obj = message.object;
        const method = obj.get("method").?.string;

        if (std.mem.eql(u8, method, "initialized")) {
            // Client acknowledges initialization
            std.log.info("Client initialized", .{});
        } else if (std.mem.eql(u8, method, "exit")) {
            std.log.info("Client requested exit", .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            if (!self.initialized) return;
            try self.handleDidOpen(message);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            if (!self.initialized) return;
            try self.handleDidChange(message);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            if (!self.initialized) return;
            try self.handleDidClose(message);
        } else {
            std.log.warn("Unknown notification: {s}", .{method});
        }
    }

    /// Handle initialize request
    fn handleInitialize(self: *Self, id: ?std.json.Value) !void {
        self.initialized = true;

        const response_json =
            \\{"capabilities":{"textDocumentSync":{"openClose":true,"change":1},"semanticTokensProvider":{"legend":{"tokenTypes":["keyword","number","string","operator","variable","function","comment","namespace"],"tokenModifiers":[]},"full":true},"completionProvider":{"triggerCharacters":["."," "]},"definitionProvider":true,"hoverProvider":true,"documentSymbolProvider":true,"referencesProvider":true,"documentHighlightProvider":true,"foldingRangeProvider":true},"serverInfo":{"name":"lazylang-lsp","version":"0.2.0"}}
        ;

        try self.handler.writeResponse(id, response_json);
        std.log.info("Server initialized", .{});
    }

    /// Handle shutdown request
    fn handleShutdown(self: *Self, id: ?std.json.Value) !void {
        self.initialized = false;
        try self.handler.writeResponse(id, "null");
        std.log.info("Server shutdown", .{});
    }

    /// Handle textDocument/didOpen notification
    fn handleDidOpen(self: *Self, message: std.json.Value) !void {
        const params = message.object.get("params").?.object;
        const text_document = params.get("textDocument").?.object;

        const uri = text_document.get("uri").?.string;
        const text = text_document.get("text").?.string;
        const version = @as(i32, @intCast(text_document.get("version").?.integer));

        // Store document
        const uri_copy = try self.allocator.dupe(u8, uri);
        const text_copy = try self.allocator.dupe(u8, text);

        try self.documents.put(uri_copy, .{
            .uri = uri_copy,
            .text = text_copy,
            .version = version,
        });

        std.log.info("Opened document: {s}", .{uri});

        // Publish diagnostics for this document (use the stored copy, not the JSON slice)
        // Wrapped in catch to prevent crashes from diagnostic errors
        self.publishDiagnostics(uri_copy, text_copy) catch |err| {
            std.log.err("Failed to publish diagnostics: {}", .{err});
        };
    }

    /// Handle textDocument/didChange notification
    fn handleDidChange(self: *Self, message: std.json.Value) !void {
        const params = message.object.get("params").?.object;
        const text_document = params.get("textDocument").?.object;
        const content_changes = params.get("contentChanges").?.array;

        const uri = text_document.get("uri").?.string;
        const version = @as(i32, @intCast(text_document.get("version").?.integer));

        // Full sync: replace entire document
        if (content_changes.items.len > 0) {
            const change = content_changes.items[0].object;
            const text = change.get("text").?.string;

            if (self.documents.getPtr(uri)) |doc| {
                self.allocator.free(doc.text);
                doc.text = try self.allocator.dupe(u8, text);
                doc.version = version;
                std.log.info("Updated document: {s}", .{uri});

                // Publish diagnostics for updated document (use the stored copy, not the JSON slice)
                // Wrapped in catch to prevent crashes from diagnostic errors
                self.publishDiagnostics(doc.uri, doc.text) catch |err| {
                    std.log.err("Failed to publish diagnostics on change: {}", .{err});
                };
            }
        }
    }

    /// Handle textDocument/didClose notification
    fn handleDidClose(self: *Self, message: std.json.Value) !void {
        const params = message.object.get("params").?.object;
        const text_document = params.get("textDocument").?.object;
        const uri = text_document.get("uri").?.string;

        if (self.documents.fetchRemove(uri)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.text);
            std.log.info("Closed document: {s}", .{uri});
        }
    }

    /// Handle textDocument/semanticTokens/full request
    fn handleSemanticTokensFull(self: *Self, id: ?std.json.Value, message: std.json.Value) !void {
        const params = message.object.get("params").?.object;
        const text_document = params.get("textDocument").?.object;
        const uri = text_document.get("uri").?.string;

        const doc = self.documents.get(uri) orelse {
            try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InvalidParams, "Document not found");
            return;
        };

        // Tokenize the document
        const tokens = try self.computeSemanticTokens(doc.text);
        defer self.allocator.free(tokens);

        // Build JSON array for tokens
        var json_buf = std.ArrayList(u8){};
        defer json_buf.deinit(self.allocator);

        try json_buf.appendSlice(self.allocator, "{\"data\":[");
        for (tokens, 0..) |token, i| {
            if (i > 0) try json_buf.append(self.allocator, ',');
            const token_str = try std.fmt.allocPrint(self.allocator, "{d}", .{token});
            defer self.allocator.free(token_str);
            try json_buf.appendSlice(self.allocator, token_str);
        }
        try json_buf.appendSlice(self.allocator, "]}");

        try self.handler.writeResponse(id, json_buf.items);
        std.log.info("Sent semantic tokens for: {s}", .{uri});
    }

    /// Compute semantic tokens for a document
    /// Returns an array of integers representing semantic tokens in LSP format:
    /// [deltaLine, deltaStartChar, length, tokenType, tokenModifiers, ...]
    fn computeSemanticTokens(self: *Self, text: []const u8) ![]u32 {
        var tokens = std.ArrayList(u32){};
        errdefer tokens.deinit(self.allocator);

        var tokenizer = evaluator.Tokenizer.init(text, self.allocator);

        var prev_line: u32 = 0;
        var prev_col: u32 = 0;
        var line: u32 = 0;
        var col: u32 = 0;

        while (true) {
            const token = tokenizer.next() catch |err| {
                std.log.warn("Tokenizer error: {}", .{err});
                break;
            };

            if (token.kind == .eof) break;

            // Calculate line and column from lexeme position
            const token_start = @intFromPtr(token.lexeme.ptr) - @intFromPtr(text.ptr);
            var current_line: u32 = 0;
            var current_col: u32 = 0;

            for (text[0..token_start]) |c| {
                if (c == '\n') {
                    current_line += 1;
                    current_col = 0;
                } else {
                    current_col += 1;
                }
            }

            line = current_line;
            col = current_col;

            const token_type = getTokenType(token.kind);
            const token_length: u32 = @intCast(token.lexeme.len);

            // LSP semantic tokens format: relative encoding
            const delta_line = line - prev_line;
            const delta_col = if (delta_line == 0) col - prev_col else col;

            try tokens.append(self.allocator, delta_line);
            try tokens.append(self.allocator, delta_col);
            try tokens.append(self.allocator, token_length);
            try tokens.append(self.allocator, token_type);
            try tokens.append(self.allocator, 0); // No modifiers

            prev_line = line;
            prev_col = col;
        }

        return tokens.toOwnedSlice(self.allocator);
    }

    /// Map Lazylang token kinds to LSP semantic token types
    fn getTokenType(kind: evaluator.TokenKind) u32 {
        return switch (kind) {
            .identifier => 4, // variable
            .number => 1, // number
            .string => 2, // string
            .symbol => 7, // namespace (using this for symbols)
            .comma, .colon, .semicolon, .equals, .arrow, .backslash, .dot => 3, // operator
            .plus, .minus, .star, .slash, .ampersand, .ampersand_ampersand, .pipe_pipe, .bang => 3, // operator
            .equals_equals, .bang_equals, .less, .greater, .less_equals, .greater_equals => 3, // operator
            .dot_dot, .dot_dot_dot => 3, // operator
            .l_paren, .r_paren, .l_bracket, .r_bracket, .l_brace, .r_brace => 3, // operator
            .eof => 0, // keyword (shouldn't happen)
        };
    }

    /// Publish diagnostics for a document
    fn publishDiagnostics(self: *Self, uri: []const u8, text: []const u8) !void {
        const diagnostics = try self.computeDiagnostics(text);
        defer {
            for (diagnostics) |diag| {
                self.allocator.free(diag.message);
            }
            self.allocator.free(diagnostics);
        }

        // Build the diagnostics notification
        var notification_buf = std.ArrayList(u8){};
        defer notification_buf.deinit(self.allocator);

        const writer = notification_buf.writer(self.allocator);

        // Start JSON object
        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
        try writer.writeAll(uri);
        try writer.writeAll("\",\"diagnostics\":[");

        // Write diagnostics array
        for (diagnostics, 0..) |diag, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"range\":{\"start\":{\"line\":");
            try writer.print("{d}", .{diag.start_line});
            try writer.writeAll(",\"character\":");
            try writer.print("{d}", .{diag.start_char});
            try writer.writeAll("},\"end\":{\"line\":");
            try writer.print("{d}", .{diag.end_line});
            try writer.writeAll(",\"character\":");
            try writer.print("{d}", .{diag.end_char});
            try writer.writeAll("}},\"severity\":");
            try writer.print("{d}", .{diag.severity});
            try writer.writeAll(",\"message\":\"");
            // Escape the message
            for (diag.message) |c| {
                if (c == '"' or c == '\\') try writer.writeByte('\\');
                try writer.writeByte(c);
            }
            try writer.writeAll("\"}");
        }

        try writer.writeAll("]}}");

        // Send notification with Content-Length header
        const content = notification_buf.items;
        const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{content.len});
        defer self.allocator.free(header);

        _ = try self.handler.stdout.write(header);
        _ = try self.handler.stdout.write(content);

        std.log.info("Published {d} diagnostics for: {s}", .{ diagnostics.len, uri });
    }

    /// Compute diagnostics for a document by attempting to parse it
    fn computeDiagnostics(self: *Self, text: []const u8) ![]Diagnostic {
        var diagnostics = std.ArrayList(Diagnostic){};
        errdefer diagnostics.deinit(self.allocator);

        // Try to parse the document
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // Set up error context to capture error locations
        var err_ctx = evaluator.ErrorContext.init(self.allocator);
        defer err_ctx.deinit();
        err_ctx.setSource(text);

        // Attempt parsing and catch errors
        var parser = evaluator.Parser.init(arena.allocator(), text) catch |err| {
            // Failed to initialize parser
            const diag = try self.createDiagnosticFromError(err, &err_ctx);
            try diagnostics.append(self.allocator, diag);
            return try diagnostics.toOwnedSlice(self.allocator);
        };

        parser.setErrorContext(&err_ctx);

        const result = parser.parse();
        if (result) |_| {
            // Parse successful, no diagnostics
        } else |err| {
            // Parse failed, create diagnostic
            const diag = try self.createDiagnosticFromError(err, &err_ctx);
            try diagnostics.append(self.allocator, diag);
        }

        return try diagnostics.toOwnedSlice(self.allocator);
    }

    /// Create a diagnostic from a parse error
    fn createDiagnosticFromError(self: *Self, err: anyerror, err_ctx: *evaluator.ErrorContext) !Diagnostic {
        // Default diagnostic at the start of the file
        var diag = Diagnostic{
            .start_line = 0,
            .start_char = 0,
            .end_line = 0,
            .end_char = 1,
            .severity = 1, // Error
            .message = undefined,
        };

        // Use error location from context if available
        if (err_ctx.last_error_location) |loc| {
            // LSP uses 0-based line and column numbers
            diag.start_line = @intCast(if (loc.line > 0) loc.line - 1 else 0);
            diag.start_char = @intCast(if (loc.column > 0) loc.column - 1 else 0);
            diag.end_line = diag.start_line;
            diag.end_char = @intCast(diag.start_char + loc.length);
        }

        // Create error message based on error type
        const message = switch (err) {
            error.UnexpectedToken => blk: {
                if (err_ctx.last_error_token_lexeme) |lexeme| {
                    break :blk try std.fmt.allocPrint(self.allocator, "Unexpected token: '{s}'", .{lexeme});
                }
                break :blk try self.allocator.dupe(u8, "Unexpected token");
            },
            error.ExpectedExpression => try self.allocator.dupe(u8, "Expected expression"),
            error.UnexpectedCharacter => try self.allocator.dupe(u8, "Unexpected character"),
            error.UnterminatedString => try self.allocator.dupe(u8, "Unterminated string literal"),
            error.InvalidNumber => try self.allocator.dupe(u8, "Invalid number format"),
            error.Overflow => try self.allocator.dupe(u8, "Number too large"),
            else => try std.fmt.allocPrint(self.allocator, "Syntax error: {s}", .{@errorName(err)}),
        };

        diag.message = message;
        return diag;
    }

    /// Handle textDocument/completion request
    fn handleCompletion(self: *Self, id: ?std.json.Value, message: std.json.Value) !void {
        const params = message.object.get("params").?.object;
        const text_document = params.get("textDocument").?.object;
        const position = params.get("position").?.object;
        const uri = text_document.get("uri").?.string;

        const doc = self.documents.get(uri) orelse {
            try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InvalidParams, "Document not found");
            return;
        };

        const line = @as(u32, @intCast(position.get("line").?.integer));
        const character = @as(u32, @intCast(position.get("character").?.integer));

        // Get completion items
        const items = try self.computeCompletions(doc.text, line, character);
        defer {
            for (items) |item| {
                self.allocator.free(item.label);
                if (item.detail) |detail| self.allocator.free(detail);
            }
            self.allocator.free(items);
        }

        // Build JSON response
        var response_buf = std.ArrayList(u8){};
        defer response_buf.deinit(self.allocator);

        const writer = response_buf.writer(self.allocator);

        try writer.writeAll("{\"items\":[");

        for (items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"label\":\"");
            try writer.writeAll(item.label);
            try writer.writeAll("\",\"kind\":");
            try writer.print("{d}", .{item.kind});
            if (item.detail) |detail| {
                try writer.writeAll(",\"detail\":\"");
                // Escape quotes in detail
                for (detail) |c| {
                    if (c == '"' or c == '\\') try writer.writeByte('\\');
                    try writer.writeByte(c);
                }
                try writer.writeAll("\"");
            }
            try writer.writeAll("}");
        }

        try writer.writeAll("]}");

        try self.handler.writeResponse(id, response_buf.items);
        std.log.info("Sent {d} completion items for: {s}", .{ items.len, uri });
    }

    /// Compute completion items for a document
    fn computeCompletions(self: *Self, text: []const u8, line: u32, character: u32) ![]CompletionItem {
        var items = std.ArrayList(CompletionItem){};
        errdefer items.deinit(self.allocator);

        // Check if we're inside an import statement
        if (try self.isInImportContext(text, line, character)) {
            // Return available module paths
            return try self.getModuleCompletions();
        }

        // Check if we're completing a field access (e.g., Array.ma -> Array.map)
        if (try self.getFieldAccessContext(text, line, character)) |field_context| {
            defer self.allocator.free(field_context.object_name);
            defer self.allocator.free(field_context.partial_field);
            return try self.getFieldCompletions(text, field_context);
        }

        // Keywords
        const keywords = [_][]const u8{
            "let", "if",     "then",  "else",  "when", "matches",
            "for", "in",     "import", "true", "false", "null",
        };

        for (keywords) |keyword| {
            const label = try self.allocator.dupe(u8, keyword);
            try items.append(self.allocator, .{
                .label = label,
                .kind = 14, // Keyword
                .detail = null,
            });
        }

        // Built-in functions (from stdlib)
        const builtins = [_]struct { name: []const u8, detail: []const u8 }{
            .{ .name = "Array", .detail = "Array utilities module" },
            .{ .name = "String", .detail = "String utilities module" },
            .{ .name = "Math", .detail = "Math utilities module" },
            .{ .name = "Object", .detail = "Object utilities module" },
            .{ .name = "JSON", .detail = "JSON utilities module" },
            .{ .name = "YAML", .detail = "YAML utilities module" },
        };

        for (builtins) |builtin| {
            const label = try self.allocator.dupe(u8, builtin.name);
            const detail = try self.allocator.dupe(u8, builtin.detail);
            try items.append(self.allocator, .{
                .label = label,
                .kind = 9, // Module
                .detail = detail,
            });
        }

        return try items.toOwnedSlice(self.allocator);
    }

    /// Field access context for completion
    const FieldAccessContext = struct {
        object_name: []const u8,    // e.g., "Array"
        partial_field: []const u8,  // e.g., "ma" from "Array.ma"
    };

    /// Check if we're in a field access context and return the context
    fn getFieldAccessContext(self: *Self, text: []const u8, target_line: u32, target_char: u32) !?FieldAccessContext {
        // Find the line content
        var current_line: u32 = 0;
        var line_start: usize = 0;
        var line_end: usize = 0;

        for (text, 0..) |c, i| {
            if (current_line == target_line) {
                line_end = i + 1; // Use past-the-end indexing
                if (c == '\n') break;
            } else if (c == '\n') {
                current_line += 1;
                if (current_line == target_line) {
                    line_start = i + 1;
                }
            }
        }

        if (current_line == target_line and line_end < line_start) {
            line_end = text.len;
        }

        if (current_line != target_line) return null;

        const line_text = text[line_start..line_end];
        if (target_char == 0) return null;

        // Get text before cursor on this line
        const before_cursor = if (target_char <= line_text.len)
            line_text[0..@min(target_char, line_text.len)]
        else
            line_text;

        // Look for pattern: identifier.partial_identifier
        // Work backwards from cursor to find the dot and identifier
        var dot_pos: ?usize = null;
        var i: usize = before_cursor.len;
        while (i > 0) {
            i -= 1;
            if (before_cursor[i] == '.') {
                dot_pos = i;
                break;
            }
            // Stop if we hit whitespace or other non-identifier chars
            if (!std.ascii.isAlphanumeric(before_cursor[i]) and before_cursor[i] != '_') {
                return null;
            }
        }

        if (dot_pos == null) return null;
        const dot_idx = dot_pos.?;

        // Extract partial field name after dot
        const partial_field = before_cursor[dot_idx + 1..];

        // Find identifier before dot
        if (dot_idx == 0) return null;
        var ident_start = dot_idx;
        while (ident_start > 0) {
            const c = before_cursor[ident_start - 1];
            if (!std.ascii.isAlphanumeric(c) and c != '_') break;
            ident_start -= 1;
        }

        if (ident_start == dot_idx) return null;
        const object_name = before_cursor[ident_start..dot_idx];

        return FieldAccessContext{
            .object_name = try self.allocator.dupe(u8, object_name),
            .partial_field = try self.allocator.dupe(u8, partial_field),
        };
    }

    /// Get fields from a stdlib module
    fn getStdlibModuleFields(self: *Self, module_name: []const u8) !?[]ObjectFieldInfo {
        const arena = self.allocator;

        if (std.mem.eql(u8, module_name, "Array")) {
            const fields = try arena.alloc(ObjectFieldInfo, 18);
            fields[0] = .{ .name = try arena.dupe(u8, "length"), .doc = try arena.dupe(u8, "Returns the number of elements in an array") };
            fields[1] = .{ .name = try arena.dupe(u8, "get"), .doc = try arena.dupe(u8, "Retrieves the element at the specified index") };
            fields[2] = .{ .name = try arena.dupe(u8, "map"), .doc = try arena.dupe(u8, "Applies a function to each element") };
            fields[3] = .{ .name = try arena.dupe(u8, "flatMap"), .doc = try arena.dupe(u8, "Applies a function and flattens results") };
            fields[4] = .{ .name = try arena.dupe(u8, "filter"), .doc = try arena.dupe(u8, "Keeps only elements that satisfy the predicate") };
            fields[5] = .{ .name = try arena.dupe(u8, "skip"), .doc = try arena.dupe(u8, "Removes elements that satisfy the predicate") };
            fields[6] = .{ .name = try arena.dupe(u8, "fold"), .doc = try arena.dupe(u8, "Folds an array from the left using an accumulator") };
            fields[7] = .{ .name = try arena.dupe(u8, "reverse"), .doc = try arena.dupe(u8, "Reverses an array") };
            fields[8] = .{ .name = try arena.dupe(u8, "empty"), .doc = try arena.dupe(u8, "Returns an empty array") };
            fields[9] = .{ .name = try arena.dupe(u8, "isEmpty"), .doc = try arena.dupe(u8, "Checks if an array is empty") };
            fields[10] = .{ .name = try arena.dupe(u8, "slice"), .doc = try arena.dupe(u8, "Extracts a slice from start to end") };
            fields[11] = .{ .name = try arena.dupe(u8, "sort"), .doc = try arena.dupe(u8, "Sorts an array in ascending order") };
            fields[12] = .{ .name = try arena.dupe(u8, "sortBy"), .doc = try arena.dupe(u8, "Sorts an array by a computed key function") };
            fields[13] = .{ .name = try arena.dupe(u8, "uniq"), .doc = try arena.dupe(u8, "Returns array with duplicates removed") };
            fields[14] = .{ .name = try arena.dupe(u8, "all"), .doc = try arena.dupe(u8, "Tests whether all elements satisfy a predicate") };
            fields[15] = .{ .name = try arena.dupe(u8, "any"), .doc = try arena.dupe(u8, "Tests whether any element satisfies a predicate") };
            fields[16] = .{ .name = try arena.dupe(u8, "none"), .doc = try arena.dupe(u8, "Tests whether no elements satisfy a predicate") };
            fields[17] = .{ .name = try arena.dupe(u8, "groupBy"), .doc = try arena.dupe(u8, "Groups elements by a computed key function") };
            return fields;
        } else if (std.mem.eql(u8, module_name, "String")) {
            const fields = try arena.alloc(ObjectFieldInfo, 19);
            fields[0] = .{ .name = try arena.dupe(u8, "length"), .doc = try arena.dupe(u8, "Returns the number of characters in a string") };
            fields[1] = .{ .name = try arena.dupe(u8, "append"), .doc = try arena.dupe(u8, "Appends one string to another") };
            fields[2] = .{ .name = try arena.dupe(u8, "concat"), .doc = try arena.dupe(u8, "Concatenates an array of strings") };
            fields[3] = .{ .name = try arena.dupe(u8, "split"), .doc = try arena.dupe(u8, "Splits a string using a delimiter") };
            fields[4] = .{ .name = try arena.dupe(u8, "toUpperCase"), .doc = try arena.dupe(u8, "Converts a string to uppercase") };
            fields[5] = .{ .name = try arena.dupe(u8, "toLowerCase"), .doc = try arena.dupe(u8, "Converts a string to lowercase") };
            fields[6] = .{ .name = try arena.dupe(u8, "chars"), .doc = try arena.dupe(u8, "Converts string into array of characters") };
            fields[7] = .{ .name = try arena.dupe(u8, "isEmpty"), .doc = try arena.dupe(u8, "Checks if a string is empty") };
            fields[8] = .{ .name = try arena.dupe(u8, "trim"), .doc = try arena.dupe(u8, "Removes whitespace from both ends") };
            fields[9] = .{ .name = try arena.dupe(u8, "startsWith"), .doc = try arena.dupe(u8, "Checks if string starts with a prefix") };
            fields[10] = .{ .name = try arena.dupe(u8, "endsWith"), .doc = try arena.dupe(u8, "Checks if string ends with a suffix") };
            fields[11] = .{ .name = try arena.dupe(u8, "contains"), .doc = try arena.dupe(u8, "Checks if string contains a substring") };
            fields[12] = .{ .name = try arena.dupe(u8, "repeat"), .doc = try arena.dupe(u8, "Repeats a string n times") };
            fields[13] = .{ .name = try arena.dupe(u8, "replace"), .doc = try arena.dupe(u8, "Replaces all occurrences of a substring") };
            fields[14] = .{ .name = try arena.dupe(u8, "join"), .doc = try arena.dupe(u8, "Joins an array of strings with separator") };
            fields[15] = .{ .name = try arena.dupe(u8, "slice"), .doc = try arena.dupe(u8, "Extracts a substring from start to end") };
            fields[16] = .{ .name = try arena.dupe(u8, "left"), .doc = try arena.dupe(u8, "Keeps the first n characters") };
            fields[17] = .{ .name = try arena.dupe(u8, "right"), .doc = try arena.dupe(u8, "Keeps the last n characters") };
            fields[18] = .{ .name = try arena.dupe(u8, "dropLeft"), .doc = try arena.dupe(u8, "Drops the first n characters") };
            return fields;
        } else if (std.mem.eql(u8, module_name, "Math")) {
            const fields = try arena.alloc(ObjectFieldInfo, 10);
            fields[0] = .{ .name = try arena.dupe(u8, "max"), .doc = try arena.dupe(u8, "Returns the maximum of two numbers") };
            fields[1] = .{ .name = try arena.dupe(u8, "min"), .doc = try arena.dupe(u8, "Returns the minimum of two numbers") };
            fields[2] = .{ .name = try arena.dupe(u8, "abs"), .doc = try arena.dupe(u8, "Returns the absolute value") };
            fields[3] = .{ .name = try arena.dupe(u8, "pow"), .doc = try arena.dupe(u8, "Returns base raised to exponent") };
            fields[4] = .{ .name = try arena.dupe(u8, "sqrt"), .doc = try arena.dupe(u8, "Returns the square root") };
            fields[5] = .{ .name = try arena.dupe(u8, "floor"), .doc = try arena.dupe(u8, "Rounds down to nearest integer") };
            fields[6] = .{ .name = try arena.dupe(u8, "ceil"), .doc = try arena.dupe(u8, "Rounds up to nearest integer") };
            fields[7] = .{ .name = try arena.dupe(u8, "round"), .doc = try arena.dupe(u8, "Rounds to nearest integer") };
            fields[8] = .{ .name = try arena.dupe(u8, "log"), .doc = try arena.dupe(u8, "Returns natural logarithm (base e)") };
            fields[9] = .{ .name = try arena.dupe(u8, "exp"), .doc = try arena.dupe(u8, "Returns e raised to the power of n") };
            return fields;
        } else if (std.mem.eql(u8, module_name, "Object")) {
            const fields = try arena.alloc(ObjectFieldInfo, 6);
            fields[0] = .{ .name = try arena.dupe(u8, "keys"), .doc = try arena.dupe(u8, "Returns an array of all keys") };
            fields[1] = .{ .name = try arena.dupe(u8, "values"), .doc = try arena.dupe(u8, "Returns an array of all values") };
            fields[2] = .{ .name = try arena.dupe(u8, "get"), .doc = try arena.dupe(u8, "Retrieves value for a key") };
            fields[3] = .{ .name = try arena.dupe(u8, "merge"), .doc = try arena.dupe(u8, "Merges two objects together") };
            fields[4] = .{ .name = try arena.dupe(u8, "mapValues"), .doc = try arena.dupe(u8, "Applies function to each value") };
            fields[5] = .{ .name = try arena.dupe(u8, "slice"), .doc = try arena.dupe(u8, "Returns object with only specified keys") };
            return fields;
        } else if (std.mem.eql(u8, module_name, "JSON")) {
            const fields = try arena.alloc(ObjectFieldInfo, 2);
            fields[0] = .{ .name = try arena.dupe(u8, "parse"), .doc = try arena.dupe(u8, "Parses a JSON string into a Lazylang value") };
            fields[1] = .{ .name = try arena.dupe(u8, "encode"), .doc = try arena.dupe(u8, "Encodes a Lazylang value into JSON string") };
            return fields;
        } else if (std.mem.eql(u8, module_name, "YAML")) {
            const fields = try arena.alloc(ObjectFieldInfo, 2);
            fields[0] = .{ .name = try arena.dupe(u8, "parse"), .doc = try arena.dupe(u8, "Parses a YAML string into a Lazylang value") };
            fields[1] = .{ .name = try arena.dupe(u8, "encode"), .doc = try arena.dupe(u8, "Encodes a Lazylang value into YAML string") };
            return fields;
        }

        return null;
    }

    /// Get field completions for an object
    fn getFieldCompletions(self: *Self, text: []const u8, context: FieldAccessContext) ![]CompletionItem {
        var items = std.ArrayList(CompletionItem){};
        errdefer items.deinit(self.allocator);

        // First check if it's a known stdlib module and load its exports
        const stdlib_module = try self.getStdlibModuleFields(context.object_name);
        if (stdlib_module) |fields| {
            defer self.allocator.free(fields);
            for (fields) |field| {
                if (context.partial_field.len == 0 or
                    std.mem.startsWith(u8, field.name, context.partial_field)) {
                    const label = try self.allocator.dupe(u8, field.name);
                    const detail = if (field.doc) |doc|
                        try self.allocator.dupe(u8, doc)
                    else
                        null;

                    try items.append(self.allocator, .{
                        .label = label,
                        .kind = 3, // Function
                        .detail = detail,
                    });
                }
                // Free the field doc if allocated
                if (field.doc) |doc| self.allocator.free(doc);
                self.allocator.free(field.name);
            }
            return try items.toOwnedSlice(self.allocator);
        }

        // Try to resolve the object by parsing and evaluating
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var parser = evaluator.Parser.init(arena.allocator(), text) catch {
            // If parsing fails, return empty
            return try items.toOwnedSlice(self.allocator);
        };
        const ast = parser.parse() catch {
            // If parsing fails, return empty
            return try items.toOwnedSlice(self.allocator);
        };

        // Search for the identifier in the AST to get its value
        const obj_info = try self.findObjectFields(ast.*, context.object_name, arena.allocator());

        if (obj_info) |fields| {
            // Filter fields by partial name and add to completions
            for (fields) |field| {
                // Check if field name starts with partial_field
                if (context.partial_field.len == 0 or
                    std.mem.startsWith(u8, field.name, context.partial_field)) {
                    const label = try self.allocator.dupe(u8, field.name);
                    const detail = if (field.doc) |doc|
                        try self.allocator.dupe(u8, doc)
                    else
                        null;

                    try items.append(self.allocator, .{
                        .label = label,
                        .kind = 5, // Field
                        .detail = detail,
                    });
                }
            }
        }

        return try items.toOwnedSlice(self.allocator);
    }

    /// Object field info
    const ObjectFieldInfo = struct {
        name: []const u8,
        doc: ?[]const u8,
    };

    /// Find object fields in the AST
    fn findObjectFields(self: *Self, expr: evaluator.Expression, identifier: []const u8, arena: std.mem.Allocator) !?[]ObjectFieldInfo {
        return switch (expr.data) {
            .let => |let| blk: {
                // Check if this let binding defines the identifier
                if (let.pattern.data == .identifier) {
                    const pat_id = let.pattern.data.identifier;
                    if (std.mem.eql(u8, pat_id, identifier)) {
                        // Found it! Check if value is an object
                        if (let.value.data == .object) {
                            const obj = let.value.data.object;
                            var fields = std.ArrayList(ObjectFieldInfo){};

                            for (obj.fields) |field| {
                                const field_name = switch (field.key) {
                                    .static => |s| s,
                                    .dynamic => continue,
                                };

                                try fields.append(arena, .{
                                    .name = field_name,
                                    .doc = field.doc,
                                });
                            }

                            break :blk try fields.toOwnedSlice(arena);
                        }
                    }
                }
                // Recursively search the body
                break :blk try self.findObjectFields(let.body.*, identifier, arena);
            },
            .object => |obj| blk: {
                // Top-level object - return its fields
                var fields = std.ArrayList(ObjectFieldInfo){};

                for (obj.fields) |field| {
                    const field_name = switch (field.key) {
                        .static => |s| s,
                        .dynamic => continue,
                    };

                    try fields.append(arena, .{
                        .name = field_name,
                        .doc = field.doc,
                    });
                }

                break :blk try fields.toOwnedSlice(arena);
            },
            else => null,
        };
    }

    /// Check if the cursor is inside an import statement string
    fn isInImportContext(self: *Self, text: []const u8, target_line: u32, target_char: u32) !bool {
        _ = self;

        // Find the line content
        var current_line: u32 = 0;
        var line_start: usize = 0;
        var line_end: usize = 0;

        for (text, 0..) |c, i| {
            if (current_line == target_line) {
                line_end = i + 1; // Use past-the-end indexing
                if (c == '\n') break;
            } else if (c == '\n') {
                current_line += 1;
                if (current_line == target_line) {
                    line_start = i + 1;
                }
            }
        }

        if (current_line == target_line and line_end < line_start) {
            line_end = text.len;
        }

        if (current_line != target_line) return false;

        const line_text = text[line_start..line_end];

        // Check if this line contains "import" followed by a string literal in progress
        const import_pos = std.mem.indexOf(u8, line_text, "import") orelse return false;

        // Check if cursor is after import and inside quotes
        if (target_char > import_pos + 6) {
            const after_import = line_text[import_pos + 6 ..];
            // Look for opening quote
            var in_string = false;
            for (after_import, 0..) |c, i| {
                if (c == '\'' or c == '"') {
                    in_string = !in_string;
                }
                if (import_pos + 6 + i >= target_char) {
                    return in_string;
                }
            }
        }

        return false;
    }

    /// Get available module paths for completion
    fn getModuleCompletions(self: *Self) ![]CompletionItem {
        var items = std.ArrayList(CompletionItem){};
        errdefer items.deinit(self.allocator);

        // Add stdlib modules
        const stdlib_modules = [_][]const u8{
            "Array",
            "String",
            "Math",
            "Object",
            "Result",
            "Tuple",
            "JSON",
            "YAML",
            "Spec",
        };

        for (stdlib_modules) |module| {
            const label = try self.allocator.dupe(u8, module);
            const detail = try std.fmt.allocPrint(self.allocator, "Standard library module", .{});
            try items.append(self.allocator, .{
                .label = label,
                .kind = 9, // Module
                .detail = detail,
            });
        }

        // TODO: Scan LAZYLANG_PATH directories for additional modules
        // For now, just return stdlib modules

        return try items.toOwnedSlice(self.allocator);
    }

    /// Handle textDocument/definition request
    fn handleDefinition(self: *Self, id: ?std.json.Value, message: std.json.Value) !void {
        const params = message.object.get("params").?.object;
        const text_document = params.get("textDocument").?.object;
        const position = params.get("position").?.object;
        const uri = text_document.get("uri").?.string;

        const doc = self.documents.get(uri) orelse {
            try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InvalidParams, "Document not found");
            return;
        };

        const line = @as(u32, @intCast(position.get("line").?.integer));
        const character = @as(u32, @intCast(position.get("character").?.integer));

        // Compute definition location
        const def_loc = try self.computeDefinitionLocation(doc.text, line, character);

        if (def_loc) |loc| {
            // Build JSON response
            var response_buf = std.ArrayList(u8){};
            defer response_buf.deinit(self.allocator);

            const writer = response_buf.writer(self.allocator);

            try writer.writeAll("{\"uri\":\"");
            try writer.writeAll(uri);
            try writer.writeAll("\",\"range\":{\"start\":{\"line\":");
            try writer.print("{d}", .{loc.start_line});
            try writer.writeAll(",\"character\":");
            try writer.print("{d}", .{loc.start_char});
            try writer.writeAll("},\"end\":{\"line\":");
            try writer.print("{d}", .{loc.end_line});
            try writer.writeAll(",\"character\":");
            try writer.print("{d}", .{loc.end_char});
            try writer.writeAll("}}}");

            try self.handler.writeResponse(id, response_buf.items);
            std.log.info("Sent definition location for: {s}", .{uri});
        } else {
            try self.handler.writeResponse(id, "null");
            std.log.info("No definition found for position", .{});
        }
    }

    /// Handle textDocument/hover request
    fn handleHover(self: *Self, id: ?std.json.Value, message: std.json.Value) !void {
        const params = message.object.get("params").?.object;
        const text_document = params.get("textDocument").?.object;
        const position = params.get("position").?.object;
        const uri = text_document.get("uri").?.string;

        const doc = self.documents.get(uri) orelse {
            try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InvalidParams, "Document not found");
            return;
        };

        const line = @as(u32, @intCast(position.get("line").?.integer));
        const character = @as(u32, @intCast(position.get("character").?.integer));

        // Compute hover info
        const hover_info = try self.computeHoverInfo(doc.text, line, character);
        defer if (hover_info) |info| {
            self.allocator.free(info.contents);
        };

        if (hover_info) |info| {
            // Build JSON response
            var response_buf = std.ArrayList(u8){};
            defer response_buf.deinit(self.allocator);

            const writer = response_buf.writer(self.allocator);

            try writer.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
            // Escape the markdown content
            for (info.contents) |c| {
                if (c == '"' or c == '\\') try writer.writeByte('\\');
                if (c == '\n') {
                    try writer.writeAll("\\n");
                } else {
                    try writer.writeByte(c);
                }
            }
            try writer.writeAll("\"}}");

            try self.handler.writeResponse(id, response_buf.items);
            std.log.info("Sent hover info for: {s}", .{uri});
        } else {
            try self.handler.writeResponse(id, "null");
            std.log.info("No hover info found for position", .{});
        }
    }

    /// Handle textDocument/documentSymbol request
    fn handleDocumentSymbol(self: *Self, id: ?std.json.Value, message: std.json.Value) !void {
        _ = message;
        // Return empty array for now
        // TODO: Implement document symbol extraction
        try self.handler.writeResponse(id, "[]");
        std.log.info("Document symbol request handled (not implemented)", .{});
    }

    /// Handle textDocument/references request
    fn handleReferences(self: *Self, id: ?std.json.Value, message: std.json.Value) !void {
        const params = message.object.get("params").?.object;
        const text_document = params.get("textDocument").?.object;
        const position = params.get("position").?.object;
        const uri = text_document.get("uri").?.string;

        const doc = self.documents.get(uri) orelse {
            try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InvalidParams, "Document not found");
            return;
        };

        const line = @as(u32, @intCast(position.get("line").?.integer));
        const character = @as(u32, @intCast(position.get("character").?.integer));

        // Find references for the identifier at the cursor position
        const references = try self.computeReferences(doc.text, line, character);
        defer self.allocator.free(references);

        // Build JSON response
        var response_buf = std.ArrayList(u8){};
        defer response_buf.deinit(self.allocator);

        const writer = response_buf.writer(self.allocator);

        try writer.writeAll("[");
        for (references, 0..) |ref, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"uri\":\"");
            try writer.writeAll(uri);
            try writer.writeAll("\",\"range\":{\"start\":{\"line\":");
            try writer.print("{d}", .{ref.start_line});
            try writer.writeAll(",\"character\":");
            try writer.print("{d}", .{ref.start_char});
            try writer.writeAll("},\"end\":{\"line\":");
            try writer.print("{d}", .{ref.end_line});
            try writer.writeAll(",\"character\":");
            try writer.print("{d}", .{ref.end_char});
            try writer.writeAll("}}}");
        }
        try writer.writeAll("]");

        try self.handler.writeResponse(id, response_buf.items);
        std.log.info("Sent {d} references for: {s}", .{ references.len, uri });
    }

    /// Handle textDocument/documentHighlight request
    fn handleDocumentHighlight(self: *Self, id: ?std.json.Value, message: std.json.Value) !void {
        const params = message.object.get("params").?.object;
        const text_document = params.get("textDocument").?.object;
        const position = params.get("position").?.object;
        const uri = text_document.get("uri").?.string;

        const doc = self.documents.get(uri) orelse {
            try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InvalidParams, "Document not found");
            return;
        };

        const line = @as(u32, @intCast(position.get("line").?.integer));
        const character = @as(u32, @intCast(position.get("character").?.integer));

        // Find highlights for the identifier at the cursor position
        const highlights = try self.computeDocumentHighlights(doc.text, line, character);
        defer self.allocator.free(highlights);

        // Build JSON response
        var response_buf = std.ArrayList(u8){};
        defer response_buf.deinit(self.allocator);

        const writer = response_buf.writer(self.allocator);

        try writer.writeAll("[");
        for (highlights, 0..) |highlight, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"range\":{\"start\":{\"line\":");
            try writer.print("{d}", .{highlight.start_line});
            try writer.writeAll(",\"character\":");
            try writer.print("{d}", .{highlight.start_char});
            try writer.writeAll("},\"end\":{\"line\":");
            try writer.print("{d}", .{highlight.end_line});
            try writer.writeAll(",\"character\":");
            try writer.print("{d}", .{highlight.end_char});
            try writer.writeAll("}},\"kind\":");
            try writer.print("{d}", .{highlight.kind});
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        try self.handler.writeResponse(id, response_buf.items);
        std.log.info("Sent {d} document highlights for: {s}", .{ highlights.len, uri });
    }

    /// Compute document highlights for an identifier at a given position
    fn computeDocumentHighlights(self: *Self, text: []const u8, target_line: u32, target_char: u32) ![]DocumentHighlight {
        var highlights = std.ArrayList(DocumentHighlight){};
        errdefer highlights.deinit(self.allocator);

        // Tokenize to find all identifiers
        var tokenizer = evaluator.Tokenizer.init(text, self.allocator);
        var target_identifier: ?[]const u8 = null;

        // First pass: find the identifier at the cursor position
        while (true) {
            const token = tokenizer.next() catch break;
            if (token.kind == .eof) break;

            if (token.kind == .identifier) {
                // Calculate position
                const token_line: u32 = @intCast(if (token.line > 0) token.line - 1 else 0); // Convert to 0-based
                const token_col: u32 = @intCast(if (token.column > 0) token.column - 1 else 0); // Convert to 0-based

                if (token_line == target_line and target_char >= token_col and target_char < token_col + token.lexeme.len) {
                    target_identifier = token.lexeme;
                    break;
                }
            }
        }

        // If no identifier at cursor, return empty
        const target = target_identifier orelse return try highlights.toOwnedSlice(self.allocator);

        // Second pass: find all occurrences of this identifier
        var tokenizer2 = evaluator.Tokenizer.init(text, self.allocator);
        while (true) {
            const token = tokenizer2.next() catch break;
            if (token.kind == .eof) break;

            if (token.kind == .identifier and std.mem.eql(u8, token.lexeme, target)) {
                const token_line: u32 = @intCast(if (token.line > 0) token.line - 1 else 0); // Convert to 0-based
                const token_col: u32 = @intCast(if (token.column > 0) token.column - 1 else 0); // Convert to 0-based

                try highlights.append(self.allocator, .{
                    .start_line = token_line,
                    .start_char = token_col,
                    .end_line = token_line,
                    .end_char = @intCast(token_col + token.lexeme.len),
                    .kind = 1, // Text (default)
                });
            }
        }

        return try highlights.toOwnedSlice(self.allocator);
    }

    /// Handle textDocument/foldingRange request
    fn handleFoldingRange(self: *Self, id: ?std.json.Value, message: std.json.Value) !void {
        const params = message.object.get("params").?.object;
        const text_document = params.get("textDocument").?.object;
        const uri = text_document.get("uri").?.string;

        const doc = self.documents.get(uri) orelse {
            try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InvalidParams, "Document not found");
            return;
        };

        // Compute folding ranges
        const ranges = try self.computeFoldingRanges(doc.text);
        defer self.allocator.free(ranges);

        // Build JSON response
        var response_buf = std.ArrayList(u8){};
        defer response_buf.deinit(self.allocator);

        const writer = response_buf.writer(self.allocator);

        try writer.writeAll("[");
        for (ranges, 0..) |range, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"startLine\":");
            try writer.print("{d}", .{range.start_line});
            try writer.writeAll(",\"endLine\":");
            try writer.print("{d}", .{range.end_line});
            if (range.kind) |kind| {
                try writer.writeAll(",\"kind\":\"");
                try writer.writeAll(kind);
                try writer.writeAll("\"");
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        try self.handler.writeResponse(id, response_buf.items);
        std.log.info("Sent {d} folding ranges for: {s}", .{ ranges.len, uri });
    }

    /// Compute folding ranges by matching brackets
    fn computeFoldingRanges(self: *Self, text: []const u8) ![]FoldingRange {
        var ranges = std.ArrayList(FoldingRange){};
        errdefer ranges.deinit(self.allocator);

        // Stack to track opening brackets with their line numbers
        var bracket_stack = std.ArrayList(struct {
            kind: evaluator.TokenKind,
            line: u32,
            fold_kind: ?[]const u8,
        }){};
        defer bracket_stack.deinit(self.allocator);

        var tokenizer = evaluator.Tokenizer.init(text, self.allocator);

        while (true) {
            const token = tokenizer.next() catch break;
            if (token.kind == .eof) break;

            const token_line: u32 = @intCast(if (token.line > 0) token.line - 1 else 0);

            switch (token.kind) {
                .l_brace => {
                    try bracket_stack.append(self.allocator, .{
                        .kind = .r_brace,
                        .line = token_line,
                        .fold_kind = "region",
                    });
                },
                .l_bracket => {
                    try bracket_stack.append(self.allocator, .{
                        .kind = .r_bracket,
                        .line = token_line,
                        .fold_kind = "region",
                    });
                },
                .l_paren => {
                    try bracket_stack.append(self.allocator, .{
                        .kind = .r_paren,
                        .line = token_line,
                        .fold_kind = null,
                    });
                },
                .r_brace, .r_bracket, .r_paren => {
                    if (bracket_stack.items.len > 0) {
                        const top = bracket_stack.items[bracket_stack.items.len - 1];
                        _ = bracket_stack.pop();
                        // Check if matching bracket
                        if (top.kind == token.kind) {
                            // Only create fold if spans multiple lines
                            if (token_line > top.line) {
                                try ranges.append(self.allocator, .{
                                    .start_line = top.line,
                                    .end_line = token_line,
                                    .kind = top.fold_kind,
                                });
                            }
                        }
                    }
                },
                else => {},
            }
        }

        return try ranges.toOwnedSlice(self.allocator);
    }

    /// Compute hover information for an identifier at a given position
    fn computeHoverInfo(self: *Self, text: []const u8, target_line: u32, target_char: u32) !?HoverInfo {
        // Find the identifier at the cursor position
        var tokenizer = evaluator.Tokenizer.init(text, self.allocator);
        var target_identifier: ?[]const u8 = null;

        while (true) {
            const token = tokenizer.next() catch break;
            if (token.kind == .eof) break;

            if (token.kind == .identifier) {
                // Calculate position (tokens use 1-based, LSP uses 0-based)
                const token_line: u32 = @intCast(if (token.line > 0) token.line - 1 else 0);
                const token_col: u32 = @intCast(if (token.column > 0) token.column - 1 else 0);

                if (token_line == target_line and target_char >= token_col and target_char < token_col + token.lexeme.len) {
                    target_identifier = token.lexeme;
                    break;
                }
            }
        }

        const identifier = target_identifier orelse return null;

        // Parse the document to find definitions
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var parser = evaluator.Parser.init(arena.allocator(), text) catch return null;
        const ast = parser.parse() catch return null;

        // Search the AST for this identifier's definition
        const def_info = try self.findDefinitionInAST(ast.*, identifier, arena.allocator());
        defer if (def_info) |info| {
            if (info.doc) |doc| arena.allocator().free(doc);
        };

        if (def_info) |info| {
            // Build markdown hover content
            var content = std.ArrayList(u8){};
            defer content.deinit(self.allocator);

            const writer = content.writer(self.allocator);

            // Show documentation if available
            if (info.doc) |doc| {
                try writer.writeAll(doc);
                try writer.writeAll("\n\n");
            }

            // Show identifier name
            try writer.writeAll("```lazylang\n");
            try writer.writeAll(identifier);
            try writer.writeAll("\n```");

            return HoverInfo{
                .contents = try self.allocator.dupe(u8, content.items),
            };
        }

        return null;
    }

    /// Compute definition location for an identifier at a given position
    fn computeDefinitionLocation(self: *Self, text: []const u8, target_line: u32, target_char: u32) !?DefinitionLocation {
        // Find the identifier at the cursor position
        var tokenizer = evaluator.Tokenizer.init(text, self.allocator);
        var target_identifier: ?[]const u8 = null;

        while (true) {
            const token = tokenizer.next() catch break;
            if (token.kind == .eof) break;

            if (token.kind == .identifier) {
                // Calculate position (tokens use 1-based, LSP uses 0-based)
                const token_line: u32 = @intCast(if (token.line > 0) token.line - 1 else 0);
                const token_col: u32 = @intCast(if (token.column > 0) token.column - 1 else 0);

                if (token_line == target_line and target_char >= token_col and target_char < token_col + token.lexeme.len) {
                    target_identifier = token.lexeme;
                    break;
                }
            }
        }

        const identifier = target_identifier orelse return null;

        // Parse the document to find definitions
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var parser = evaluator.Parser.init(arena.allocator(), text) catch return null;
        const ast = parser.parse() catch return null;

        // Search the AST for this identifier's definition location
        const def_location = try self.findDefinitionLocationInAST(ast.*, identifier);

        return def_location;
    }

    /// Compute references for an identifier at a given position
    fn computeReferences(self: *Self, text: []const u8, target_line: u32, target_char: u32) ![]DefinitionLocation {
        var references = std.ArrayList(DefinitionLocation){};
        errdefer references.deinit(self.allocator);

        // Tokenize to find all identifiers
        var tokenizer = evaluator.Tokenizer.init(text, self.allocator);
        var target_identifier: ?[]const u8 = null;

        // First pass: find the identifier at the cursor position
        while (true) {
            const token = tokenizer.next() catch break;
            if (token.kind == .eof) break;

            if (token.kind == .identifier) {
                // Calculate position (tokens use 1-based, LSP uses 0-based)
                const token_line: u32 = @intCast(if (token.line > 0) token.line - 1 else 0);
                const token_col: u32 = @intCast(if (token.column > 0) token.column - 1 else 0);

                if (token_line == target_line and target_char >= token_col and target_char < token_col + token.lexeme.len) {
                    target_identifier = token.lexeme;
                    break;
                }
            }
        }

        // If no identifier at cursor, return empty
        const target = target_identifier orelse return try references.toOwnedSlice(self.allocator);

        // Second pass: find all occurrences of this identifier
        var tokenizer2 = evaluator.Tokenizer.init(text, self.allocator);
        while (true) {
            const token = tokenizer2.next() catch break;
            if (token.kind == .eof) break;

            if (token.kind == .identifier and std.mem.eql(u8, token.lexeme, target)) {
                const token_line: u32 = @intCast(if (token.line > 0) token.line - 1 else 0);
                const token_col: u32 = @intCast(if (token.column > 0) token.column - 1 else 0);

                try references.append(self.allocator, .{
                    .start_line = token_line,
                    .start_char = token_col,
                    .end_line = token_line,
                    .end_char = @intCast(token_col + token.lexeme.len),
                });
            }
        }

        return try references.toOwnedSlice(self.allocator);
    }

    /// Definition information found in AST
    const DefinitionInfo = struct {
        doc: ?[]const u8,
        expr: *evaluator.Expression,
    };

    /// Find definition of an identifier in the AST
    fn findDefinitionInAST(self: *Self, expr: evaluator.Expression, identifier: []const u8, arena: std.mem.Allocator) !?DefinitionInfo {
        return switch (expr.data) {
            .let => |let| blk: {
                // Check if this let binding defines the identifier (simple identifier pattern only)
                if (let.pattern.data == .identifier) {
                    const pat_id = let.pattern.data.identifier;
                    if (std.mem.eql(u8, pat_id, identifier)) {
                        // Found it! Extract doc comments if any
                        const doc_copy = if (let.doc) |doc|
                            try arena.dupe(u8, doc)
                        else
                            null;

                        break :blk DefinitionInfo{
                            .doc = doc_copy,
                            .expr = let.value,
                        };
                    }
                }
                // Recursively search the body
                break :blk try self.findDefinitionInAST(let.body.*, identifier, arena);
            },
            .object => |obj| blk: {
                // Search object fields
                for (obj.fields) |field| {
                    // Check if field key matches (only static keys)
                    const key_str = switch (field.key) {
                        .static => |s| s,
                        .dynamic => continue, // Skip dynamic keys
                    };

                    if (std.mem.eql(u8, key_str, identifier)) {
                        // Found it! Return with doc comments
                        const doc_copy = if (field.doc) |doc|
                            try arena.dupe(u8, doc)
                        else
                            null;

                        break :blk DefinitionInfo{
                            .doc = doc_copy,
                            .expr = field.value,
                        };
                    }
                }
                break :blk null;
            },
            else => null,
        };
    }

    /// Find definition location of an identifier in the AST
    fn findDefinitionLocationInAST(self: *Self, expr: evaluator.Expression, identifier: []const u8) !?DefinitionLocation {
        return switch (expr.data) {
            .let => |let| blk: {
                // Check if this let binding defines the identifier (simple identifier pattern only)
                if (let.pattern.data == .identifier) {
                    const pat_id = let.pattern.data.identifier;
                    if (std.mem.eql(u8, pat_id, identifier)) {
                        // Found it! Return the pattern location
                        const loc = let.pattern.location;
                        break :blk DefinitionLocation{
                            .start_line = @intCast(if (loc.line > 0) loc.line - 1 else 0),
                            .start_char = @intCast(if (loc.column > 0) loc.column - 1 else 0),
                            .end_line = @intCast(if (loc.line > 0) loc.line - 1 else 0),
                            .end_char = @intCast((if (loc.column > 0) loc.column - 1 else 0) + loc.length),
                        };
                    }
                }
                // Recursively search the body
                break :blk try self.findDefinitionLocationInAST(let.body.*, identifier);
            },
            .object => |obj| blk: {
                // Search object fields
                for (obj.fields) |field| {
                    // Check if field key matches (only static keys)
                    const key_str = switch (field.key) {
                        .static => |s| s,
                        .dynamic => continue, // Skip dynamic keys
                    };

                    if (std.mem.eql(u8, key_str, identifier)) {
                        // Found it! We need to get the location from somewhere
                        // For now, return a location based on the field value's location
                        // This isn't perfect but better than nothing
                        // TODO: Add location tracking to ObjectField
                        break :blk null;
                    }
                }
                break :blk null;
            },
            else => null,
        };
    }
};

/// Diagnostic information for LSP
const Diagnostic = struct {
    start_line: u32,
    start_char: u32,
    end_line: u32,
    end_char: u32,
    severity: u32, // 1 = Error, 2 = Warning, 3 = Information, 4 = Hint
    message: []const u8,
};

/// Completion item for LSP
const CompletionItem = struct {
    label: []const u8,
    kind: u32, // LSP CompletionItemKind (1=Text, 3=Function, 9=Module, 14=Keyword, etc.)
    detail: ?[]const u8,
};

/// Document highlight for LSP
const DocumentHighlight = struct {
    start_line: u32,
    start_char: u32,
    end_line: u32,
    end_char: u32,
    kind: u32, // 1 = Text, 2 = Read, 3 = Write
};

/// Folding range for LSP
const FoldingRange = struct {
    start_line: u32,
    end_line: u32,
    kind: ?[]const u8, // "comment", "imports", "region", etc.
};

/// Hover information for LSP
const HoverInfo = struct {
    contents: []const u8, // Markdown formatted string
};

/// Definition location for LSP
const DefinitionLocation = struct {
    start_line: u32,
    start_char: u32,
    end_line: u32,
    end_char: u32,
};

/// Text document representation
const TextDocument = struct {
    uri: []const u8,
    text: []const u8,
    version: i32,
};
