const std = @import("std");
const lsp = @import("lsp.zig");
const json_rpc = @import("json_rpc.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Set up logging
    std.log.info("Starting Lazylang Language Server...", .{});

    // Create JSON-RPC message handler using stdin/stdout
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    var handler = json_rpc.MessageHandler.init(allocator, stdin, stdout);

    // Create and run the LSP server
    var server = try lsp.Server.init(allocator, &handler);
    defer server.deinit();

    try server.run();

    std.log.info("Lazylang Language Server stopped", .{});
}
