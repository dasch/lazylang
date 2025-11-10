const std = @import("std");
const evaluator = @import("evaluator");

fn expectEvaluates(source: []const u8, expected: []const u8) !void {
    var result = try evaluator.evalInline(std.testing.allocator, source);
    defer result.deinit();
    try std.testing.expectEqualStrings(expected, result.text);
}

test "evaluates arithmetic expressions" {
    try expectEvaluates("1 + 2 * 3", "7");
}

test "evaluates parentheses" {
    try expectEvaluates("(1 + 2) * 3", "9");
}

test "evaluates lambda application" {
    try expectEvaluates("(x -> x + 1) 41", "42");
}

test "supports higher order functions" {
    try expectEvaluates("(a -> b -> a + b) 2 3", "5");
}

test "evaluates array literals" {
    try expectEvaluates("[1, 2, 3]", "[1, 2, 3]");
}

test "allows newline separated array elements" {
    try expectEvaluates(
        "[\n  1\n  2\n]",
        "[1, 2]",
    );
}

test "evaluates object literals" {
    try expectEvaluates("{ foo: 1, bar: 2 }", "{foo: 1, bar: 2}");
}

test "allows newline separated object fields" {
    try expectEvaluates(
        "{\n  foo: 1\n  bar: 2\n}",
        "{foo: 1, bar: 2}",
    );
}

test "imports modules from search paths" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makePath("Helpers");
    try tmp_dir.dir.writeFile(.{ .sub_path = "Helpers/ArrayHelpers.lazy", .data = "{ reverse: items -> items }" });

    const module_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(module_path);

    const original_dir = try std.fs.cwd().realpathAlloc(std.testing.allocator, ".");
    defer {
        std.process.changeCurDir(original_dir) catch unreachable;
        std.testing.allocator.free(original_dir);
    }

    std.process.changeCurDir(module_path) catch unreachable;

    try expectEvaluates("import 'Helpers/ArrayHelpers'", "{reverse: <function>}");
}

test "evaluates double-quoted strings" {
    try expectEvaluates("\"hello world\"", "\"hello world\"");
}

test "evaluates single-quoted strings" {
    try expectEvaluates("'hello world'", "\"hello world\"");
}

test "evaluates empty tuple" {
    try expectEvaluates("()", "()");
}

test "evaluates single element tuple" {
    try expectEvaluates("(42,)", "(42)");
}

test "evaluates two element tuple" {
    try expectEvaluates("(1, 2)", "(1, 2)");
}

test "evaluates multi-element tuple" {
    try expectEvaluates("(1, 2, 3, 4)", "(1, 2, 3, 4)");
}

test "evaluates tuple with mixed types" {
    try expectEvaluates("(1, \"test\", 3)", "(1, \"test\", 3)");
}

test "evaluates nested tuples" {
    try expectEvaluates("((1, 2), (3, 4))", "((1, 2), (3, 4))");
}

test "evaluates tuple with expressions" {
    try expectEvaluates("(1 + 2, 3 * 4)", "(3, 12)");
}

test "evaluates tuple with arrays" {
    try expectEvaluates("([1, 2], [3, 4])", "([1, 2], [3, 4])");
}

test "evaluates tuple with objects" {
    try expectEvaluates("({ a: 1 }, { b: 2 })", "({a: 1}, {b: 2})");
}

test "evaluates tuple with strings" {
    try expectEvaluates("(\"a\", \"b\", \"c\")", "(\"a\", \"b\", \"c\")");
}

test "distinguishes parenthesized expressions from tuples" {
    try expectEvaluates("(42)", "42");
    try expectEvaluates("(1 + 2)", "3");
}

test "evaluates tuple with lambda expressions" {
    try expectEvaluates("((x -> x + 1), (x -> x * 2))", "(<function>, <function>)");
}

test "evaluates true literal" {
    try expectEvaluates("true", "true");
}

test "evaluates false literal" {
    try expectEvaluates("false", "false");
}

test "evaluates boolean in array" {
    try expectEvaluates("[true, false]", "[true, false]");
}

