const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "Dynamic keys: null key creates no field" {
    try expectEvaluates(
        \\{ [null]: 42 }
    ,
        "{}",
    );
}

test "Dynamic keys: string key creates single field" {
    try expectEvaluates(
        \\{ ["foo"]: 42 }
    ,
        "{ foo: 42 }",
    );
}

test "Dynamic keys: array creates multiple fields" {
    try expectEvaluates(
        \\{ [["foo", "bar"]]: 42 }
    ,
        "{ foo: 42, bar: 42 }",
    );
}

test "Dynamic keys: array with null skips null elements" {
    try expectEvaluates(
        \\{ [["foo", null, "bar"]]: 42 }
    ,
        "{ foo: 42, bar: 42 }",
    );
}

test "Dynamic keys: conditional with true" {
    try expectEvaluates(
        \\foo = true
        \\{ [if foo then "bar"]: 42 }
    ,
        "{ bar: 42 }",
    );
}

test "Dynamic keys: conditional with false returns null" {
    try expectEvaluates(
        \\foo = false
        \\{ [if foo then "bar"]: 42 }
    ,
        "{}",
    );
}

test "Dynamic keys: mixed static and dynamic keys" {
    try expectEvaluates(
        \\{ ["foo"]: 1, bar: 2, ["baz"]: 3 }
    ,
        "{ foo: 1, bar: 2, baz: 3 }",
    );
}

test "Dynamic keys: computed from array comprehension" {
    try expectEvaluates(
        \\String = import 'String'
        \\keys = ["foo", "bar"]
        \\upperKeys = [String.toUpperCase key for key in keys]
        \\{ [upperKeys]: 42 }
    ,
        "{ FOO: 42, BAR: 42 }",
    );
}

test "Dynamic keys: object comprehension still works" {
    try expectEvaluates(
        \\String = import 'String'
        \\keys = ["foo", "bar"]
        \\{ [String.toUpperCase key]: 42 for key in keys }
    ,
        "{ FOO: 42, BAR: 42 }",
    );
}
