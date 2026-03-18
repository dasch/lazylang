const std = @import("std");
const eval = @import("evaluator");
const testing = std.testing;

const ErrorData = eval.ErrorData;

// Helper to expect an error with a specific type
fn expectError(source: []const u8, expected_error: anyerror) !void {
    var result = try eval.evalInlineWithContext(testing.allocator, source);
    defer result.deinit();

    if (result.err) |err| {
        try testing.expectEqual(expected_error, err);
    } else {
        std.debug.print("\nExpected error {}, but evaluation succeeded with: {s}\n", .{ expected_error, result.output.?.text });
        return error.TestExpectedError;
    }
}

// Helper to expect an error and verify the error data content
fn expectErrorWithData(source: []const u8, expected_error: anyerror, check: fn (ErrorData) anyerror!void) !void {
    var result = try eval.evalInlineWithContext(testing.allocator, source);
    defer result.deinit();

    if (result.err) |err| {
        try testing.expectEqual(expected_error, err);
        try check(result.error_ctx.last_error_data);
    } else {
        std.debug.print("\nExpected error {}, but evaluation succeeded with: {s}\n", .{ expected_error, result.output.?.text });
        return error.TestExpectedError;
    }
}

// ============================================================================
// TOKENIZER/PARSER ERROR TESTS
// ============================================================================

test "error: unterminated string" {
    try expectError(
        \\"hello
    , error.UnterminatedString);
}

test "error: unterminated string with newlines" {
    try expectError(
        \\x = 10
        \\"hello
        \\y = 20
    , error.UnterminatedString);
}

test "error: unexpected character" {
    try expectError("x = 5 @ 3", error.UnexpectedCharacter);
}

test "error: missing operand" {
    try expectError("x = 5 +", error.ExpectedExpression);
}

test "error: unexpected closing paren" {
    try expectError("x = 5 + )", error.ExpectedExpression);
}

test "error: missing closing paren" {
    try expectError("x = (5 + 3", error.UnexpectedToken);
}

test "error: missing closing bracket" {
    try expectError("x = [1, 2, 3", error.UnexpectedToken);
}

test "error: missing closing brace" {
    try expectError("obj = { x: 1, y: 2", error.UnexpectedToken);
}

test "error: unexpected token after let" {
    try expectError("let 123 = 5; x", error.UnexpectedToken);
}

// ============================================================================
// UNKNOWN IDENTIFIER - with content checks
// ============================================================================