test "evaluates boolean in tuple" {
    try expectEvaluates("(true, false)", "(true, false)");
}

test "evaluates boolean in object" {
    try expectEvaluates("{ a: true, b: false }", "{a: true, b: false}");
}

test "evaluates mixed boolean and integer tuple" {
    try expectEvaluates("(true, 42, false)", "(true, 42, false)");
}

test "evaluates mixed types with booleans" {
    try expectEvaluates("(true, \"hello\", 42, false)", "(true, \"hello\", 42, false)");
}

test "evaluates logical AND with true and true" {
    try expectEvaluates("true && true", "true");
}

test "evaluates logical AND with true and false" {
    try expectEvaluates("true && false", "false");
}

test "evaluates logical AND with false and false" {
    try expectEvaluates("false && false", "false");
}

test "evaluates logical OR with true and true" {
    try expectEvaluates("true || true", "true");
}

test "evaluates logical OR with true and false" {
    try expectEvaluates("true || false", "true");
}

test "evaluates logical OR with false and false" {
    try expectEvaluates("false || false", "false");
}

test "evaluates logical NOT with true" {
    try expectEvaluates("!true", "false");
}

test "evaluates logical NOT with false" {
    try expectEvaluates("!false", "true");
}

test "evaluates double NOT" {
    try expectEvaluates("!!true", "true");
}

test "evaluates complex boolean expression with AND and OR" {
    try expectEvaluates("true && false || true", "true");
}

test "evaluates boolean expression with parentheses" {
    try expectEvaluates("!(true && false)", "true");
}

test "evaluates chained AND operations" {
    try expectEvaluates("true && true && true", "true");
}

test "evaluates chained OR operations" {
    try expectEvaluates("false || false || true", "true");
}

test "evaluates mixed boolean operations" {
    try expectEvaluates("!false && true || false", "true");
}

test "evaluates null literal" {
    try expectEvaluates("null", "null");
}

test "evaluates null in array" {
    try expectEvaluates("[null, 1, null]", "[null, 1, null]");
}

test "evaluates null in tuple" {
    try expectEvaluates("(null, true, false)", "(null, true, false)");
}

test "evaluates null in object" {
    try expectEvaluates("{ value: null }", "{value: null}");
}

test "evaluates mixed types with null" {
    try expectEvaluates("(1, null, \"test\", true, null)", "(1, null, \"test\", true, null)");
}

test "evaluates if-then-else with true condition" {
    try expectEvaluates("if true then 1 else 2", "1");
}

test "evaluates if-then-else with false condition" {
    try expectEvaluates("if false then 1 else 2", "2");
}

test "evaluates if-then without else with true condition" {
    try expectEvaluates("if true then 42", "42");
}

test "evaluates if-then without else with false condition returns null" {
    try expectEvaluates("if false then 42", "null");
}

test "evaluates if with boolean expression condition" {
    try expectEvaluates("if true && false then 1 else 2", "2");
}

test "evaluates if with complex condition" {
    try expectEvaluates("if !false then \"yes\" else \"no\"", "\"yes\"");
}

test "evaluates nested if expressions" {
    try expectEvaluates("if true then (if false then 1 else 2) else 3", "2");
}

test "evaluates if in array" {
    try expectEvaluates("[if true then 1 else 2, if false then 3 else 4]", "[1, 4]");
}

test "evaluates if in tuple" {
    try expectEvaluates("(if true then \"a\" else \"b\", if false then \"c\" else \"d\")", "(\"a\", \"d\")");
}

test "evaluates if with arithmetic in branches" {
    try expectEvaluates("if true then 1 + 2 else 3 * 4", "3");
}

test "evaluates chained if-else-if with first condition true" {
    try expectEvaluates("if true then 1 else if false then 2 else 3", "1");
}

test "evaluates chained if-else-if with second condition true" {
    try expectEvaluates("if false then 1 else if true then 2 else 3", "2");
}

test "evaluates chained if-else-if with all conditions false" {
    try expectEvaluates("if false then 1 else if false then 2 else 3", "3");
}

