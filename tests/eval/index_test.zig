const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "index: array indexing with integer" {
    try expectEvaluates(
        \\arr = [10, 20, 30]
        \\arr[1]
    ,
        "20",
    );
}

test "index: array indexing with first element" {
    try expectEvaluates(
        \\arr = ["a", "b", "c"]
        \\arr[0]
    ,
        "\"a\"",
    );
}

test "index: array indexing with last element" {
    try expectEvaluates(
        \\arr = [1, 2, 3, 4, 5]
        \\arr[4]
    ,
        "5",
    );
}

test "index: object indexing with string key" {
    try expectEvaluates(
        \\obj = { name: "Alice", age: 30 }
        \\obj["name"]
    ,
        "\"Alice\"",
    );
}

test "index: object indexing with dynamic key" {
    try expectEvaluates(
        \\obj = { foo: 42, bar: 99 }
        \\key = "bar"
        \\obj[key]
    ,
        "99",
    );
}

test "index: nested indexing" {
    try expectEvaluates(
        \\data = { users: [{ name: "Alice" }, { name: "Bob" }] }
        \\data["users"][1]["name"]
    ,
        "\"Bob\"",
    );
}

test "index: indexing with computed key" {
    try expectEvaluates(
        \\obj = { a: 1, b: 2, c: 3 }
        \\keys = ["a", "b", "c"]
        \\obj[keys[1]]
    ,
        "2",
    );
}

test "index: whitespace sensitivity - array argument" {
    try expectEvaluates(
        \\fn = x -> x[0]
        \\fn [1, 2, 3]
    ,
        "1",
    );
}

test "index: indexing forces thunks" {
    try expectEvaluates(
        \\config = { env: { NODE_ENV: "production" } }
        \\config["env"]["NODE_ENV"]
    ,
        "\"production\"",
    );
}
