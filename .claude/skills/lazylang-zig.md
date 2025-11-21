---
skill: lazylang-zig
description: Guide for implementing Lazylang interpreter features in Zig
---

# Lazylang Zig Implementation Guide

This skill helps you implement new features, fix bugs, and extend the Lazylang interpreter written in Zig.

## Zig Style Conventions

### Naming
- **Functions**: `camelCase` (e.g., `evaluateExpression`, `parseLoop`)
- **Types**: `PascalCase` (e.g., `Expression`, `TokenKind`, `Value`)
- **Constants**: `SCREAMING_SNAKE_CASE` (e.g., `MAX_DEPTH`, `DEFAULT_PORT`)

### Memory Management
- **Always use arena allocator**: Pass `arena: Allocator` parameter
- **Never free manually**: Arena frees everything in bulk
- **All AST nodes**: Must be arena-allocated (Expression, Pattern, etc.)

### Error Handling
- **Use `try`** for error propagation
- **Rarely use `catch`** (only when recovering from error)
- **Set error context**: Call `setErrorContext` or `setErrorContextForToken` before returning errors

### Comments
- **Explain WHY, not WHAT**: Code should be self-documenting
- **Only comment non-obvious logic**: Complex algorithms, workarounds, edge cases

## Architecture Quick Reference

**Pipeline**: Tokenizer → Parser → Evaluator → Value

**Key files**:
- `ast.zig` - Token and Expression types
- `tokenizer.zig` - Lexical analysis
- `parser.zig` - Recursive descent parsing
- `evaluator.zig` - Tree-walking evaluation
- `value.zig` - Runtime value types
- `builtins.zig` - Native functions

## Adding New Syntax

### Example: Add a `loop` keyword

**Checklist**:
- [ ] Add token kind (`ast.zig`)
- [ ] Update tokenizer keyword list (`tokenizer.zig`)
- [ ] Add AST node type (`ast.zig`)
- [ ] Implement parser method (`parser.zig`)
- [ ] Add evaluator case (`evaluator.zig`)
- [ ] Write unit tests (`tests/eval/*.zig`)
- [ ] Update README.md with new syntax
- [ ] Add example file and run formatter

### Step-by-Step Implementation

**1. Add token kind** (ast.zig)
```zig
pub const TokenKind = enum {
    // ... existing tokens
    loop,  // Add here
    // ...
};
```

**2. Update tokenizer** (tokenizer.zig)

Find `makeIdentifierOrKeyword` function and add to keyword list:
```zig
inline for (.{
    "let", "if", "then", "else", "when", "matches",
    "import", "do", "for", "in", "loop",  // Add here
}) |keyword| {
    if (std.mem.eql(u8, self.source[start..self.offset], keyword)) {
        return self.makeToken(@field(TokenKind, keyword));
    }
}
```

**3. Add AST node** (ast.zig)
```zig
pub const Expression = union(enum) {
    // ... existing variants
    loop_expr: *Loop,
    // ...
};

pub const Loop = struct {
    init: *Expression,
    condition: *Expression,
    body: *Expression,
};
```

**4. Implement parser method** (parser.zig)

Add method:
```zig
fn parseLoop(self: *Parser) ParseError!Expression {
    try self.expect(.loop);
    const init = try self.parseExpression();
    try self.expect(.comma);
    const condition = try self.parseExpression();
    try self.expect(.comma);
    const body = try self.parseExpression();

    const loop_ptr = try self.arena.create(Loop);
    loop_ptr.* = .{
        .init = try self.arena.create(Expression),
        .condition = try self.arena.create(Expression),
        .body = try self.arena.create(Expression),
    };
    loop_ptr.init.* = init;
    loop_ptr.condition.* = condition;
    loop_ptr.body.* = body;

    return .{ .loop_expr = loop_ptr };
}
```

Call from `parsePrimary`:
```zig
fn parsePrimary(self: *Parser) ParseError!Expression {
    return switch (self.current.kind) {
        .loop => self.parseLoop(),
        // ... other cases
    };
}
```

