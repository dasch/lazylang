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
        const method = obj.get("method").?.string;

        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(id);
        } else if (std.mem.eql(u8, method, "shutdown")) {
            try self.handleShutdown(id);
        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            if (!self.initialized) {
                try self.handler.writeErrorResponse(id, json_rpc.ErrorCode.ServerNotInitialized, "Server not initialized");
                return;
            }
            try self.handleSemanticTokensFull(id, message);
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
            \\{"capabilities":{"textDocumentSync":{"openClose":true,"change":1},"semanticTokensProvider":{"legend":{"tokenTypes":["keyword","number","string","operator","variable","function","comment","namespace"],"tokenModifiers":[]},"full":true}},"serverInfo":{"name":"lazylang-lsp","version":"0.1.0"}}
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
            .l_paren, .r_paren, .l_bracket, .r_bracket, .l_brace, .r_brace => 3, // operator
            .eof => 0, // keyword (shouldn't happen)
        };
    }
};

/// Text document representation
const TextDocument = struct {
    uri: []const u8,
    text: []const u8,
    version: i32,
};
