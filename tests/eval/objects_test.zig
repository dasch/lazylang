const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates object literals" {
    try expectEvaluates("{ foo: 1, bar: 2 }", "{foo: 1, bar: 2}");
}

test "allows newline separated object fields" {
    try expectEvaluates(
        "{\n  foo: 1\n  bar: 2\n}",
        "{foo: 1, bar: 2}",
    );
}

test "evaluates short object syntax" {
    try expectEvaluates("x = 1; y = 2; { x, y }", "{x: 1, y: 2}");
}

test "evaluates mixed short and long object syntax" {
    try expectEvaluates("x = 42; name = \"test\"; { x, name, extra: 123 }", "{x: 42, name: \"test\", extra: 123}");
}

test "evaluates short object syntax with newlines" {
    try expectEvaluates(
        \\x = 1
        \\y = 2
        \\{ x, y }
    ,
        "{x: 1, y: 2}",
    );
}

test "evaluates short object syntax with multiple fields" {
    try expectEvaluates(
        \\a = 1
        \\b = 2
        \\c = 3
        \\{ a, b, c }
    ,
        "{a: 1, b: 2, c: 3}",
    );
}

test "Object.get returns ok tuple when key exists" {
    try expectEvaluates(
        \\{ get } = import 'Object'
        \\obj = { name: "Alice" }
        \\get (obj, "name")
    ,
        "(#ok, \"Alice\")",
    );
}

test "Object.get returns noSuchKey tag when key does not exist" {
    try expectEvaluates(
        \\{ get } = import 'Object'
        \\obj = { name: "Alice" }
        \\get (obj, "email")
    ,
        "#noSuchKey",
    );
}

test "Object.get returns ok tuple for nested values" {
    try expectEvaluates(
        \\{ get } = import 'Object'
        \\obj = { user: { name: "Bob" } }
        \\get (obj, "user")
    ,
        "(#ok, {name: \"Bob\"})",
    );
}