**5. Add evaluator case** (evaluator.zig)
```zig
pub fn evaluateExpression(
    arena: Allocator,
    expr: Expression,
    env: ?*const Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
) EvalError!Value {
    return switch (expr) {
        .loop_expr => |loop| {
            // Implement loop logic
            var result = Value.null_value;
            var current_env = env;

            // Evaluate init
            const init_val = try evaluateExpression(
                arena, loop.init.*, current_env, current_dir, ctx
            );

            // Loop while condition is true
            while (true) {
                const cond = try evaluateExpression(
                    arena, loop.condition.*, current_env, current_dir, ctx
                );

                const is_true = switch (cond) {
                    .boolean => |b| b,
                    else => return error.TypeMismatch,
                };

                if (!is_true) break;

                result = try evaluateExpression(
                    arena, loop.body.*, current_env, current_dir, ctx
                );
            }

            return result;
        },
        // ... other cases
    };
}
```

**6. Write tests** (tests/eval/loop_test.zig)
```zig
const eval = @import("eval");
const std = @import("std");
const testing = std.testing;

test "loop: basic iteration" {
    const result = try eval.evalString(
        \\counter = 0
        \\loop counter < 3 do
        \\  counter = counter + 1
    , testing.allocator);

    try testing.expectEqual(@as(i64, 3), result.integer);
}

test "loop: empty body" {
    const result = try eval.evalString(
        \\loop false do 42
    , testing.allocator);

    try testing.expectEqual(Value.null_value, result);
}
```

**7. Register test** in `build.zig`

Add to `eval_test_files` array:
```zig
const eval_test_files = [_][]const u8{
    // ... existing tests
    "tests/eval/loop_test.zig",
};
```

## Adding a New Operator

### Example: Add `**` (exponentiation)

**Checklist**:
- [ ] Add to BinaryOperator enum (`ast.zig`)
- [ ] Add token kind (`ast.zig`)
- [ ] Update tokenizer (`tokenizer.zig`)
- [ ] Update parser precedence (`parser.zig`)
- [ ] Map token to operator (`parser.zig`)
- [ ] Implement evaluation (`evaluator.zig`)
- [ ] Write tests

### Implementation

**1. Add to BinaryOperator enum** (ast.zig)
```zig
pub const BinaryOperator = enum {
    add, subtract, multiply, divide, modulo,
    power,  // Add here
    equal, not_equal, less_than, less_equal,
    greater_than, greater_equal,
    and_op, or_op, concat, pipe,
};
```

**2. Add TokenKind** (ast.zig)
```zig
pub const TokenKind = enum {
    // ... existing
    double_star,  // **
    // ...
};
```

**3. Update tokenizer** (tokenizer.zig)

In `next` method, handle `**` before `*`:
```zig
'*' => {
    self.offset += 1;
    if (self.peek() == '*') {
        self.offset += 1;
        return self.makeToken(.double_star);
    }
    return self.makeToken(.star);
},
```

**4. Update parser precedence** (parser.zig)
```zig
fn getPrecedence(kind: TokenKind) u8 {
    return switch (kind) {
        .pipe => 1,
        .or_kw => 2,
        .and_kw => 3,
        .equal_equal, .bang_equal, .less, .less_equal,
        .greater, .greater_equal => 4,
        .plus_plus => 5,
        .plus, .minus => 6,
        .star, .slash, .percent => 7,
        .double_star => 8,  // Higher than multiplication
        else => 0,
    };
}
```

**5. Map token to operator** (parser.zig)
```zig
fn tokenToBinaryOp(kind: TokenKind) ?BinaryOperator {
    return switch (kind) {
        .plus => .add,
        .minus => .subtract,
        .star => .multiply,
        .slash => .divide,
        .percent => .modulo,
        .double_star => .power,  // Add here
        // ... rest
    };
}
```

**6. Implement evaluation** (evaluator.zig)
```zig
.binary => |bin| {
    const left = try evaluateExpression(arena, bin.left.*, env, current_dir, ctx);
    const right = try evaluateExpression(arena, bin.right.*, env, current_dir, ctx);

    return switch (bin.operator) {
        .power => {
            const l = switch (left) {
                .integer => |i| @as(f64, @floatFromInt(i)),
                .float => |f| f,
                else => return error.TypeMismatch,
            };
            const r = switch (right) {
                .integer => |i| @as(f64, @floatFromInt(i)),
                .float => |f| f,
                else => return error.TypeMismatch,
            };
            const result = std.math.pow(f64, l, r);
            return .{ .float = result };
        },
        // ... other operators
    };
}
```

