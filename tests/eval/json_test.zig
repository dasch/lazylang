const std = @import("std");
const evaluator = @import("evaluator");
const testing = std.testing;

test "JSON: parse simple string" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse '"hello"'
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "hello") != null);
}

test "JSON: parse integer" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse "42"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "42") != null);
}

test "JSON: parse negative integer" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse "-123"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "-123") != null);
}

test "JSON: parse boolean true" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse "true"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "true") != null);
}

test "JSON: parse boolean false" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse "false"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "false") != null);
}

test "JSON: parse null" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse "null"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "null") != null);
}

test "JSON: parse array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse "[1, 2, 3]"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "[1, 2, 3]") != null);
}

test "JSON: parse nested array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse "[[1, 2], [3, 4]]"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "[1, 2]") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "[3, 4]") != null);
}

test "JSON: parse object" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse '{"name": "John", "age": 30}'
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "name") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "John") != null);
}

test "JSON: parse nested object" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse '{"user": {"name": "Alice", "age": 25}}'
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "user") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "Alice") != null);
}

test "JSON: parse empty array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse "[]"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "[]") != null);
}

test "JSON: parse empty object" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse "{}"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "{}") != null);
}

test "JSON: parse with whitespace" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse '  { "x" : 42 }  '
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "42") != null);
}

test "JSON: parse invalid JSON returns error" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse "{ invalid }"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#error") != null);
}

test "JSON: parse empty string returns null" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse ""
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "null") != null);
}

test "JSON: encode string" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.encode "hello"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "hello") != null);
}

test "JSON: encode integer" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.encode 42
    );
    defer result.deinit();

    try testing.expectEqualStrings("\"42\"", result.text);
}

test "JSON: encode boolean" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.encode true
    );
    defer result.deinit();

    try testing.expectEqualStrings("\"true\"", result.text);
}

test "JSON: encode null" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.encode null
    );
    defer result.deinit();

    try testing.expectEqualStrings("\"null\"", result.text);
}

test "JSON: encode array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.encode [1, 2, 3]
    );
    defer result.deinit();

    try testing.expectEqualStrings("\"[1, 2, 3]\"", result.text);
}

test "JSON: encode object" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.encode { name: "John", age: 30 }
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "name") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "John") != null);
}

test "JSON: encode symbol" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.encode #success
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "success") != null);
}

test "JSON: encode tuple" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.encode (1, 2, 3)
    );
    defer result.deinit();

    try testing.expectEqualStrings("\"[1, 2, 3]\"", result.text);
}

test "JSON: encode nested structures" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.encode { items: [1, 2, 3], meta: { count: 3 } }
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "items") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "meta") != null);
}

test "JSON: encode string with special characters" {
    var result = try evaluator.evalInline(testing.allocator,
        \\str = "line1\nline2\ttab"
        \\JSON = import 'JSON'
        \\JSON.encode str
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "line1") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "line2") != null);
}

test "JSON: round-trip simple values" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\value = { name: "Alice", age: 30 }
        \\json = JSON.encode value
        \\(#ok, parsed) = JSON.parse json
        \\parsed.name == value.name
    );
    defer result.deinit();

    try testing.expectEqualStrings("true", result.text);
}

test "JSON: round-trip array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\original = [1, 2, 3, 4, 5]
        \\json = JSON.encode original
        \\(#ok, parsed) = JSON.parse json
        \\parsed == original
    );
    defer result.deinit();

    try testing.expectEqualStrings("true", result.text);
}

test "JSON: parse mixed types in array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse '[1, "hello", true, null]'
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "1") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "true") != null);
}

test "JSON: parse string with unicode escapes" {
    var result = try evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.parse '"hello world"'
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "hello world") != null);
}

test "JSON: encode crashes on function" {
    var result = evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.encode (x -> x + 1)
    ) catch |err| {
        try testing.expectEqual(error.UserCrash, err);
        return;
    };
    defer result.deinit();

    // Should not reach here
    try testing.expect(false);
}

test "YAML: encode crashes on function" {
    var result = evaluator.evalInline(testing.allocator,
        \\YAML = import 'YAML'
        \\YAML.encode (x -> x + 1)
    ) catch |err| {
        try testing.expectEqual(error.UserCrash, err);
        return;
    };
    defer result.deinit();

    // Should not reach here
    try testing.expect(false);
}

test "JSON: encode crashes on function in array" {
    var result = evaluator.evalInline(testing.allocator,
        \\JSON = import 'JSON'
        \\JSON.encode [1, (x -> x + 1), 3]
    ) catch |err| {
        try testing.expectEqual(error.UserCrash, err);
        return;
    };
    defer result.deinit();

    // Should not reach here
    try testing.expect(false);
}

test "YAML: encode crashes on function in object" {
    var result = evaluator.evalInline(testing.allocator,
        \\YAML = import 'YAML'
        \\YAML.encode { foo: (x -> x + 1) }
    ) catch |err| {
        try testing.expectEqual(error.UserCrash, err);
        return;
    };
    defer result.deinit();

    // Should not reach here
    try testing.expect(false);
}
