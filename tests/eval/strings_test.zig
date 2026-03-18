const common = @import("common.zig");
const expectEvaluates = common.expectEvaluates;

test "evaluates double-quoted strings" {
    try expectEvaluates("\"hello world\"", "\"hello world\"");
}

test "evaluates single-quoted strings" {
    try expectEvaluates("'hello world'", "\"hello world\"");
}

test "simple variable interpolation" {
    try expectEvaluates(
        \\target = "world"
        \\"hello, $target"
    , "\"hello, world\"");
}

test "multiple variable interpolations" {
    try expectEvaluates(
        \\first = "John"
        \\last = "Doe"
        \\"$first $last"
    , "\"John Doe\"");
}

test "interpolation with integer" {
    try expectEvaluates(
        \\x = 42
        \\"The answer is $x"
    , "\"The answer is 42\"");
}

test "complex expression interpolation" {
    try expectEvaluates(
        \\x = 5
        \\y = 10
        \\"The sum is ${x + y}"
    , "\"The sum is 15\"");
}

test "interpolation with nested expressions" {
    try expectEvaluates(
        \\name = "alice"
        \\toUpper = str -> str
        \\"Hello, ${toUpper name}"
    , "\"Hello, alice\"");
}

test "interpolation at string boundaries" {
    try expectEvaluates(
        \\x = "test"
        \\"$x"
    , "\"test\"");
}

test "interpolation with boolean" {
    try expectEvaluates(
        \\flag = true
        \\"Flag is $flag"
    , "\"Flag is true\"");
}

test "empty interpolation becomes empty" {
    try expectEvaluates(
        \\"hello world"
    , "\"hello world\"");
}

test "dollar sign without identifier is literal" {
    try expectEvaluates(
        \\"Price: $ 100"
    , "\"Price: $ 100\"");
}

// Multiline text blocks

test "multiline text block basic" {
    try expectEvaluates(
        \\'''
        \\hello
        \\world
        \\'''
    ,
        \\"hello
        \\world"
    );
}

test "multiline text block strips common indentation" {
    try expectEvaluates(
        \\'''
        \\  hello
        \\  world
        \\'''
    ,
        \\"hello
        \\world"
    );
}

test "multiline text block preserves relative indentation" {
    try expectEvaluates(
        \\'''
        \\  hello
        \\    world
        \\'''
    ,
        \\"hello
        \\  world"
    );
}

test "multiline text block single line" {
    try expectEvaluates(
        \\'''
        \\hello
        \\'''
    , "\"hello\"");
}

test "multiline text block empty" {
    try expectEvaluates(
        \\'''
        \\'''
    , "\"\"");
}

// String concatenation with +

test "string concatenation with +" {
    try expectEvaluates(
        \\"hello" + " " + "world"
    , "\"hello world\"");
}

test "string concatenation with variable" {
    try expectEvaluates(
        \\name = "Alice"
        \\"Hello, " + name + "!"
    , "\"Hello, Alice!\"");
}

test "string concatenation empty strings" {
    try expectEvaluates(
        \\"" + "hello" + ""
    , "\"hello\"");
}
