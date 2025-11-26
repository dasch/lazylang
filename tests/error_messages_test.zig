const std = @import("std");
const eval = @import("evaluator");
const testing = std.testing;

// Helper to expect an error occurs
fn expectError(source: []const u8, expected_error: anyerror) !void {
    const result = eval.evalInline(testing.allocator, source);
    try testing.expectError(expected_error, result);
}

// ============================================================================
// TOKENIZER/PARSER ERROR TESTS
// ============================================================================

test "error message: unterminated string - basic" {
    try expectError(\\"hello
, error.UnterminatedString);
}

test "error message: unterminated string - with newlines" {
    try expectError(
        \\x = 10
        \\"hello
        \\y = 20
        ,
        error.UnterminatedString,
    );
}

test "error message: unexpected character" {
    try expectError("x = 5 @ 3", error.UnexpectedCharacter);
}

test "error message: unexpected token - missing operand" {
    try expectError("x = 5 +", error.ExpectedExpression);
}

test "error message: unexpected token - unexpected closing paren" {
    try expectError("x = 5 + )", error.ExpectedExpression);
}

test "error message: missing closing paren" {
    try expectError("x = (5 + 3", error.UnexpectedToken);
}

test "error message: missing closing bracket" {
    try expectError("x = [1, 2, 3", error.UnexpectedToken);
}

test "error message: missing closing brace" {
    try expectError("obj = { x: 1, y: 2", error.UnexpectedToken);
}

test "error message: unexpected token after let" {
    try expectError("let 123 = 5; x", error.UnexpectedToken);
}

// ============================================================================
// IDENTIFIER/SCOPE ERROR TESTS
// ============================================================================

test "error message: unknown identifier - simple" {
    try expectError("unknownVar", error.UnknownIdentifier);
}

test "error message: unknown identifier - in expression" {
    try expectError(
        \\x = 10
        \\y = unknownVar + x
        \\y
        ,
        error.UnknownIdentifier,
    );
}

test "error message: unknown identifier - nested scope" {
    try expectError(
        \\f = x -> unknownNested + x
        \\f 5
        ,
        error.UnknownIdentifier,
    );
}

test "error message: unknown identifier - in object field" {
    try expectError(
        \\obj = { x: unknownVar }
        \\obj.x
        ,
        error.UnknownIdentifier,
    );
}

test "error message: unknown identifier - in array" {
    try expectError(
        \\arr = [1, 2, unknownVar, 4]
        \\arr
        ,
        error.UnknownIdentifier,
    );
}

// ============================================================================
// TYPE MISMATCH ERROR TESTS
// ============================================================================

test "error message: type mismatch - add number and string" {
    try expectError("5 + \"hello\"", error.TypeMismatch);
}

test "error message: type mismatch - add number and boolean" {
    try expectError("5 + true", error.TypeMismatch);
}

test "error message: type mismatch - multiply string" {
    try expectError("\"hello\" * 5", error.TypeMismatch);
}

test "error message: type mismatch - subtract incompatible" {
    try expectError("10 - \"five\"", error.TypeMismatch);
}

// Division operator not supported yet
// test "error message: type mismatch - divide by string" {
//     try expectError("10 / \"two\"", error.TypeMismatch);
// }

test "error message: type mismatch - comparison of incompatible types" {
    try expectError("5 < \"hello\"", error.TypeMismatch);
}

test "error message: type mismatch - logical and with non-boolean" {
    try expectError("true && 5", error.TypeMismatch);
}

test "error message: type mismatch - logical or with non-boolean" {
    try expectError("false || \"yes\"", error.TypeMismatch);
}

test "error message: type mismatch - not operation on non-boolean" {
    try expectError("!5", error.TypeMismatch);
}

test "error message: type mismatch - negate string" {
    try expectError("-\"hello\"", error.ExpectedExpression);
}

// ============================================================================
// FUNCTION APPLICATION ERROR TESTS
// ============================================================================

test "error message: not a function - integer" {
    try expectError(
        \\x = 42
        \\x 10
        ,
        error.ExpectedFunction,
    );
}

test "error message: not a function - string" {
    try expectError("\"hello\" \"world\"", error.ExpectedFunction);
}

test "error message: not a function - array" {
    try expectError(
        \\arr = [1, 2, 3]
        \\arr 1
        ,
        error.ExpectedFunction,
    );
}

test "error message: not a function - object" {
    try expectError(
        \\obj = { x: 5 }
        \\obj 10
        ,
        error.ExpectedFunction,
    );
}

// ============================================================================
// PATTERN MATCHING ERROR TESTS
// ============================================================================

test "error message: pattern mismatch - tuple length" {
    try expectError(
        \\f = (x, y, z) -> x + y + z
        \\f (1, 2)
        ,
        error.TypeMismatch,
    );
}

test "error message: pattern mismatch - tuple value" {
    try expectError("when (1, 2) matches (1, 3) then 0", error.TypeMismatch);
}

test "error message: pattern mismatch - array length" {
    try expectError(
        \\[x, y, z] = [1, 2]
        \\x
        ,
        error.TypeMismatch,
    );
}

test "error message: pattern mismatch - array value" {
    try expectError(
        \\[1, 2, 3] = [1, 3, 3]
        \\0
        ,
        error.TypeMismatch,
    );
}

test "error message: pattern mismatch - object missing field" {
    try expectError(
        \\{ x, y } = { x: 1 }
        \\x
        ,
        error.TypeMismatch,
    );
}

