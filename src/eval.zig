const std = @import("std");

pub const EvalOutput = struct {
    allocator: std.mem.Allocator,
    text: []u8,

    pub fn deinit(self: *EvalOutput) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn evalInline(allocator: std.mem.Allocator, source: []const u8) !EvalOutput {
    const copy = try allocator.dupe(u8, source);
    return .{
        .allocator = allocator,
        .text = copy,
    };
}

pub fn evalFile(allocator: std.mem.Allocator, path: []const u8) !EvalOutput {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    return try evalInline(allocator, contents);
}
