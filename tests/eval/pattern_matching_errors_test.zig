const std = @import("std");
const evaluator = @import("evaluator");

fn expectError(source: []const u8, expected_error: evaluator.EvalError) !void {
    const result = evaluator.evalInline(std.testing.allocator, source);
    if (result) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(expected_error, err);
    }
}

// Array pattern matching errors

test "array pattern: length mismatch without rest" {
    try expectError(
        \\[x, y] = [1, 2, 3]; 0
    , error.TypeMismatch);
}

test "array pattern: length mismatch too few elements" {
    try expectError(
        \\[x, y, z] = [1, 2]; 0
    , error.TypeMismatch);
}

test "array pattern: element value mismatch" {
    try expectError(
        \\[1, 2, 3] = [1, 3, 3]; 0
    , error.TypeMismatch);
}

test "array pattern: element value mismatch at different position" {
    try expectError(
        \\[1, 2, ...rest] = [1, 3, 3, 4]; 0
    , error.TypeMismatch);
}

test "array pattern: type mismatch with non-array" {
    try expectError(
        \\[a, b] = 42; 0
    , error.TypeMismatch);
}

test "array pattern: type mismatch with object" {
    try expectError(
        \\[a, b] = { x: 1, y: 2 }; 0
    , error.TypeMismatch);
}

test "array pattern: with rest but too few elements" {
    try expectError(
        \\[x, y, z, ...rest] = [1, 2]; 0
    , error.TypeMismatch);
}

// Tuple pattern matching errors

test "tuple pattern: length mismatch" {
    try expectError(
        \\(x, y) = (1, 2, 3); 0
    , error.TypeMismatch);
}

test "tuple pattern: element value mismatch" {
    try expectError(
        \\(1, 2) = (1, 3); 0
    , error.TypeMismatch);
}

test "tuple pattern: type mismatch with non-tuple" {
    try expectError(
        \\(x, y) = [1, 2]; 0
    , error.TypeMismatch);
}

// Object pattern matching errors

test "object pattern: missing field" {
    try expectError(
        \\{ x, y } = { x: 1 }; 0
    , error.TypeMismatch);
}

test "object pattern: field value mismatch" {
    try expectError(
        \\{ x: 1, y } = { x: 2, y: 3 }; 0
    , error.TypeMismatch);
}

test "object pattern: type mismatch with non-object" {
    try expectError(
        \\{ x, y } = [1, 2]; 0
    , error.TypeMismatch);
}

test "object pattern: empty object missing fields" {
    try expectError(
        \\{ x } = {}; 0
    , error.TypeMismatch);
}

// Literal pattern matching errors

test "integer pattern: value mismatch" {
    try expectError(
        \\when 2 matches 1 then 0
    , error.TypeMismatch);
}

test "integer pattern: type mismatch with string" {
    try expectError(
        \\when "hello" matches 1 then 0
    , error.TypeMismatch);
}

test "float pattern: value mismatch" {
    try expectError(
        \\when 2.5 matches 1.5 then 0
    , error.TypeMismatch);
}

test "float pattern: type mismatch with integer" {
    try expectError(
        \\when 1 matches 1.5 then 0
    , error.TypeMismatch);
}

test "boolean pattern: value mismatch" {
    try expectError(
        \\when false matches true then 0
    , error.TypeMismatch);
}

test "boolean pattern: type mismatch with integer" {
    try expectError(
        \\when 1 matches true then 0
    , error.TypeMismatch);
}

test "null pattern: type mismatch with integer" {
    try expectError(
        \\when 0 matches null then 0
    , error.TypeMismatch);
}

test "string pattern: value mismatch" {
    try expectError(
        \\when "world" matches "hello" then 0
    , error.TypeMismatch);
}

test "string pattern: type mismatch with integer" {
    try expectError(
        \\when 42 matches "hello" then 0
    , error.TypeMismatch);
}

test "symbol pattern: value mismatch" {
    try expectError(
        \\when #error matches #ok then 0
    , error.TypeMismatch);
}

test "symbol pattern: type mismatch with string" {
    try expectError(
        \\when "ok" matches #ok then 0
    , error.TypeMismatch);
}

// Nested pattern matching errors

test "nested array pattern: inner element mismatch" {
    try expectError(
        \\[[1, 2], [3, 4]] = [[1, 2], [3, 5]]; 0
    , error.TypeMismatch);
}

test "nested tuple pattern: inner element mismatch" {
    try expectError(
        \\((1, 2), (3, 4)) = ((1, 2), (3, 5)); 0
    , error.TypeMismatch);
}

test "nested object pattern: inner field mismatch" {
    try expectError(
        \\{ x: { y: 1 } } = { x: { y: 2 } }; 0
    , error.TypeMismatch);
}

// Function application with pattern matching errors

test "function application: parameter pattern mismatch" {
    try expectError(
        \\f = (x, y) -> x + y
        \\f 1
    , error.TypeMismatch);
}

test "function application: destructuring pattern mismatch" {
    try expectError(
        \\f = [a, b, c] -> a + b + c
        \\f [1, 2]
    , error.TypeMismatch);
}

// When matches without matching patterns

test "when matches: no pattern matches and no otherwise" {
    try expectError(
        \\when 42 matches
        \\  [x, y] then x + y
        \\  { x } then x
    , error.TypeMismatch);
}
