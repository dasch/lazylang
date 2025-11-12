const std = @import("std");
const evaluator = @import("evaluator");
const testing = std.testing;

test "JSON: parse simple string" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse '"hello"'
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "hello") != null);
}

test "JSON: parse integer" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse "42"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "42") != null);
}

test "JSON: parse negative integer" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse "-123"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "-123") != null);
}

test "JSON: parse boolean true" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse "true"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "true") != null);
}

test "JSON: parse boolean false" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse "false"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "false") != null);
}

test "JSON: parse null" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse "null"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "null") != null);
}

test "JSON: parse array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse "[1, 2, 3]"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "[1, 2, 3]") != null);
}

test "JSON: parse nested array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse "[[1, 2], [3, 4]]"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "[[1, 2], [3, 4]]") != null);
}

test "JSON: parse object" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse '{"name": "John", "age": 30}'
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "name") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "John") != null);
}

test "JSON: parse nested object" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse '{"user": {"name": "Alice", "age": 25}}'
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "user") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "Alice") != null);
}

test "JSON: parse empty array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse "[]"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "[]") != null);
}

test "JSON: parse empty object" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse "{}"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "{}") != null);
}

test "JSON: parse with whitespace" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse '  { "x" : 42 }  '
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "42") != null);
}

test "JSON: parse invalid JSON returns error" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse "{ invalid }"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#error") != null);
}

test "JSON: parse empty string returns null" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse ""
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "null") != null);
}

test "JSON: encode string" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_encode "hello"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "hello") != null);
}

test "JSON: encode integer" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_encode 42
    );
    defer result.deinit();

    try testing.expectEqualStrings("\"42\"", result.text);
}

test "JSON: encode boolean" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_encode true
    );
    defer result.deinit();

    try testing.expectEqualStrings("\"true\"", result.text);
}

test "JSON: encode null" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_encode null
    );
    defer result.deinit();

    try testing.expectEqualStrings("\"null\"", result.text);
}

test "JSON: encode array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_encode [1, 2, 3]
    );
    defer result.deinit();

    try testing.expectEqualStrings("\"[1, 2, 3]\"", result.text);
}

test "JSON: encode object" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_encode { name: "John", age: 30 }
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "name") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "John") != null);
}

test "JSON: encode symbol" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_encode #success
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "success") != null);
}

test "JSON: encode tuple" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_encode (1, 2, 3)
    );
    defer result.deinit();

    try testing.expectEqualStrings("\"[1, 2, 3]\"", result.text);
}

test "JSON: encode nested structures" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_encode { items: [1, 2, 3], meta: { count: 3 } }
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "items") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "meta") != null);
}

test "JSON: encode string with special characters" {
    var result = try evaluator.evalInline(testing.allocator,
        \\str = "line1\nline2\ttab"
        \\__json_encode str
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "line1") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "line2") != null);
}

test "JSON: round-trip simple values" {
    var result = try evaluator.evalInline(testing.allocator,
        \\value = { name: "Alice", age: 30 }
        \\json = __json_encode value
        \\(#ok, parsed) = __json_parse json
        \\parsed.name == value.name
    );
    defer result.deinit();

    try testing.expectEqualStrings("true", result.text);
}

test "JSON: round-trip array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\original = [1, 2, 3, 4, 5]
        \\json = __json_encode original
        \\(#ok, parsed) = __json_parse json
        \\parsed == original
    );
    defer result.deinit();

    try testing.expectEqualStrings("true", result.text);
}

test "JSON: parse mixed types in array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse '[1, "hello", true, null]'
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "1") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "true") != null);
}

test "JSON: parse string with unicode escapes" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__json_parse '"hello world"'
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "hello world") != null);
}
