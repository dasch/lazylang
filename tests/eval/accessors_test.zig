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