test "error message: pattern mismatch - object field value" {
    try expectError(
        \\{ x: 1, y } = { x: 2, y: 3 }
        \\y
        ,
        error.TypeMismatch,
    );
}

test "error message: pattern mismatch - wrong type for array" {
    try expectError(
        \\[x, y] = 42
        \\x
        ,
        error.TypeMismatch,
    );
}

test "error message: pattern mismatch - wrong type for object" {
    try expectError(
        \\{ x, y } = [1, 2]
        \\x
        ,
        error.TypeMismatch,
    );
}

test "error message: pattern mismatch - wrong type for tuple" {
    try expectError(
        \\(x, y) = [1, 2]
        \\x
        ,
        error.TypeMismatch,
    );
}

test "error message: pattern mismatch - when matches no match" {
    try expectError(
        \\when 42 matches
        \\  [x, y] then x + y
        \\  { x } then x
        ,
        error.TypeMismatch,
    );
}

test "error message: pattern mismatch - symbol mismatch" {
    try expectError("when #error matches #ok then 0", error.TypeMismatch);
}

test "error message: pattern mismatch - boolean mismatch" {
    try expectError("when false matches true then 0", error.TypeMismatch);
}

test "error message: pattern mismatch - integer mismatch" {
    try expectError("when 2 matches 1 then 0", error.TypeMismatch);
}

test "error message: pattern mismatch - string mismatch" {
    try expectError("when \"world\" matches \"hello\" then 0", error.TypeMismatch);
}

// ============================================================================
// FIELD ACCESS ERROR TESTS
// ============================================================================

test "error message: unknown field - simple" {
    try expectError(
        \\obj = { x: 1 }
        \\obj.y
        ,
        error.UnknownField,
    );
}

test "error message: unknown field - multiple available fields" {
    try expectError(
        \\obj = { name: "Alice", age: 30, city: "NYC" }
        \\obj.unknownField
        ,
        error.UnknownField,
    );
}

test "error message: unknown field - empty object" {
    try expectError(
        \\obj = {}
        \\obj.x
        ,
        error.UnknownField,
    );
}

test "error message: unknown field - nested" {
    try expectError(
        \\obj = { inner: { x: 1 } }
        \\obj.inner.y
        ,
        error.UnknownField,
    );
}

test "error message: field access on non-object - string" {
    try expectError(
        \\f = x -> x.field
        \\f "hello"
        ,
        error.TypeMismatch,
    );
}

test "error message: field access on non-object - integer" {
    try expectError(
        \\f = x -> x.value
        \\f 42
        ,
        error.TypeMismatch,
    );
}

test "error message: field access on non-object - boolean" {
    try expectError(
        \\f = x -> x.status
        \\f true
        ,
        error.TypeMismatch,
    );
}

// ============================================================================
// MODULE/IMPORT ERROR TESTS
// ============================================================================

test "error message: module not found" {
    try expectError("import 'NonExistentModule'", error.ModuleNotFound);
}

test "error message: module not found - relative path" {
    try expectError("import './does_not_exist'", error.ModuleNotFound);
}

// ============================================================================
// CYCLIC REFERENCE ERROR TESTS
// ============================================================================

test "error message: cyclic reference - simple" {
    try expectError(
        \\obj = { x: obj.x }
        \\obj.x
        ,
        error.CyclicReference,
    );
}

test "error message: cyclic reference - indirect" {
    try expectError(
        \\obj = { x: obj.y, y: obj.x }
        \\obj.x
        ,
        error.CyclicReference,
    );
}

// ============================================================================
// BUILTIN FUNCTION ERROR TESTS
// ============================================================================

test "error message: wrong number of arguments" {
    // Note: Function application is left-associative, so this becomes:
    // (String.length "hello") "world", which tries to call a non-function
    try expectError(
        \\String = import 'String'
        \\String.length "hello" "world"
        ,
        error.ExpectedFunction,
    );
}

test "error message: type mismatch in builtin - array length on non-array" {
    try expectError(
        \\Array = import 'Array'
        \\Array.length 5
        ,
        error.TypeMismatch,
    );
}

test "error message: type mismatch in builtin - string upper on non-string" {
    try expectError(
        \\String = import 'String'
        \\String.toUpperCase 42
        ,
        error.TypeMismatch,
    );
}

// Note: Array.get returns a Result type (#ok or #outOfBounds), not an error
// test "error message: invalid argument - negative array index" {
//     try expectError(
//         \\Array = import 'Array'
//         \\Array.get (-1) [1, 2, 3]
//         ,
//         error.InvalidArgument,
//     );
// }

// ============================================================================
// COMPLEX/NESTED ERROR TESTS
// ============================================================================

test "error message: nested unknown identifier in function" {
    try expectError(
        \\f = x -> (
        \\  inner = x + 2;
        \\  result = inner + unknownNested;
        \\  result
        \\)
        \\f 5
        ,
        error.UnknownIdentifier,
    );
}

test "error message: type mismatch in nested function call" {
    try expectError(
        \\double = x -> x * 2
        \\result = double "text"
        \\result
        ,
        error.TypeMismatch,
    );
}

test "error message: unknown field in array comprehension" {
    try expectError(
        \\objects = [{ x: 1 }, { x: 2 }]
        \\[obj.y for obj in objects]
        ,
        error.UnknownField,
    );
}

test "error message: type mismatch in object extend" {
    try expectError(
        \\base = { x: 1 }
        \\extended = "not an object" { y: 2 }
        \\extended
        ,
        error.TypeMismatch,
    );
}
