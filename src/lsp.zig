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
            .plus, .minus, .star, .ampersand, .ampersand_ampersand, .pipe_pipe, .bang => 3, // operator
            .equals_equals, .bang_equals, .less, .greater, .less_equals, .greater_equals => 3, // operator
            .dot_dot_dot => 3, // operator
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
        const uri = text_document.get("uri").?.string;

        const doc = self.documents.get(uri) orelse {
            try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.InvalidParams, "Document not found");
            return;
        };

        // Get completion items
        const items = try self.computeCompletions(doc.text);
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
    fn computeCompletions(self: *Self, text: []const u8) ![]CompletionItem {
        _ = text;
        var items = std.ArrayList(CompletionItem){};
        errdefer items.deinit(self.allocator);

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

    /// Handle textDocument/definition request
    fn handleDefinition(self: *Self, id: ?std.json.Value, message: std.json.Value) !void {
        _ = message;
        // Return null for now (no definition found)
        // TODO: Implement proper definition lookup
        try self.handler.writeResponse(id, "null");
        std.log.info("Definition request handled (not implemented)", .{});
    }

    /// Handle textDocument/hover request
    fn handleHover(self: *Self, id: ?std.json.Value, message: std.json.Value) !void {
        _ = message;
        // Return null for now (no hover info)
        // TODO: Implement hover information
        try self.handler.writeResponse(id, "null");
        std.log.info("Hover request handled (not implemented)", .{});
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
        _ = message;
        // Return empty array for now (no references)
        // TODO: Implement reference finding
        try self.handler.writeResponse(id, "[]");
        std.log.info("References request handled (not implemented)", .{});
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

/// Text document representation
const TextDocument = struct {
    uri: []const u8,
    text: []const u8,
    version: i32,
};