test "evaluates variable assignment with semicolon" {
    try expectEvaluates("x = 42; x", "42");
}

test "evaluates multiple variable assignments with semicolons" {
    try expectEvaluates("x = 1; y = 2; x + y", "3");
}

test "evaluates variable assignment with newlines" {
    try expectEvaluates("x = 42\nx", "42");
}

test "evaluates multiple variable assignments with newlines" {
    try expectEvaluates(
        \\x = 1
        \\y = 2
        \\x + y
    ,
        "3",
    );
}

test "evaluates variable shadowing" {
    try expectEvaluates("x = 1; x = 2; x", "2");
}

test "evaluates nested variable scopes" {
    try expectEvaluates("x = 1; y = (z = 2; z + 1); x + y", "4");
}

test "evaluates nested scopes with indentation" {
    try expectEvaluates(
        \\x =
        \\  x1 = 1
        \\  x2 = 2
        \\  x1 + x2
        \\y = 3
        \\x + y
    ,
        "6",
    );
}

test "evaluates tuple destructuring in assignment" {
    try expectEvaluates("(first, last) = (\"John\", \"Doe\"); first", "\"John\"");
}

test "evaluates tuple destructuring with multiple bindings" {
    try expectEvaluates("(a, b) = (1, 2); a + b", "3");
}

test "evaluates tuple destructuring with three elements" {
    try expectEvaluates("(x, y, z) = (1, 2, 3); x + y + z", "6");
}

test "evaluates object destructuring in assignment" {
    try expectEvaluates("{ first, last } = { first: \"John\", last: \"Doe\" }; first", "\"John\"");
}

test "evaluates object destructuring with multiple uses" {
    try expectEvaluates("{ x, y } = { x: 10, y: 20 }; x + y", "30");
}

test "evaluates array destructuring with two elements" {
    try expectEvaluates("[a, b] = [1, 2]; a + b", "3");
}

test "evaluates nested destructuring" {
    try expectEvaluates("(a, (b, c)) = (1, (2, 3)); a + b + c", "6");
}

test "evaluates function with tuple destructuring parameter" {
    try expectEvaluates("f = (a, b) -> a + b; f (1, 2)", "3");
}

test "evaluates function with object destructuring parameter" {
    try expectEvaluates("f = { first, last } -> first; f { first: \"John\", last: \"Doe\" }", "\"John\"");
}

test "evaluates function with array destructuring parameter" {
    try expectEvaluates("f = [x, y] -> x + y; f [10, 20]", "30");
}

test "evaluates function with nested destructuring parameter" {
    try expectEvaluates("f = (a, (b, c)) -> a + b + c; f (1, (2, 3))", "6");
}

test "evaluates when matches with tuple pattern" {
    try expectEvaluates(
        \\when (1, 2) matches
        \\  (x, y) then x + y
    ,
        "3",
    );
}

test "evaluates when matches with multiple patterns" {
    try expectEvaluates(
        \\value = [1, 2, 3]
        \\when value matches
        \\  (x, y) then x + y
        \\  [a, b, c] then a + b + c
    ,
        "6",
    );
}

test "evaluates when matches with otherwise" {
    try expectEvaluates(
        \\value = 42
        \\when value matches
        \\  (x, y) then x + y
        \\  otherwise 100
    ,
        "100",
    );
}

test "evaluates when matches with array pattern" {
    try expectEvaluates(
        \\when [1, 2, 3] matches
        \\  [a, b, c] then a + b + c
    ,
        "6",
    );
}

test "evaluates when matches with object pattern" {
    try expectEvaluates(
        \\when { x: 10, y: 20 } matches
        \\  { x, y } then x + y
    ,
        "30",
    );
}

test "evaluates when matches with nested pattern" {
    try expectEvaluates(
        \\when (1, (2, 3)) matches
        \\  (a, (b, c)) then a + b + c
    ,
        "6",
    );
}

test "evaluates when matches selecting first match" {
    try expectEvaluates(
        \\when (5, 10) matches
        \\  (a, b) then a + b
        \\  (x, y) then x * y
    ,
        "15",
    );
}
