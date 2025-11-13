const std = @import("std");
const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "object field access" {
    try expectEvaluates(
        \\obj = { foo: 42 }
        \\obj.foo
    , "42");
}

test "nested object field access" {
    try expectEvaluates(
        \\obj = { nested: { field: "bar" } }
        \\obj.nested.field
    , "\"bar\"");
}

test "field accessor function" {
    try expectEvaluates(
        \\getFoo = .foo
        \\obj = { foo: 42 }
        \\getFoo obj
    , "42");
}

test "chained field accessor function" {
    try expectEvaluates(
        \\getAddress = .user.address
        \\record = { user: { address: "123 Main St" } }
        \\getAddress record
    , "\"123 Main St\"");
}

test "field projection with single field" {
    try expectEvaluates(
        \\user = { name: "Alice", age: 30, email: "alice@example.com" }
        \\user.{ name }
    , "{ name: \"Alice\" }");
}

test "field projection with multiple fields" {
    try expectEvaluates(
        \\user = { name: "Alice", age: 30, email: "alice@example.com" }
        \\user.{ name, age }
    , "{ name: \"Alice\", age: 30 }");
}

test "field projection with nested accessor" {
    try expectEvaluates(
        \\record = { user: { name: "Alice", age: 30 } }
        \\record.user.{ name }
    , "{ name: \"Alice\" }");
}

test "field projection with multiple nested fields" {
    try expectEvaluates(
        \\record = { user: { name: "Alice", age: 30, email: "alice@example.com" } }
        \\record.user.{ name, age }
    , "{ name: \"Alice\", age: 30 }");
}

test "field projection can be assigned" {
    try expectEvaluates(
        \\user = { name: "Alice", age: 30, email: "alice@example.com" }
        \\subset = user.{ name, age }
        \\subset
    , "{ name: \"Alice\", age: 30 }");
}

test "field accessor as function argument with space" {
    try expectEvaluates(
        \\map = f -> xs -> [f x for x in xs]
        \\people = [{ name: "Alice" }, { name: "Bob" }]
        \\map .name people
    , "[\"Alice\", \"Bob\"]");
}

test "field accessor with Array.map" {
    try expectEvaluates(
        \\Array = import 'Array'
        \\people = [{ name: "Alice" }, { name: "Bob" }]
        \\Array.map .name people
    , "[\"Alice\", \"Bob\"]");
}

test "field accessor with parentheses still works" {
    try expectEvaluates(
        \\Array = import 'Array'
        \\people = [{ name: "Alice" }, { name: "Bob" }]
        \\Array.map (.name) people
    , "[\"Alice\", \"Bob\"]");
}

test "whitespace disambiguates field access vs field accessor" {
    // No space before dot = field access chain
    try expectEvaluates(
        \\obj = { nested: { field: "value" } }
        \\obj.nested.field
    , "\"value\"");

    // Space before dot = field accessor as function argument
    try expectEvaluates(
        \\map = f -> xs -> [f x for x in xs]
        \\objs = [{ field: 1 }, { field: 2 }]
        \\map .field objs
    , "[1, 2]");
}