## Adding a New Builtin Function

### Example: Add `String.reverse`

**Checklist**:
- [ ] Implement function in `builtins.zig`
- [ ] Register in `builtin_env.zig`
- [ ] Wrap in stdlib module (optional, e.g., `stdlib/lib/String.lazy`)
- [ ] Write tests
- [ ] Update stdlib documentation (if public API)

### Implementation

**1. Implement in builtins.zig**
```zig
pub fn stringReverse(arena: Allocator, args: []const Value) EvalError!Value {
    if (args.len != 1) return error.WrongNumberOfArguments;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    // Allocate new string
    const reversed = try arena.alloc(u8, str.len);
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        reversed[i] = str[str.len - 1 - i];
    }

    return .{ .string = reversed };
}
```

**Signature pattern**: All builtins follow this signature:
```zig
pub fn functionName(arena: Allocator, args: []const Value) EvalError!Value
```

**2. Register in builtin_env.zig**

In `createBuiltinEnvironment`:
```zig
pub fn createBuiltinEnvironment(arena: Allocator) !?*Environment {
    var env: ?*Environment = null;

    // ... existing builtins
    try addBuiltin(arena, &env, "__string_reverse", builtins.stringReverse);

    return env;
}
```

Note: Use `__` prefix for internal builtins that will be wrapped by stdlib

**3. Wrap in stdlib** (stdlib/lib/String.lazy)
```
{
  // ... existing functions
  reverse: str -> __string_reverse str
}
```

**4. Write tests** (tests/eval/strings_test.zig)
```zig
test "String: reverse" {
    const result = try eval.evalString(
        \\String.reverse "hello"
    , std.testing.allocator);

    try std.testing.expectEqualStrings("olleh", result.string);
}
```

## Testing Patterns

### Unit Test Structure

**Location**: `tests/eval/*.zig`

**Pattern**:
```zig
const eval = @import("eval");
const std = @import("std");
const testing = std.testing;

test "feature: description" {
    const result = try eval.evalString(
        \\code here
    , testing.allocator);

    try testing.expectEqual(expected, result.integer);
}
```

### Running Tests

```bash
# Run all tests
zig build test

# See only failures
zig build test 2>&1 | grep FAIL
```

## Debugging Tips

### Common Pitfalls