test "error: unknown identifier reports the name" {
    try expectErrorWithData("unknownVar", error.UnknownIdentifier, struct {
        fn check(data: ErrorData) !void {
            switch (data) {
                .unknown_identifier => |id| {
                    try testing.expectEqualStrings("unknownVar", id.name);
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }.check);
}

test "error: unknown identifier in expression reports the name" {
    try expectErrorWithData(
        \\x = 10
        \\y = unknownVar + x
        \\y
    , error.UnknownIdentifier, struct {
        fn check(data: ErrorData) !void {
            switch (data) {
                .unknown_identifier => |id| {
                    try testing.expectEqualStrings("unknownVar", id.name);
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }.check);
}

test "error: unknown identifier in nested scope reports the name" {
    try expectErrorWithData(
        \\f = x -> unknownNested + x
        \\f 5
    , error.UnknownIdentifier, struct {
        fn check(data: ErrorData) !void {
            switch (data) {
                .unknown_identifier => |id| {
                    try testing.expectEqualStrings("unknownNested", id.name);
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }.check);
}

test "error: unknown identifier in object field" {
    try expectError(
        \\obj = { x: unknownVar }
        \\obj.x
    , error.UnknownIdentifier);
}

test "error: unknown identifier in array" {
    try expectError(
        \\arr = [1, 2, unknownVar, 4]
        \\arr
    , error.UnknownIdentifier);
}

// ============================================================================
// TYPE MISMATCH - with content checks
// ============================================================================

test "error: add number and string reports types" {
    try expectErrorWithData("5 + \"hello\"", error.TypeMismatch, struct {
        fn check(data: ErrorData) !void {
            switch (data) {
                .type_mismatch => |tm| {
                    try testing.expectEqualStrings("integer", tm.expected);
                    try testing.expectEqualStrings("string", tm.found);
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }.check);
}

test "error: add number and boolean" {
    try expectError("5 + true", error.TypeMismatch);
}

test "error: multiply string reports types" {
    try expectErrorWithData("\"hello\" * 5", error.TypeMismatch, struct {
        fn check(data: ErrorData) !void {
            switch (data) {
                .type_mismatch => |tm| {
                    try testing.expectEqualStrings("integer", tm.expected);
                    try testing.expectEqualStrings("string", tm.found);
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }.check);
}

test "error: subtract incompatible types" {
    try expectError("10 - \"five\"", error.TypeMismatch);
}

test "error: comparison of incompatible types" {
    try expectError("5 < \"hello\"", error.TypeMismatch);
}

test "error: logical and with non-boolean" {
    try expectError("true && 5", error.TypeMismatch);
}

test "error: logical or with non-boolean" {
    try expectError("false || \"yes\"", error.TypeMismatch);
}

test "error: not on non-boolean" {
    try expectError("!5", error.TypeMismatch);
}

test "error: negate string" {
    try expectError("-\"hello\"", error.ExpectedExpression);
}

// ============================================================================
// FUNCTION APPLICATION ERRORS
// ============================================================================

test "error: not a function - integer" {
    try expectError(
        \\x = 42
        \\x 10
    , error.ExpectedFunction);
}

test "error: not a function - string" {
    try expectError("\"hello\" \"world\"", error.ExpectedFunction);
}

test "error: not a function - array" {
    try expectError(
        \\arr = [1, 2, 3]
        \\arr 1
    , error.ExpectedFunction);
}

test "error: not a function - object" {
    try expectError(
        \\obj = { x: 5 }
        \\obj 10
    , error.ExpectedFunction);
}

// ============================================================================
// FIELD ACCESS ERRORS - with content checks
// ============================================================================

test "error: unknown field reports field name and available fields" {
    try expectErrorWithData(
        \\obj = { x: 1 }
        \\obj.y
    , error.UnknownField, struct {
        fn check(data: ErrorData) !void {
            switch (data) {
                .unknown_field => |uf| {
                    try testing.expectEqualStrings("y", uf.field_name);
                    try testing.expect(uf.available_fields.len > 0);
                    try testing.expectEqualStrings("x", uf.available_fields[0]);
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }.check);
}

test "error: unknown field with multiple available fields" {
    try expectError(
        \\obj = { name: "Alice", age: 30, city: "NYC" }
        \\obj.unknownField
    , error.UnknownField);
}

test "error: unknown field on empty object" {
    try expectErrorWithData(
        \\obj = {}
        \\obj.x
    , error.UnknownField, struct {
        fn check(data: ErrorData) !void {
            switch (data) {
                .unknown_field => |uf| {
                    try testing.expectEqualStrings("x", uf.field_name);
                    try testing.expect(uf.available_fields.len == 0);
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }.check);
}

test "error: unknown field nested" {
    try expectError(
        \\obj = { inner: { x: 1 } }
        \\obj.inner.y
    , error.UnknownField);
}

test "error: field access on non-object" {
    try expectError(
        \\f = x -> x.field
        \\f "hello"
    , error.TypeMismatch);
}

test "error: field access on integer" {
    try expectError(
        \\f = x -> x.value
        \\f 42
    , error.TypeMismatch);
}

test "error: field access on boolean" {
    try expectError(
        \\f = x -> x.status
        \\f true
    , error.TypeMismatch);
}

// ============================================================================
// MODULE/IMPORT ERRORS - with content checks
// ============================================================================

test "error: module not found reports module name" {
    try expectErrorWithData("import 'NonExistentModule'", error.ModuleNotFound, struct {
        fn check(data: ErrorData) !void {
            switch (data) {
                .module_not_found => |mf| {
                    try testing.expectEqualStrings("NonExistentModule", mf.module_name);
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }.check);
}

test "error: module not found relative path" {
    try expectError("import './does_not_exist'", error.ModuleNotFound);
}

// ============================================================================
// PATTERN MATCHING ERRORS
// ============================================================================

test "error: pattern mismatch - tuple length" {
    try expectError(
        \\f = (x, y, z) -> x + y + z
        \\f (1, 2)
    , error.TypeMismatch);
}

test "error: pattern mismatch - tuple value" {
    try expectError("when (1, 2) matches (1, 3) then 0", error.TypeMismatch);
}

test "error: pattern mismatch - array length" {
    try expectError(
        \\[x, y, z] = [1, 2]
        \\x
    , error.TypeMismatch);
}

test "error: pattern mismatch - array value" {
    try expectError(
        \\[1, 2, 3] = [1, 3, 3]
        \\0
    , error.TypeMismatch);
}

test "error: pattern mismatch - object missing field" {
    try expectError(
        \\{ x, y } = { x: 1 }
        \\x
    , error.TypeMismatch);
}

test "error: pattern mismatch - object field value" {
    try expectError(
        \\{ x: 1, y } = { x: 2, y: 3 }
        \\y
    , error.TypeMismatch);
}

test "error: pattern mismatch - wrong type for array" {
    try expectError(
        \\[x, y] = 42
        \\x
    , error.TypeMismatch);
}

test "error: pattern mismatch - wrong type for object" {
    try expectError(
        \\{ x, y } = [1, 2]
        \\x
    , error.TypeMismatch);
}

test "error: pattern mismatch - wrong type for tuple" {
    try expectError(
        \\(x, y) = [1, 2]
        \\x
    , error.TypeMismatch);
}

test "error: pattern mismatch - when matches no match" {
    try expectError(
        \\when 42 matches
        \\  [x, y] then x + y
        \\  { x } then x
    , error.TypeMismatch);
}

test "error: pattern mismatch - symbol" {
    try expectError("when #error matches #ok then 0", error.TypeMismatch);
}

test "error: pattern mismatch - boolean" {
    try expectError("when false matches true then 0", error.TypeMismatch);
}

test "error: pattern mismatch - integer" {
    try expectError("when 2 matches 1 then 0", error.TypeMismatch);
}

test "error: pattern mismatch - string" {
    try expectError(
        \\when "world" matches "hello" then 0
    , error.TypeMismatch);
}

// ============================================================================
// CYCLIC REFERENCE ERRORS
// ============================================================================

test "error: cyclic reference - simple" {
    try expectError(
        \\obj = { x: obj.x }
        \\obj.x
    , error.CyclicReference);
}

test "error: cyclic reference - indirect" {
    try expectError(
        \\obj = { x: obj.y, y: obj.x }
        \\obj.x
    , error.CyclicReference);
}

// ============================================================================
// BUILTIN FUNCTION ERRORS
// ============================================================================

test "error: wrong number of arguments to builtin" {
    try expectError(
        \\String = import 'String'
        \\String.length "hello" "world"
    , error.ExpectedFunction);
}

test "error: wrong argument type to Array.length" {
    try expectError(
        \\Array = import 'Array'
        \\Array.length 5
    , error.TypeMismatch);
}

test "error: wrong argument type to String.toUpperCase" {
    try expectError(
        \\String = import 'String'
        \\String.toUpperCase 42
    , error.TypeMismatch);
}

// ============================================================================
// COMPLEX/NESTED ERROR TESTS
// ============================================================================

test "error: nested unknown identifier in function" {
    try expectError(
        \\f = x -> (
        \\  inner = x + 2;
        \\  result = inner + unknownNested;
        \\  result
        \\)
        \\f 5
    , error.UnknownIdentifier);
}

test "error: type mismatch in nested function call" {
    try expectError(
        \\double = x -> x * 2
        \\result = double "text"
        \\result
    , error.TypeMismatch);
}

test "error: unknown field in array comprehension" {
    try expectError(
        \\objects = [{ x: 1 }, { x: 2 }]
        \\[obj.y for obj in objects]
    , error.UnknownField);
}

test "error: type mismatch in object extend" {
    try expectError(
        \\base = { x: 1 }
        \\extended = "not an object" { y: 2 }
        \\extended
    , error.TypeMismatch);
}

// ============================================================================
// INTERNAL BUILTIN ACCESS RESTRICTION
// ============================================================================

test "error: Builtins module is not accessible from user code" {
    try expectError("Builtins.array_length [1, 2, 3]", error.UnknownIdentifier);
}

test "stdlib functions that use Builtins internally still work" {
    var result = try eval.evalInlineWithContext(testing.allocator,
        \\Array = import 'Array'
        \\Array.length [1, 2, 3]
    );
    defer result.deinit();
    try testing.expect(result.err == null);
}
