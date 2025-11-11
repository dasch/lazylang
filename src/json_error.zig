const std = @import("std");
const error_reporter = @import("error_reporter.zig");
const error_context = @import("error_context.zig");

/// JSON error format for IDE integration
pub fn reportErrorAsJson(
    writer: anytype,
    filename: []const u8,
    err_ctx: *const error_context.ErrorContext,
    error_type: []const u8,
    message: []const u8,
    suggestion: ?[]const u8,
) !void {
    try writer.writeAll("{");

    // Error type
    try writer.writeAll("\"type\":\"");
    try writer.writeAll(error_type);
    try writer.writeAll("\",");

    // Message
    try writer.writeAll("\"message\":\"");
    try writeJsonString(writer, message);
    try writer.writeAll("\",");

    // Location
    if (err_ctx.last_error_location) |loc| {
        try writer.writeAll("\"location\":{");
        try writer.print("\"file\":\"{s}\",", .{filename});
        try writer.print("\"line\":{d},", .{loc.line});
        try writer.print("\"column\":{d},", .{loc.column});
        try writer.print("\"offset\":{d},", .{loc.offset});
        try writer.print("\"length\":{d}", .{loc.length});
        try writer.writeAll("},");
    } else {
        try writer.writeAll("\"location\":null,");
    }

    // Suggestion
    if (suggestion) |sugg| {
        try writer.writeAll("\"suggestion\":\"");
        try writeJsonString(writer, sugg);
        try writer.writeAll("\"");
    } else {
        try writer.writeAll("\"suggestion\":null");
    }

    try writer.writeAll("}\n");
}

/// Write a string with JSON escaping
fn writeJsonString(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 32) {
                try writer.print("\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            },
        }
    }
}
