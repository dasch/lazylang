const std = @import("std");
const testing = std.testing;

/// Simple LSP client for testing the Language Server
const LspClient = struct {
    process: std.process.Child,
    allocator: std.mem.Allocator,
    next_id: i32 = 1,

    const Self = @This();

    /// Initialize a new LSP client connected to the server
    pub fn init(allocator: std.mem.Allocator, server_path: []const u8) !Self {
        var process = std.process.Child.init(&.{server_path}, allocator);
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe;

        try process.spawn();

        return Self{
            .process = process,
            .allocator = allocator,
        };
    }

    /// Send a JSON-RPC request and return the response
    pub fn sendRequest(self: *Self, method: []const u8, params: anytype) !std.json.Value {
        const id = self.next_id;
        self.next_id += 1;

        // Build the JSON-RPC request
        var request = std.json.ObjectMap.init(self.allocator);
        defer request.deinit();

        try request.put("jsonrpc", .{ .string = "2.0" });
        try request.put("id", .{ .integer = id });
        try request.put("method", .{ .string = method });

        // Serialize params
        const params_json = try std.json.stringifyAlloc(self.allocator, params, .{});
        defer self.allocator.free(params_json);

        var parsed_params = try std.json.parseFromSlice(std.json.Value, self.allocator, params_json, .{});
        defer parsed_params.deinit();

        try request.put("params", parsed_params.value);

        // Serialize the request
        const request_json = try std.json.stringifyAlloc(self.allocator, std.json.Value{ .object = request }, .{});
        defer self.allocator.free(request_json);

        // Send with Content-Length header
        const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{request_json.len});
        defer self.allocator.free(header);

        try self.process.stdin.?.writeAll(header);
        try self.process.stdin.?.writeAll(request_json);

        // Read response
        return try self.readResponse();
    }

    /// Send a JSON-RPC notification (no response expected)
    pub fn sendNotification(self: *Self, method: []const u8, params: anytype) !void {
        var request = std.json.ObjectMap.init(self.allocator);
        defer request.deinit();

        try request.put("jsonrpc", .{ .string = "2.0" });
        try request.put("method", .{ .string = method });

        const params_json = try std.json.stringifyAlloc(self.allocator, params, .{});
        defer self.allocator.free(params_json);

        var parsed_params = try std.json.parseFromSlice(std.json.Value, self.allocator, params_json, .{});
        defer parsed_params.deinit();

        try request.put("params", parsed_params.value);

        const request_json = try std.json.stringifyAlloc(self.allocator, std.json.Value{ .object = request }, .{});
        defer self.allocator.free(request_json);

        const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{request_json.len});
        defer self.allocator.free(header);

        try self.process.stdin.?.writeAll(header);
        try self.process.stdin.?.writeAll(request_json);
    }

    /// Read a JSON-RPC response from the server
    fn readResponse(self: *Self) !std.json.Value {
        // Read Content-Length header
        var content_length: usize = 0;
        var line_buf: [256]u8 = undefined;

        while (true) {
            const line = try self.process.stdout.?.reader().readUntilDelimiter(&line_buf, '\n');
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

            if (trimmed.len == 0) break; // Empty line separates headers from content

            if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
                const value_str = std.mem.trim(u8, trimmed["Content-Length:".len..], &std.ascii.whitespace);
                content_length = try std.fmt.parseInt(usize, value_str, 10);
            }
        }

        if (content_length == 0) {
            return error.InvalidResponse;
        }

        // Read the JSON content
        const content = try self.allocator.alloc(u8, content_length);
        defer self.allocator.free(content);

        const bytes_read = try self.process.stdout.?.readAll(content);
        if (bytes_read != content_length) {
            return error.IncompleteResponse;
        }

        // Parse JSON
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        // Note: caller is responsible for calling deinit on the returned value
        return parsed.value;
    }

    /// Shutdown and cleanup the client
    pub fn deinit(self: *Self) void {
        _ = self.process.kill() catch {};
        self.process.stdin = null;
        self.process.stdout = null;
        self.process.stderr = null;
    }
};

test "LSP initialization sequence" {
    const allocator = testing.allocator;

    // TODO: Build the LSP server first
    // For now, this test will be skipped
    if (true) return error.SkipZigTest;

    var client = try LspClient.init(allocator, "./bin/lazy-lsp");
    defer client.deinit();

    // Send initialize request
    const init_params = .{
        .processId = null,
        .rootUri = null,
        .capabilities = .{},
    };

    const response = try client.sendRequest("initialize", init_params);
    defer response.deinit();

    // Verify response
    try testing.expect(response == .object);
    const result = response.object.get("result").?;
    try testing.expect(result == .object);

    // Verify capabilities
    const capabilities = result.object.get("capabilities").?;
    try testing.expect(capabilities == .object);

    // Send initialized notification
    try client.sendNotification("initialized", .{});

    // Send shutdown request
    const shutdown_response = try client.sendRequest("shutdown", .{});
    defer shutdown_response.deinit();

    // Send exit notification
    try client.sendNotification("exit", .{});
}

