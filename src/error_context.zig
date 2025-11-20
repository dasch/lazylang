//! Error context tracking for detailed error messages.
//!
//! Zig's error system doesn't allow attaching data to errors, so this module
//! provides a workaround by storing error context in a separate structure.
//!
//! Key features:
//! - Source location tracking (line, column, offset, length)
//! - Secondary location support for multi-location errors (e.g., cyclic refs)
//! - Error-specific data (unknown field names, type mismatches, etc.)
//! - Source file mapping for multi-file error reporting
//! - Identifier registry for "did you mean" suggestions
//! - Levenshtein distance for fuzzy identifier matching
//!
//! Usage pattern:
//!   1. Create ErrorContext at start of parsing/evaluation
//!   2. Call setErrorLocation() before returning an error
//!   3. Call setErrorData() to attach error-specific information
//!   4. Error reporter reads context to generate helpful messages
//!
//! The context is passed through the call stack and updated at error sites
//! to provide precise location information and helpful suggestions.

const std = @import("std");
const error_reporter = @import("error_reporter.zig");

/// A single stack frame in the call stack
pub const StackFrame = struct {
    function_name: ?[]const u8,
    location: error_reporter.SourceLocation,
    filename: []const u8,
    is_native: bool,

    pub fn init(
        function_name: ?[]const u8,
        filename: []const u8,
        line: usize,
        column: usize,
        offset: usize,
        length: usize,
        is_native: bool,
    ) StackFrame {
        return .{
            .function_name = function_name,
            .location = .{
                .line = line,
                .column = column,
                .offset = offset,
                .length = length,
            },
            .filename = filename,
            .is_native = is_native,
        };
    }
};

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
    module_not_found: struct {
        module_name: []const u8,
    },
    none: void,
};

