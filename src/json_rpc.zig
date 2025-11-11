const std = @import("std");

/// JSON-RPC 2.0 message types
pub const MessageKind = enum {
    request,
    response,
    notification,
    error_response,
};

/// JSON-RPC 2.0 Request
pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value,
    method: []const u8,
    params: ?std.json.Value,
};

/// JSON-RPC 2.0 Response
pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value,
    result: ?std.json.Value,
};

/// JSON-RPC 2.0 Error Response
pub const ErrorResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value,
    @"error": ErrorObject,
};

/// JSON-RPC 2.0 Error Object
pub const ErrorObject = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// JSON-RPC 2.0 Notification
pub const Notification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value,
};

/// Standard JSON-RPC error codes
pub const ErrorCode = struct {
    pub const ParseError: i32 = -32700;
    pub const InvalidRequest: i32 = -32600;
    pub const MethodNotFound: i32 = -32601;
    pub const InvalidParams: i32 = -32602;
    pub const InternalError: i32 = -32603;
    pub const ServerNotInitialized: i32 = -32002;
    pub const UnknownErrorCode: i32 = -32001;
};

/// JSON-RPC message reader/writer for LSP communication
pub const MessageHandler = struct {
    allocator: std.mem.Allocator,
    stdin: std.fs.File,
    stdout: std.fs.File,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, stdin: std.fs.File, stdout: std.fs.File) Self {
        return Self{
            .allocator = allocator,
            .stdin = stdin,
            .stdout = stdout,
        };
    }

    /// Read a JSON-RPC message from the input stream
    pub fn readMessage(self: *Self) !std.json.Parsed(std.json.Value) {
        // Read headers
        var content_length: ?usize = null;
        var line_buf: [256]u8 = undefined;

        while (true) {
            // Read line byte by byte
            var line_len: usize = 0;
            while (line_len < line_buf.len) {
                var byte_buf: [1]u8 = undefined;
                const bytes_read = std.posix.read(self.stdin.handle, &byte_buf) catch |err| {
                    return err;
                };
                if (bytes_read == 0) return error.EndOfStream;

                const c = byte_buf[0];
                line_buf[line_len] = c;
                line_len += 1;

                if (c == '\n') {
                    break;
                }
            }

            const line = line_buf[0..line_len];
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

            // Empty line marks end of headers
            if (trimmed.len == 0) break;

            // Parse Content-Length header
            if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
                const value_str = std.mem.trim(u8, trimmed["Content-Length:".len..], &std.ascii.whitespace);
                content_length = std.fmt.parseInt(usize, value_str, 10) catch {
                    return error.InvalidContentLength;
                };
            }
        }

        const len = content_length orelse return error.MissingContentLength;

        // Read the JSON content
        const content = try self.allocator.alloc(u8, len);
        defer self.allocator.free(content);

        var total_read: usize = 0;
        while (total_read < len) {
            const bytes_read = std.posix.read(self.stdin.handle, content[total_read..]) catch |err| {
                return err;
            };
            if (bytes_read == 0) return error.IncompleteMessage;
            total_read += bytes_read;
        }

        // Parse JSON
        return try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{ .allocate = .alloc_always });
    }

    /// Write a JSON-RPC message to the output stream
    pub fn writeMessage(self: *Self, json_str: []const u8) !void {
        // Write headers
        const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {d}\r\n\r\n", .{json_str.len});
        defer self.allocator.free(header);

        _ = try std.posix.write(self.stdout.handle, header);
        _ = try std.posix.write(self.stdout.handle, json_str);
    }

    /// Write a JSON-RPC response - for now just write simple responses
    pub fn writeResponse(self: *Self, id: ?std.json.Value, result_json: []const u8) !void {
        const id_str = if (id) |val|
            if (val == .integer)
                try std.fmt.allocPrint(self.allocator, "{d}", .{val.integer})
            else
                try std.fmt.allocPrint(self.allocator, "null", .{})
        else
            try std.fmt.allocPrint(self.allocator, "null", .{});
        defer self.allocator.free(id_str);

        const json_str = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
            .{ id_str, result_json },
        );
        defer self.allocator.free(json_str);

        try self.writeMessage(json_str);
    }

    /// Write a JSON-RPC error response
    pub fn writeErrorResponse(self: *Self, id: ?std.json.Value, code: i32, message: []const u8) !void {
        const id_str = if (id) |val|
            if (val == .integer)
                try std.fmt.allocPrint(self.allocator, "{d}", .{val.integer})
            else
                try std.fmt.allocPrint(self.allocator, "null", .{})
        else
            try std.fmt.allocPrint(self.allocator, "null", .{});
        defer self.allocator.free(id_str);

        const json_str = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
            .{ id_str, code, message },
        );
        defer self.allocator.free(json_str);

        try self.writeMessage(json_str);
    }
};

/// Parse a message and determine its type
pub fn parseMessageKind(value: std.json.Value) !MessageKind {
    if (value != .object) return error.InvalidMessage;

    const obj = value.object;

    // Check for required "jsonrpc" field
    const jsonrpc = obj.get("jsonrpc") orelse return error.MissingJsonRpcVersion;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.InvalidJsonRpcVersion;
    }

    const has_id = obj.contains("id");
    const has_method = obj.contains("method");
    const has_result = obj.contains("result");
    const has_error = obj.contains("error");

    if (has_method and has_id) {
        return .request;
    } else if (has_method and !has_id) {
        return .notification;
    } else if (has_error and has_id) {
        return .error_response;
    } else if (has_result and has_id) {
        return .response;
    }

    return error.InvalidMessage;
}

test "parseMessageKind identifies request" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "id": 1, "method": "test", "params": {}}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const kind = try parseMessageKind(parsed.value);
    try std.testing.expectEqual(MessageKind.request, kind);
}

test "parseMessageKind identifies notification" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "method": "test", "params": {}}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const kind = try parseMessageKind(parsed.value);
    try std.testing.expectEqual(MessageKind.notification, kind);
}

test "parseMessageKind identifies response" {
    const allocator = std.testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "id": 1, "result": {}}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const kind = try parseMessageKind(parsed.value);
    try std.testing.expectEqual(MessageKind.response, kind);
}