test "LSP semantic tokens for syntax highlighting" {
    const allocator = testing.allocator;

    // TODO: Build the LSP server first
    if (true) return error.SkipZigTest;

    var client = try LspClient.init(allocator, "./bin/lazy-lsp");
    defer client.deinit();

    // Initialize
    const init_params = .{
        .processId = null,
        .rootUri = null,
        .capabilities = .{
            .textDocument = .{
                .semanticTokens = .{
                    .dynamicRegistration = false,
                },
            },
        },
    };

    const init_response = try client.sendRequest("initialize", init_params);
    defer init_response.deinit();

    try client.sendNotification("initialized", .{});

    // Open a document
    const doc_uri = "file:///test.lazy";
    const doc_text = "let x = 42;";

    const did_open_params = .{
        .textDocument = .{
            .uri = doc_uri,
            .languageId = "lazylang",
            .version = 1,
            .text = doc_text,
        },
    };

    try client.sendNotification("textDocument/didOpen", did_open_params);

    // Request semantic tokens
    const semantic_tokens_params = .{
        .textDocument = .{
            .uri = doc_uri,
        },
    };

    const tokens_response = try client.sendRequest("textDocument/semanticTokens/full", semantic_tokens_params);
    defer tokens_response.deinit();

    // Verify we got semantic tokens back
    try testing.expect(tokens_response == .object);
    const result = tokens_response.object.get("result").?;
    try testing.expect(result == .object);

    const data = result.object.get("data").?;
    try testing.expect(data == .array);
    try testing.expect(data.array.items.len > 0);

    // Cleanup
    const shutdown_response = try client.sendRequest("shutdown", .{});
    defer shutdown_response.deinit();

    try client.sendNotification("exit", .{});
}

test "LSP diagnostics for syntax errors" {
    const allocator = testing.allocator;

    // TODO: Build the LSP server first
    if (true) return error.SkipZigTest;

    var client = try LspClient.init(allocator, "./bin/lazy-lsp");
    defer client.deinit();

    // Initialize
    const init_params = .{
        .processId = null,
        .rootUri = null,
        .capabilities = .{},
    };

    const init_response = try client.sendRequest("initialize", init_params);
    defer init_response.deinit();

    try client.sendNotification("initialized", .{});

    // Open a document with a syntax error
    const doc_uri = "file:///test.lazy";
    const doc_text = "let x = ; // Missing value - syntax error";

    const did_open_params = .{
        .textDocument = .{
            .uri = doc_uri,
            .languageId = "lazylang",
            .version = 1,
            .text = doc_text,
        },
    };

    try client.sendNotification("textDocument/didOpen", did_open_params);

    // Note: In a real test, we'd need to read the publishDiagnostics notification
    // For now, we just verify the server doesn't crash

    // Cleanup
    const shutdown_response = try client.sendRequest("shutdown", .{});
    defer shutdown_response.deinit();

    try client.sendNotification("exit", .{});
}

test "LSP diagnostics clear for valid code" {
    const allocator = testing.allocator;

    // TODO: Build the LSP server first
    if (true) return error.SkipZigTest;

    var client = try LspClient.init(allocator, "./bin/lazy-lsp");
    defer client.deinit();

    // Initialize
    const init_params = .{
        .processId = null,
        .rootUri = null,
        .capabilities = .{},
    };

    const init_response = try client.sendRequest("initialize", init_params);
    defer init_response.deinit();

    try client.sendNotification("initialized", .{});

    // Open a document with valid code
    const doc_uri = "file:///test.lazy";
    const doc_text = "let x = 42; x + 1";

    const did_open_params = .{
        .textDocument = .{
            .uri = doc_uri,
            .languageId = "lazylang",
            .version = 1,
            .text = doc_text,
        },
    };

    try client.sendNotification("textDocument/didOpen", did_open_params);

    // Note: Should publish empty diagnostics array

    // Cleanup
    const shutdown_response2 = try client.sendRequest("shutdown", .{});
    defer shutdown_response2.deinit();

    try client.sendNotification("exit", .{});
}

