const std = @import("std");
const evaluator = @import("evaluator");
const testing = std.testing;

test "YAML: parse simple string" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "hello"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "hello") != null);
}

test "YAML: parse integer" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "42"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "42") != null);
}

test "YAML: parse boolean true" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "true"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "true") != null);
}

test "YAML: parse boolean false" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "false"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "false") != null);
}

test "YAML: parse null" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "null"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "null") != null);
}

test "YAML: parse flow array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "[1, 2, 3]"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "[1, 2, 3]") != null);
}

test "YAML: parse block array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "- apple\n- banana\n- cherry"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "apple") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "banana") != null);
}

test "YAML: parse simple object" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "name: John\nage: 30"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "name") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "John") != null);
}

test "YAML: parse flow object" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "{name: Alice, age: 25}"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "name") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "Alice") != null);
}

test "YAML: encode string" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_encode "hello"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "hello") != null);
}

test "YAML: encode integer" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_encode 42
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "42") != null);
}

test "YAML: encode boolean" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_encode true
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "true") != null);
}

test "YAML: encode null" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_encode null
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "null") != null);
}

test "YAML: encode array" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_encode [1, 2, 3]
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "1") != null);
}

test "YAML: encode object" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_encode { name: "John", age: 30 }
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "name") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "John") != null);
}

test "YAML: handles special strings correctly" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "value: test"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "test") != null);
}

test "YAML: round-trip simple values" {
    var result = try evaluator.evalInline(testing.allocator,
        \\value = { name: "Alice", age: 30 }
        \\yaml = __yaml_encode value
        \\(#ok, parsed) = __yaml_parse yaml
        \\parsed.name == value.name
    );
    defer result.deinit();

    try testing.expectEqualStrings("true", result.text);
}

test "YAML: parse string with spaces" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "hello world"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "hello world") != null);
}

test "YAML: parse empty string returns null" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse ""
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "null") != null);
}

// Note: Encoding functions throws an error (TypeMismatch) rather than returning an error tuple.
// This is intentional - encoding a function is a programming error, not expected user input.

test "YAML: parse flow objects with multiple fields" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "{server: localhost, port: 8080}"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "server") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "localhost") != null);
}

test "YAML: encode and parse arrays preserve order" {
    var result = try evaluator.evalInline(testing.allocator,
        \\original = [1, 2, 3, 4, 5]
        \\yaml = __yaml_encode original
        \\(#ok, parsed) = __yaml_parse yaml
        \\parsed
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "[1, 2, 3, 4, 5]") != null);
}

test "YAML: parse array with mixed simple types" {
    var result = try evaluator.evalInline(testing.allocator,
        \\__yaml_parse "[1, hello, true, null]"
    );
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, result.text, "#ok") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "1") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "true") != null);
}
