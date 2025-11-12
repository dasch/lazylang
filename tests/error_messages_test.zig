const std = @import("std");
const eval = @import("evaluator");
const testing = std.testing;

// Helper to expect an error occurs
fn expectError(source: []const u8, expected_error: anyerror) !void {
    const result = eval.evalInline(testing.allocator, source);
    try testing.expectError(expected_error, result);
}

test "error messages: unknown identifier" {
    try expectError("unknownVar", error.UnknownIdentifier);
}

test "error messages: type mismatch - add number and boolean" {
    try expectError("5 + true", error.TypeMismatch);
}

test "error messages: type mismatch - add number and string" {
    try expectError("5 + \"hello\"", error.TypeMismatch);
}

test "error messages: type mismatch - multiply number and string" {
    try expectError("5 * \"hello\"", error.TypeMismatch);
}

test "error messages: type mismatch - comparison of incompatible types" {
    try expectError("5 < \"hello\"", error.TypeMismatch);
}

test "error messages: type mismatch - negation of non-number" {
    // Note: Parser reports ExpectedExpression because `-` expects a number literal/expression
    try expectError("-\"hello\"", error.ExpectedExpression);
}

test "error messages: type mismatch - not operation on non-boolean" {
    try expectError("!5", error.TypeMismatch);
}

test "error messages: type mismatch - array operation on non-array" {
    try expectError(
        \\Array = import 'Array';
        \\Array.length 5
    , error.TypeMismatch);
}

test "error messages: unknown field" {
    try expectError("{x: 5}.y", error.UnknownField);
}

test "error messages: import not found" {
    try expectError("import 'NonExistentModule'", error.ModuleNotFound);
}

test "error messages: unterminated string" {
    try expectError("\"hello", error.UnterminatedString);
}

test "error messages: expected expression after operator" {
    // Parsing `5 + )` fails because `)` is not an expression
    try expectError("5 + )", error.ExpectedExpression);
}

test "error messages: expected expression after assignment" {
    // Parsing `let x =` fails at end of input
    try expectError("let x =", error.UnexpectedToken);
}