/// Thread-local error context that captures the last error location
/// This is a workaround for Zig's error system which doesn't allow attaching data to errors
pub const ErrorContext = struct {
    last_error_location: ?error_reporter.SourceLocation = null,
    last_error_secondary_location: ?error_reporter.SourceLocation = null,
    last_error_location_label: ?[]const u8 = null,
    last_error_secondary_label: ?[]const u8 = null,
    last_error_token_lexeme: ?[]const u8 = null,
    last_error_data: ErrorData = .none,
    source: []const u8 = "",
    source_filename: []const u8 = "",
    /// Whether source_filename is an owned copy that needs to be freed
    source_filename_owned: bool = false,
    /// Maps filename -> source content for all files involved (main + imports)
    source_map: std.StringHashMap([]const u8),
    /// The currently active file being parsed/evaluated
    current_file: []const u8 = "",
    /// Whether current_file is an owned copy that needs to be freed
    current_file_owned: bool = false,
    identifiers: std.ArrayList([]const u8),
    /// Call stack for runtime error traces
    call_stack: std.ArrayList(StackFrame),
    /// Captured stack trace at the time of error
    stack_trace: ?[]StackFrame = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ErrorContext {
        return .{
            .identifiers = std.ArrayList([]const u8){},
            .source_map = std.StringHashMap([]const u8).init(allocator),
            .call_stack = std.ArrayList(StackFrame){},
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

        // Free source_filename if it's an owned copy
        if (self.source_filename_owned and self.source_filename.len > 0) {
            self.allocator.free(self.source_filename);
        }

        // Free error token lexeme
        if (self.last_error_token_lexeme) |lexeme| {
            self.allocator.free(lexeme);
        }

        // Free ErrorData memory
        self.freeErrorData();

        // Free call stack
        self.call_stack.deinit(self.allocator);

        // Free captured stack trace
        if (self.stack_trace) |trace| {
            for (trace) |frame| {
                if (frame.function_name) |name| {
                    self.allocator.free(name);
                }
                self.allocator.free(frame.filename);
            }
            self.allocator.free(trace);
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
    /// Always makes an owned copy to avoid dangling pointers if HashMap reallocates
    pub fn setCurrentFile(self: *ErrorContext, filename: []const u8) void {
        // Free previous owned copy if any
        if (self.current_file_owned and self.current_file.len > 0) {
            self.allocator.free(self.current_file);
            self.current_file_owned = false;
        }

        // Always make an owned copy, even if the filename is in the source_map
        // This is necessary because HashMap can reallocate and invalidate key pointers
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
        // Capture the current file when the error occurs - make a copy to avoid dangling pointer
        if (self.source_filename_owned and self.source_filename.len > 0) {
            self.allocator.free(self.source_filename);
            self.source_filename_owned = false;
        }
        if (self.allocator.dupe(u8, self.current_file)) |owned| {
            self.source_filename = owned;
            self.source_filename_owned = true;
        } else |_| {
            // If allocation fails, just use the pointer (better than crashing)
            self.source_filename = self.current_file;
            self.source_filename_owned = false;
        }
    }

    pub fn setErrorLocationWithLabels(
        self: *ErrorContext,
        line: usize,
        column: usize,
        offset: usize,
        length: usize,
        label: []const u8,
        secondary_line: usize,
        secondary_column: usize,
        secondary_offset: usize,
        secondary_length: usize,
        secondary_label: []const u8,
    ) void {
        self.last_error_location = .{
            .line = line,
            .column = column,
            .offset = offset,
            .length = length,
        };
        self.last_error_secondary_location = .{
            .line = secondary_line,
            .column = secondary_column,
            .offset = secondary_offset,
            .length = secondary_length,
        };
        self.last_error_location_label = label;
        self.last_error_secondary_label = secondary_label;
        // Capture the current file when the error occurs - make a copy to avoid dangling pointer
        if (self.source_filename_owned and self.source_filename.len > 0) {
            self.allocator.free(self.source_filename);
            self.source_filename_owned = false;
        }
        if (self.allocator.dupe(u8, self.current_file)) |owned| {
            self.source_filename = owned;
            self.source_filename_owned = true;
        } else |_| {
            // If allocation fails, just use the pointer (better than crashing)
            self.source_filename = self.current_file;
            self.source_filename_owned = false;
        }
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
        // Free old error data before setting new data
        self.freeErrorData();
        self.last_error_data = data;
    }

    fn freeErrorData(self: *ErrorContext) void {
        switch (self.last_error_data) {
            .unknown_field => |old_data| {
                self.allocator.free(old_data.field_name);
                for (old_data.available_fields) |field| {
                    self.allocator.free(field);
                }
                self.allocator.free(old_data.available_fields);
            },
            .unknown_identifier => |old_data| {
                self.allocator.free(old_data.name);
            },
            .unexpected_token => |old_data| {
                self.allocator.free(old_data.expected);
                self.allocator.free(old_data.context);
            },
            .module_not_found => |old_data| {
                self.allocator.free(old_data.module_name);
            },
            .type_mismatch => |old_data| {
                // The expected and found strings are usually from formatPatternValue/formatValueShort
                // which use page_allocator, so we don't free them here (they're leaked but acceptable)
                // However, the operation string might be allocated with err_ctx.allocator if it's
                // a custom operation like "calling function `f`"
                if (old_data.operation) |op| {
                    // Only free if it starts with "calling function" (our custom allocations)
                    if (std.mem.startsWith(u8, op, "calling function `")) {
                        self.allocator.free(op);
                    }
                }
            },
            .none => {},
        }
    }

    pub fn registerIdentifier(self: *ErrorContext, name: []const u8) !void {
        try self.identifiers.append(self.allocator, name);
    }

    pub fn clearError(self: *ErrorContext) void {
        self.last_error_location = null;
        self.last_error_secondary_location = null;
        self.last_error_location_label = null;
        self.last_error_secondary_label = null;
        self.last_error_token_lexeme = null;
        self.last_error_data = .none;

        // Clear source_filename if it's owned
        if (self.source_filename_owned and self.source_filename.len > 0) {
            self.allocator.free(self.source_filename);
            self.source_filename = "";
            self.source_filename_owned = false;
        }

        // Clear stack trace
        if (self.stack_trace) |trace| {
            for (trace) |frame| {
                if (frame.function_name) |name| {
                    self.allocator.free(name);
                }
                self.allocator.free(frame.filename);
            }
            self.allocator.free(trace);
            self.stack_trace = null;
        }
    }

    /// Push a stack frame onto the call stack
    pub fn pushStackFrame(
        self: *ErrorContext,
        function_name: ?[]const u8,
        filename: []const u8,
        line: usize,
        column: usize,
        offset: usize,
        length: usize,
        is_native: bool,
    ) !void {
        const frame = StackFrame.init(function_name, filename, line, column, offset, length, is_native);
        try self.call_stack.append(self.allocator, frame);
    }

    /// Pop a stack frame from the call stack
    pub fn popStackFrame(self: *ErrorContext) void {
        if (self.call_stack.items.len > 0) {
            _ = self.call_stack.pop();
        }
    }

    /// Capture the current call stack as a stack trace
    /// Makes deep copies of all strings so they remain valid after arena deallocation
    pub fn captureStackTrace(self: *ErrorContext) !void {
        // Free old stack trace if any
        if (self.stack_trace) |old_trace| {
            // Free the strings in the old trace
            for (old_trace) |frame| {
                if (frame.function_name) |name| {
                    self.allocator.free(name);
                }
                self.allocator.free(frame.filename);
            }
            self.allocator.free(old_trace);
        }

        // Make a deep copy of the current call stack
        if (self.call_stack.items.len > 0) {
            const frames = try self.allocator.alloc(StackFrame, self.call_stack.items.len);
            for (self.call_stack.items, 0..) |src_frame, i| {
                frames[i] = StackFrame{
                    .function_name = if (src_frame.function_name) |name|
                        try self.allocator.dupe(u8, name)
                    else
                        null,
                    .location = src_frame.location,
                    .filename = try self.allocator.dupe(u8, src_frame.filename),
                    .is_native = src_frame.is_native,
                };
            }
            self.stack_trace = frames;
        } else {
            self.stack_trace = null;
        }
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