1. **Arena allocation**: Never store pointers outside arena lifetime
2. **Token lookahead**: Parser has 2-token lookahead (use `peek(0)` and `peek(1)`)
3. **Newline handling**: Check `newlines_before` on tokens for indentation
4. **Environment chaining**: Always create new Environment nodes, never mutate
5. **Pattern matching null return**: `matchPattern` returns `null` if no match
6. **String slicing**: Token lexemes are slices into source (don't mutate source)

### Debug Prints

**In parser**:
```zig
std.debug.print("Current token: {s}\n", .{@tagName(self.current.kind)});
```

**In evaluator**:
```zig
std.debug.print("Value: {any}\n", .{value});
```

### Error Context

Always set error context before returning errors:

**For tokens**:
```zig
error_context.setErrorContextForToken(token);
return error.UnexpectedToken;
```

**For expressions**:
```zig
error_context.setErrorContext(line, column, offset, length);
return error.EvaluationError;
```

### Debugging Parser Issues

1. Add debug prints to see token stream
2. Check `getPrecedence` returns correct values
3. Test with minimal failing case
4. Verify tokenizer produces expected tokens

### Debugging Evaluator Issues

1. Print intermediate values
2. Check environment scope chain
3. Trace evaluation with prints at each switch case
4. Use `evalString` for minimal test cases

## Pattern Matching Implementation

Pattern matching is fully implemented. Key function:

**matchPattern** (evaluator.zig):
```zig
fn matchPattern(
    pattern: Pattern,
    value: Value,
    parent_env: ?*const Environment,
    arena: Allocator,
) !?*const Environment
```

Returns `?*const Environment`:
- Non-null with bindings if match succeeds
- `null` if pattern doesn't match value

**Used in**:
- Lambda application (bind parameters)
- Let bindings (bind variables)
- When-matches expressions (try each pattern)

**Example**:
```zig
.identifier => |name| {
    // Bind identifier to value
    const env = try arena.create(Environment);
    env.* = .{ .parent = parent_env, .name = name, .value = value };
    return env;
},
.tuple => |patterns| {
    // Match each element
    const tuple = try expectTuple(value);
    if (patterns.len != tuple.elements.len) return null;

    var env = parent_env;
    for (patterns, tuple.elements) |pat, elem| {
        env = try matchPattern(pat, elem, env, arena) orelse return null;
    }
    return env;
},
```

## Module System Implementation

**Auto-Imported Modules** (evaluator.zig):

```zig
const stdlib_modules = [_][]const u8{
    "Array", "Basics", "Float", "Math",
    "Object", "Range", "Result", "String", "Tuple"
};
```

**To add new auto-imported module**:
1. Create `stdlib/lib/ModuleName.lazy`
2. Add module name to `stdlib_modules` array
3. Rebuild and test

**Import resolution** (module_resolver.zig):
- Checks if path is absolute/relative
- Searches `LAZYLANG_PATH` environment variable
- Falls back to `stdlib/lib`
- Appends `.lazy` extension if missing

## Advanced Topics

### Lazy Evaluation (Thunks)

**Thunk type** (value.zig):
```zig
pub const ThunkState = union(enum) {
    unevaluated,
    evaluating,      // Cycle detection
    evaluated: Value,
};

pub const Thunk = struct {
    expr: *Expression,
    env: ?*Environment,
    current_dir: ?[]const u8,
    ctx: *const EvalContext,
    state: ThunkState,
};
```

**Forcing thunks** (evaluator.zig):
```zig
pub fn force(arena: Allocator, value: Value) EvalError!Value {
    return switch (value) {
        .thunk => |thunk| {
            switch (thunk.state) {
                .evaluated => |v| return v,
                .evaluating => return error.CyclicReference,
                .unevaluated => {
                    thunk.state = .evaluating;
                    const result = try evaluateExpression(...);
                    thunk.state = .{ .evaluated = result };
                    return result;
                },
            }
        },
        else => value,
    };
}
```

**Thunks forced at**:
- Field access
- Pattern matching for object destructuring
- Object comprehensions
- Object patching
- Value formatting

### Module Caching (Future Enhancement)

Currently not implemented. To add:

1. Add cache to evaluation context:
```zig
const ModuleCache = std.StringHashMap(Value);
```

2. Check cache in `importModule`:
```zig
if (cache.get(path)) |cached| return cached;
// ... evaluate
try cache.put(path, result);
```

3. Detect circular imports with "loading" set

## Useful Commands

**Build and run**:
```bash
zig build
./bin/lazy eval examples/hello.lazy
```

**Quick iteration**:
```bash
export LAZYLANG_PATH=./stdlib/lib

for file in examples/*.lazy; do
    echo "=== $file ==="
    ./bin/lazy eval $file
done
```

**Debug build**:
```bash
zig build -Doptimize=Debug
# Now has debug symbols for lldb/gdb
```

## Error Messages

**Be specific**: "Expected ')' after function argument" not "Unexpected token"
**Be helpful**: Suggest corrections, show context
**Be consistent**: Use similar phrasing for similar errors

## Implementation Checklists

### Adding Language Feature
- [ ] Add token kind (if new syntax)
- [ ] Update tokenizer (keyword or operator)
- [ ] Add to Expression AST
- [ ] Implement parser method
- [ ] Add to evaluator switch
- [ ] Write unit tests
- [ ] Update README.md
- [ ] Add example file
- [ ] Run formatter on example

### Adding Builtin Function
- [ ] Implement in builtins.zig
- [ ] Register in builtin_env.zig
- [ ] Wrap in stdlib (optional)
- [ ] Write tests
- [ ] Update stdlib docs (if public)

### Debugging Checklist
- [ ] Add debug prints
- [ ] Check error context is set
- [ ] Test with minimal case
- [ ] Verify token stream
- [ ] Check precedence table
- [ ] Trace evaluation flow

---

**Remember**: When implementing features, follow existing patterns in the codebase. Test thoroughly and set error context before returning errors!
