const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "array comprehension: iterate over object with simple pattern" {
    try expectEvaluates(
        \\obj = { a: 1, b: 2 }
        \\[pair for pair in obj]
    ,
        "[\n  (\"a\", 1),\n  (\"b\", 2)\n]",
    );
}

test "array comprehension: iterate over object with tuple destructuring" {
    try expectEvaluates(
        \\obj = { foo: 42, bar: 99 }
        \\[{ key, val } for (key, val) in obj]
    ,
        "[\n  { key: \"foo\", val: 42 },\n  { key: \"bar\", val: 99 }\n]",
    );
}

test "array comprehension: iterate over nested object field" {
    try expectEvaluates(
        \\config = { env: { NODE_ENV: "production", DEBUG: "false" } }
        \\[{ name, value } for (name, value) in config.env]
    ,
        "[\n  { name: \"NODE_ENV\", value: \"production\" },\n  { name: \"DEBUG\", value: \"false\" }\n]",
    );
}

test "array comprehension: object iteration with filter" {
    try expectEvaluates(
        \\obj = { a: 1, b: 2, c: 3 }
        \\[val for (key, val) in obj when val > 1]
    ,
        "[2, 3]",
    );
}

test "array comprehension: nested object iteration" {
    try expectEvaluates(
        \\data = { users: { alice: 30, bob: 25 } }
        \\[{ name, age } for (name, age) in data.users]
    ,
        "[\n  { name: \"alice\", age: 30 },\n  { name: \"bob\", age: 25 }\n]",
    );
}

test "array comprehension: object iteration forces thunks" {
    try expectEvaluates(
        \\obj = { a: { x: 1 }, b: { x: 2 } }
        \\[v.x for (k, v) in obj]
    ,
        "[1, 2]",
    );
}
