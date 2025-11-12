const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates object literals" {
    try expectEvaluates("{ foo: 1, bar: 2 }", "{ foo: 1, bar: 2 }");
}

test "allows newline separated object fields" {
    try expectEvaluates(
        "{\n  foo: 1\n  bar: 2\n}",
        "{ foo: 1, bar: 2 }",
    );
}

test "evaluates short object syntax" {
    try expectEvaluates("x = 1; y = 2; { x, y }", "{ x: 1, y: 2 }");
}

test "evaluates mixed short and long object syntax" {
    try expectEvaluates("x = 42; name = \"test\"; { x, name, extra: 123 }", "{ x: 42, name: \"test\", extra: 123 }");
}

test "evaluates short object syntax with newlines" {
    try expectEvaluates(
        \\x = 1
        \\y = 2
        \\{ x, y }
    ,
        "{ x: 1, y: 2 }",
    );
}

test "evaluates short object syntax with multiple fields" {
    try expectEvaluates(
        \\a = 1
        \\b = 2
        \\c = 3
        \\{ a, b, c }
    ,
        "{ a: 1, b: 2, c: 3 }",
    );
}

test "object extension with overwrite" {
    try expectEvaluates(
        \\foo = { x: 1, y: 2 }
        \\bar = foo { y: 3 }
        \\bar
    ,
        "{ x: 1, y: 3 }",
    );
}

test "object extension adds new fields" {
    try expectEvaluates(
        \\foo = { x: 1 }
        \\bar = foo { y: 2 }
        \\bar
    ,
        "{ x: 1, y: 2 }",
    );
}

test "object extension with multiple overwrites" {
    try expectEvaluates(
        \\base = { a: 1, b: 2, c: 3 }
        \\extended = base { b: 20, c: 30 }
        \\extended
    ,
        "{ a: 1, b: 20, c: 30 }",
    );
}

test "object merge operator" {
    try expectEvaluates(
        \\obj1 = { x: 1, y: 2 }
        \\obj2 = { y: 3, z: 4 }
        \\obj1 & obj2
    ,
        "{ x: 1, y: 3, z: 4 }",
    );
}

test "object merge operator preserves left operand fields" {
    try expectEvaluates(
        \\obj1 = { a: 1, b: 2 }
        \\obj2 = { c: 3 }
        \\obj1 & obj2
    ,
        "{ a: 1, b: 2, c: 3 }",
    );
}

test "object patch syntax merges nested objects" {
    try expectEvaluates(
        \\obj1 = { rest: { three: 3 } }
        \\obj2 = obj1 { rest { four: 4 } }
        \\obj2
    ,
        "{ rest: { three: 3, four: 4 } }",
    );
}

test "object patch syntax in literal" {
    try expectEvaluates(
        \\obj = {
        \\  one: 1
        \\  two: 2
        \\  rest {
        \\    three: 3
        \\  }
        \\}
        \\obj
    ,
        "{ one: 1, two: 2, rest: { three: 3 } }",
    );
}

test "object extension can be chained" {
    try expectEvaluates(
        \\base = { a: 1 }
        \\ext1 = base { b: 2 }
        \\ext2 = ext1 { c: 3 }
        \\ext2
    ,
        "{ a: 1, b: 2, c: 3 }",
    );
}
