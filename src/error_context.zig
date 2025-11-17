const std = @import("std");
const error_reporter = @import("error_reporter.zig");

/// Additional context data for specific error types
pub const ErrorData = union(enum) {
    unknown_field: struct {
        field_name: []const u8,
        available_fields: []const []const u8,
    },
    type_mismatch: struct {
        expected: []const u8,
        found: []const u8,
        operation: ?[]const u8 = null,
    },
    unknown_identifier: struct {
        name: []const u8,
    },
    unexpected_token: struct {
        expected: []const u8,
        context: []const u8,
    },
    none: void,
};

/// Thread-local error context that captures the last error location
/// This is a workaround for Zig's error system which doesn't allow attaching data to errors
pub const ErrorContext = struct {
    last_error_location: ?error_reporter.SourceLocation = null,
    last_error_token_lexeme: ?[]const u8 = null,
    last_error_data: ErrorData = .none,
    source: []const u8 = "",
    source_filename: []const u8 = "",
    /// Maps filename -> source content for all files involved (main + imports)
    source_map: std.StringHashMap([]const u8),
    /// The currently active file being parsed/evaluated
    current_file: []const u8 = "",
    /// Whether current_file is an owned copy that needs to be freed
    current_file_owned: bool = false,
    identifiers: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ErrorContext {
        return .{
            .identifiers = std.ArrayList([]const u8){},
            .source_map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ErrorContext) void {
        self.identifiers.deinit(self.allocator);

        // Free source map entries
        var it = self.source_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.source_map.deinit();

        // Free current_file if it's an owned copy
        if (self.current_file_owned and self.current_file.len > 0) {
            self.allocator.free(self.current_file);
        }

        // Free error token lexeme
        if (self.last_error_token_lexeme) |lexeme| {
            self.allocator.free(lexeme);
        }

        // Free ErrorData memory
        switch (self.last_error_data) {
            .unknown_field => |data| {
                self.allocator.free(data.field_name);
                for (data.available_fields) |field| {
                    self.allocator.free(field);
                }
                self.allocator.free(data.available_fields);
            },
            .type_mismatch => {
                // Type mismatch strings are static/const, no need to free
            },
            .unknown_identifier => |data| {
                self.allocator.free(data.name);
            },
            .unexpected_token => |data| {
                self.allocator.free(data.expected);
                self.allocator.free(data.context);
            },
            .none => {},
        }
    }

    pub fn setSource(self: *ErrorContext, source: []const u8) void {
        self.source = source;
    }

    pub fn setSourceFile(self: *ErrorContext, source: []const u8, filename: []const u8) void {
        self.source = source;
        self.source_filename = filename;
    }

    /// Register a source file in the source map (for error reporting)
    /// Makes copies of both filename and source
    pub fn registerSource(self: *ErrorContext, filename: []const u8, source: []const u8) !void {
        // Check if this filename is already registered
        if (self.source_map.get(filename)) |_| {
            // Already registered, skip to avoid duplicate allocations
            return;
        }

        // Make owned copies
        const owned_filename = try self.allocator.dupe(u8, filename);
        errdefer self.allocator.free(owned_filename);
        const owned_source = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(owned_source);

        try self.source_map.put(owned_filename, owned_source);
    }

    /// Set the currently active file being parsed/evaluated
    /// Makes a copy since the filename may be freed
    pub fn setCurrentFile(self: *ErrorContext, filename: []const u8) void {
        // Free previous owned copy if any
        if (self.current_file_owned and self.current_file.len > 0) {
            self.allocator.free(self.current_file);
            self.current_file_owned = false;
        }

        // The current_file should point to a key in our source_map which we own
        // So we don't need to copy it separately - just reference the map key
        if (self.source_map.get(filename)) |_| {
            // Find the key in the map (which is owned) and use that
            var it = self.source_map.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, filename)) {
                    self.current_file = entry.key_ptr.*;
                    self.current_file_owned = false;
                    return;
                }
            }
        }
        // If not in map yet, make a temporary copy
        // This will be overwritten when registerSource is called on error
        if (self.allocator.dupe(u8, filename)) |owned| {
            self.current_file = owned;
            self.current_file_owned = true;
        } else |_| {
            self.current_file = "";
            self.current_file_owned = false;
        }
    }

    pub fn setErrorLocation(self: *ErrorContext, line: usize, column: usize, offset: usize, length: usize) void {
        self.last_error_location = .{
            .line = line,
            .column = column,
            .offset = offset,
            .length = length,
        };
        // Capture the current file when the error occurs
        self.source_filename = self.current_file;
    }

    pub fn setErrorToken(self: *ErrorContext, lexeme: []const u8) void {
        // Make a copy of the lexeme since it may be a slice into source that gets freed
        if (self.allocator.dupe(u8, lexeme)) |owned_lexeme| {
            // Free the old lexeme if it exists
            if (self.last_error_token_lexeme) |old| {
                self.allocator.free(old);
            }
            self.last_error_token_lexeme = owned_lexeme;
        } else |_| {
            // If allocation fails, just don't set it
        }
    }

    pub fn setErrorData(self: *ErrorContext, data: ErrorData) void {
        self.last_error_data = data;
    }

    pub fn registerIdentifier(self: *ErrorContext, name: []const u8) !void {
        try self.identifiers.append(self.allocator, name);
    }

    pub fn clearError(self: *ErrorContext) void {
        self.last_error_location = null;
        self.last_error_token_lexeme = null;
        self.last_error_data = .none;
    }

    /// Find similar identifiers using Levenshtein distance
    pub fn findSimilarIdentifiers(self: *const ErrorContext, target: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.identifiers.items.len == 0) return null;

        var best_match: ?[]const u8 = null;
        var best_distance: usize = std.math.maxInt(usize);

        for (self.identifiers.items) |ident| {
            const distance = levenshteinDistance(target, ident);
            // Only suggest if distance is small relative to target length
            if (distance < best_distance and distance <= target.len / 2 + 1) {
                best_distance = distance;
                best_match = ident;
            }
        }

        if (best_match) |match| {
            return try std.fmt.allocPrint(allocator, "Did you mean `\x1b[36m{s}\x1b[0m`?", .{match});
        }

        return null;
    }
};

/// Calculate Levenshtein distance between two strings
fn levenshteinDistance(s1: []const u8, s2: []const u8) usize {
    if (s1.len == 0) return s2.len;
    if (s2.len == 0) return s1.len;

    // Use a single array for dynamic programming
    var prev_row = std.heap.page_allocator.alloc(usize, s2.len + 1) catch return std.math.maxInt(usize);
    defer std.heap.page_allocator.free(prev_row);

    var curr_row = std.heap.page_allocator.alloc(usize, s2.len + 1) catch return std.math.maxInt(usize);
    defer std.heap.page_allocator.free(curr_row);

    // Initialize first row
    for (prev_row, 0..) |*cell, j| {
        cell.* = j;
    }

    // Calculate distances
    for (s1, 0..) |c1, i| {
        curr_row[0] = i + 1;

        for (s2, 0..) |c2, j| {
            const cost: usize = if (c1 == c2) 0 else 1;
            const deletion = prev_row[j + 1] + 1;
            const insertion = curr_row[j] + 1;
            const substitution = prev_row[j] + cost;

            curr_row[j + 1] = @min(deletion, @min(insertion, substitution));
        }

        // Swap rows
        const temp = prev_row;
        prev_row = curr_row;
        curr_row = temp;
    }

    return prev_row[s2.len];
}
