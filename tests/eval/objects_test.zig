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
        \\{
        \\  rest: { three: 3, four: 4 }
        \\}
    ,
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
        \\{
        \\  one: 1,
        \\  two: 2,
        \\  rest: { three: 3 }
        \\}
    ,
    );
}

// Quoted string field keys

test "quoted string field key" {
    try expectEvaluates(
        \\{ "name": "Alice" }
    , "{ name: \"Alice\" }");
}

test "quoted string field key with spaces" {
    try expectEvaluates(
        \\{ "my field": 42 }
    , "{ my field: 42 }");
}

test "mixed quoted and unquoted field keys" {
    try expectEvaluates(
        \\{ "name": "Alice", age: 30 }
    , "{ name: \"Alice\", age: 30 }");
}

test "JSON object is valid Lazylang" {
    try expectEvaluates(
        \\{ "x": 1, "y": 2 }
    , "{ x: 1, y: 2 }");
}

// Conditional object fields

test "conditional object field with if - true" {
    try expectEvaluates(
        \\enabled = true
        \\{ x: 1, y: 2 if enabled }
    , "{ x: 1, y: 2 }");
}

test "conditional object field with if - false" {
    try expectEvaluates(
        \\enabled = false
        \\{ x: 1, y: 2 if enabled }
    , "{ x: 1 }");
}

test "conditional object field with unless - true" {
    try expectEvaluates(
        \\debug = true
        \\{ x: 1, verbose: true unless debug }
    , "{ x: 1 }");
}

test "conditional object field with unless - false" {
    try expectEvaluates(
        \\debug = false
        \\{ x: 1, verbose: true unless debug }
    , "{ x: 1, verbose: true }");
}

test "multiple conditional object fields" {
    try expectEvaluates(
        \\a = true
        \\b = false
        \\{ x: 1 if a, y: 2 if b, z: 3 if a }
    , "{ x: 1, z: 3 }");
}

test "all conditional object fields filtered out" {
    try expectEvaluates(
        \\{ x: 1 if false, y: 2 if false }
    , "{}");
}

// self references

test "self references sibling field" {
    try expectEvaluates(
        \\obj = { x: 1, y: self.x + 1 }
        \\obj.y
    , "2");
}

test "self in extended object sees overridden field" {
    try expectEvaluates(
        \\base = { x: 1, y: self.x + 10 }
        \\ext = base { x: 2 }
        \\ext.y
    , "12");
}

test "self with multiple derived fields" {
    try expectEvaluates(
        \\config = {
        \\  host: "localhost"
        \\  port: 8080
        \\  url: "http://" + self.host
        \\}
        \\config.url
    , "\"http://localhost\"");
}

test "self in extended object derives from overridden values" {
    try expectEvaluates(
        \\base = {
        \\  host: "localhost"
        \\  url: "http://" + self.host
        \\}
        \\prod = base { host: "prod.example.com" }
        \\prod.url
    , "\"http://prod.example.com\"");
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

// Hidden fields

test "hidden field excluded from output" {
    try expectEvaluates(
        \\{ x: 1, _base:: 8080, y: 2 }
    , "{ x: 1, y: 2 }");
}

test "hidden field accessible via field access" {
    try expectEvaluates(
        \\obj = { x: 1, _port:: 8080 }
        \\obj._port
    , "8080");
}

test "hidden field used by self" {
    try expectEvaluates(
        \\config = {
        \\  _port:: 8080
        \\  url: "http://localhost:" + toString self._port
        \\}
        \\config.url
    , "\"http://localhost:8080\"");
}

test "hidden field preserved through extension" {
    try expectEvaluates(
        \\base = { _port:: 8080, url: ":" + toString self._port }
        \\ext = base { _port:: 443 }
        \\ext.url
    , "\":443\"");
}

test "hidden field not in output after extension" {
    try expectEvaluates(
        \\base = { _port:: 8080, x: 1 }
        \\ext = base { y: 2 }
        \\ext
    , "{ x: 1, y: 2 }");
}

// Late-binding self: purity and chaining

test "base object not mutated by extension" {
    try expectEvaluates(
        \\base = { host: "localhost", url: "http://" + self.host }
        \\prod = base { host: "prod.example.com" }
        \\(base.url, prod.url)
    , "(\"http://localhost\", \"http://prod.example.com\")");
}

test "chained extensions with late-binding self" {
    try expectEvaluates(
        \\base = { x: 1, y: self.x + 10 }
        \\mid = base { x: 2 }
        \\top = mid { x: 3 }
        \\(base.y, mid.y, top.y)
    , "(11, 12, 13)");
}

test "self sees fields added by extension" {
    try expectEvaluates(
        \\base = { greeting: "Hello, " + self.name }
        \\extended = base { name: "Alice" }
        \\extended.greeting
    , "\"Hello, Alice\"");
}

test "hidden field with late-binding self through extension" {
    try expectEvaluates(
        \\base = { _port:: 8080, url: ":" + toString self._port }
        \\prod = base { _port:: 443 }
        \\(base.url, prod.url)
    , "(\":8080\", \":443\")");
}

test "hidden field excluded from JSON eval output" {
    // Hidden fields should not appear in eval --json output either
    try expectEvaluates(
        \\{ x: 1, _secret:: 42 }
    , "{ x: 1 }");
}

// Hidden field edge cases

test "Object.keys includes hidden fields" {
    try expectEvaluates(
        \\Object = import "Object"
        \\obj = { x: 1, _secret:: 42, y: 2 }
        \\Object.keys obj
    , "[\"x\", \"_secret\", \"y\"]");
}

test "hidden field not in object output" {
    try expectEvaluates(
        \\{ visible: 1, _hidden:: 2 }
    , "{ visible: 1 }");
}

// Sibling field references

test "object fields can reference sibling fields" {
    try expectEvaluates("{ x: 1, y: x + 1 }.y", "2");
}

test "object fields can reference later sibling fields" {
    try expectEvaluates("{ x: y + 1, y: 1 }.x", "2");
}

test "object sibling references work with self" {
    try expectEvaluates("{ x: 1, y: self.x + 1 }.y", "2");
}

test "object sibling fields shadow outer scope" {
    try expectEvaluates(
        \\x = 100
        \\{ x: 1, y: x + 1 }.y
    , "2");
}