test "LSP code completion for keywords" {
    const allocator = testing.allocator;

    // TODO: Build the LSP server first
    if (true) return error.SkipZigTest;

    var client = try LspClient.init(allocator, "./bin/lazy-lsp");
    defer client.deinit();

    // Initialize
    const init_params = .{
        .processId = null,
        .rootUri = null,
        .capabilities = .{
            .textDocument = .{
                .completion = .{
                    .dynamicRegistration = false,
                },
            },
        },
    };

    const init_response = try client.sendRequest("initialize", init_params);
    defer init_response.deinit();

    try client.sendNotification("initialized", .{});

    // Open a document
    const doc_uri = "file:///test.lazy";
    const doc_text = "let x = 42";

    const did_open_params = .{
        .textDocument = .{
            .uri = doc_uri,
            .languageId = "lazylang",
            .version = 1,
            .text = doc_text,
        },
    };

    try client.sendNotification("textDocument/didOpen", did_open_params);

    // Request completions
    const completion_params = .{
        .textDocument = .{
            .uri = doc_uri,
        },
        .position = .{
            .line = 0,
            .character = 0,
        },
    };

    const completion_response = try client.sendRequest("textDocument/completion", completion_params);
    defer completion_response.deinit();

    // Verify we got completion items
    try testing.expect(completion_response == .object);
    const result = completion_response.object.get("result").?;
    try testing.expect(result == .object);
    const items = result.object.get("items").?;
    try testing.expect(items == .array);
    try testing.expect(items.array.items.len > 0);

    // Cleanup
    const shutdown_response = try client.sendRequest("shutdown", .{});
    defer shutdown_response.deinit();

    try client.sendNotification("exit", .{});
}

test "LSP document highlights for identifiers" {
    const allocator = testing.allocator;

    // TODO: Build the LSP server first
    if (true) return error.SkipZigTest;

    var client = try LspClient.init(allocator, "./bin/lazy-lsp");
    defer client.deinit();

    // Initialize
    const init_params = .{
        .processId = null,
        .rootUri = null,
        .capabilities = .{},
    };

    const init_response = try client.sendRequest("initialize", init_params);
    defer init_response.deinit();

    try client.sendNotification("initialized", .{});

    // Open a document with repeated identifiers
    const doc_uri = "file:///test.lazy";
    const doc_text = "let x = 5; x + x";

    const did_open_params = .{
        .textDocument = .{
            .uri = doc_uri,
            .languageId = "lazylang",
            .version = 1,
            .text = doc_text,
        },
    };

    try client.sendNotification("textDocument/didOpen", did_open_params);

    // Request highlights for 'x' at position (0, 4)
    const highlight_params = .{
        .textDocument = .{
            .uri = doc_uri,
        },
        .position = .{
            .line = 0,
            .character = 4,
        },
    };

    const highlight_response = try client.sendRequest("textDocument/documentHighlight", highlight_params);
    defer highlight_response.deinit();

    // Verify we got highlights
    try testing.expect(highlight_response == .object);
    const result = highlight_response.object.get("result").?;
    try testing.expect(result == .array);
    // Should highlight 3 occurrences of 'x'
    try testing.expect(result.array.items.len == 3);

    // Cleanup
    const shutdown_response = try client.sendRequest("shutdown", .{});
    defer shutdown_response.deinit();

    try client.sendNotification("exit", .{});
}

test "LSP folding ranges for code blocks" {
    const allocator = testing.allocator;

    // TODO: Build the LSP server first
    if (true) return error.SkipZigTest;

    var client = try LspClient.init(allocator, "./bin/lazy-lsp");
    defer client.deinit();

    // Initialize
    const init_params = .{
        .processId = null,
        .rootUri = null,
        .capabilities = .{},
    };

    const init_response = try client.sendRequest("initialize", init_params);
    defer init_response.deinit();

    try client.sendNotification("initialized", .{});

    // Open a document with foldable regions
    const doc_uri = "file:///test.lazy";
    const doc_text =
        \\{
        \\  x: 1,
        \\  y: {
        \\    a: 2,
        \\    b: 3
        \\  },
        \\  z: [
        \\    1,
        \\    2,
        \\    3
        \\  ]
        \\}
    ;

    const did_open_params = .{
        .textDocument = .{
            .uri = doc_uri,
            .languageId = "lazylang",
            .version = 1,
            .text = doc_text,
        },
    };

    try client.sendNotification("textDocument/didOpen", did_open_params);

    // Request folding ranges
    const folding_params = .{
        .textDocument = .{
            .uri = doc_uri,
        },
    };

    const folding_response = try client.sendRequest("textDocument/foldingRange", folding_params);
    defer folding_response.deinit();

    // Verify we got folding ranges
    try testing.expect(folding_response == .object);
    const result = folding_response.object.get("result").?;
    try testing.expect(result == .array);
    // Should have 3 folding ranges: outer object, nested object, array
    try testing.expect(result.array.items.len == 3);

    // Cleanup
    const shutdown_response = try client.sendRequest("shutdown", .{});
    defer shutdown_response.deinit();

    try client.sendNotification("exit", .{});
}
