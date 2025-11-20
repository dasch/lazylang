# CLAUDE.md - Guide for Implementing Lazylang Features

This document is designed to help AI assistants (and humans) effectively implement new features in Lazylang. It provides a comprehensive overview of the architecture, codebase organization, and common implementation patterns.

## Table of Contents
1. [Project Overview](#project-overview)
2. [Architecture](#architecture)
3. [Codebase Navigation](#codebase-navigation)
4. [Implementation Patterns](#implementation-patterns)
5. [Testing Strategy](#testing-strategy)
6. [Common Tasks](#common-tasks)
7. [Code Conventions](#code-conventions)
8. [Debugging Tips](#debugging-tips)

---

## Project Overview

### What is Lazylang?

Lazylang is a pure, dynamically typed, lazy functional language for configuration management. It's inspired by Jsonnet and Erlang, with a focus on transforming objects and arrays. Key characteristics:

- **Pure functional**: No side effects in evaluation
- **Lazy evaluation**: Values computed only when needed (via thunks)
- **JSON superset**: Any JSON file is valid Lazylang
- **Configuration-first**: Designed for generating configs, manifests, etc.

### Implementation Approach

- **Language**: Zig (0.12.0)
- **Architecture**: Single-pass tree-walking interpreter with modular design
- **Memory Management**: Arena allocation (no manual free needed)
- **Lines of Code**: ~5500 total (evaluator ~2500, parser ~1600, value_format ~800, builtins ~600, tokenizer ~650, ast ~500)
- **Distribution**: Single static binary (`lazylang` and `lazylang-lsp`)

### Key Design Decisions

1. **Modular architecture**: Previously monolithic eval.zig has been refactored into focused modules (ast, tokenizer, parser, evaluator, value, value_format, module_resolver) for maintainability
2. **No separate IR**: AST is directly evaluated (tree-walking)
3. **Lazy by default for objects**: Object fields wrapped in thunks for recursive definitions
4. **Arena allocation**: Memory freed in bulk at end of evaluation
5. **No type system**: Runtime type checking only
6. **Auto-imported stdlib**: Core modules (Array, String, Math, etc.) are automatically available without explicit imports

---

## Architecture

### Pipeline: Source → Value

```
Source Code (.lazy file)
    ↓
┌─────────────────────┐
│   Tokenizer         │  Splits into tokens, tracks position
│  (tokenizer.zig)    │  Handles doc comments (///)
└──────────┬──────────┘
           ↓
┌─────────────────────┐
│   Parser            │  Recursive descent, 2-token lookahead
│   (parser.zig)      │  Operator precedence climbing
│                     │  Indentation-aware
└──────────┬──────────┘
           ↓
┌─────────────────────┐
│   AST (Expression)  │  Expression types (union)
│    (ast.zig)        │  Patterns for destructuring
└──────────┬──────────┘
           ↓
┌─────────────────────┐
│   Evaluator         │  Tree-walking with environment
│  (evaluator.zig)    │  Pattern matching, comprehensions
│                     │  Thunk forcing for laziness
└──────────┬──────────┘
           ↓
┌─────────────────────┐
│      Value          │  Runtime values (union)
│    (value.zig)      │  Integer, Float, String, Array, etc.
└─────────────────────┘
```

### Core Data Structures

#### 1. Token (ast.zig)
```zig
const TokenKind = enum {
    // 38 token types: identifiers, literals, operators, delimiters
    identifier, integer, symbol, string_literal,
    let, lambda, if_kw, then, else_kw, when, matches,
    equal, arrow, backslash, ampersand, plus, minus, ...
};

const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,  // Slice into source
    line: u32,
    column: u32,
    offset: usize,
    newlines_before: u32,
};
```

#### 2. Expression AST (ast.zig)
```zig
pub const Expression = union(enum) {
    // Literals
    integer: i64,
    boolean: bool,
    null_literal: void,
    symbol: []const u8,             // #tag
    string_literal: []const u8,

    // Variables & Functions
    identifier: []const u8,
    lambda: Lambda,                 // arg -> body
    let: Let,                       // name = value; expr
    application: Application,       // fn arg

    // Control Flow
    if_expr: If,                    // if cond then expr else expr
    when_matches: WhenMatches,      // when val matches pattern then...

    // Collections
    array: []Expression,
    tuple: []Expression,
    object: Object,
    object_extend: ObjectExtend,    // base { fields }

    // Operators
    unary: Unary,
    binary: Binary,

    // Advanced
    string_interpolation: StringInterpolation,
    array_comprehension: ArrayComprehension,
    object_comprehension: ObjectComprehension,
    field_access: FieldAccess,      // obj.field
    field_accessor: FieldAccessor,  // .field (function)
    field_projection: FieldProjection, // obj.{f1, f2}

    // Module System
    import_expr: Import,
};
```

Key nested types:
- `Lambda`: `{ parameter: Pattern, body: *Expression }`
- `Let`: `{ identifier: []const u8, value: *Expression, body: *Expression }`
- `Object`: `{ fields: []ObjectField }` where each field has `key: Expression`, `value: Expression`, `is_merge: bool`

#### 3. Pattern (ast.zig)
For destructuring in function params, let bindings, and when-matches:
```zig
pub const Pattern = union(enum) {
    identifier: []const u8,
    integer: i64,
    boolean: bool,
    null_literal: void,
    symbol: []const u8,
    tuple: []Pattern,
    array: ArrayPattern,        // [head, ...tail]
    object: ObjectPattern,      // { field1, field2 }
};
```

#### 4. Value (value.zig)
Runtime values during evaluation:
```zig
pub const Value = union(enum) {
    integer: i64,
    boolean: bool,
    null_value: void,
    symbol: []const u8,
    string: []const u8,
    array: Array,
    tuple: Tuple,
    object: Object,
    function: Function,         // Closures
    native_fn: NativeFn,        // Zig functions
};

const Function = struct {
    parameter: Pattern,
    body: *Expression,
    env: ?*const Environment,   // Closure capture
};

const NativeFn = *const fn (arena: Allocator, args: []const Value) EvalError!Value;
```

#### 5. Environment (value.zig)
Linked-list scope chain for lexical scoping:
```zig
pub const Environment = struct {
    parent: ?*const Environment,
    name: []const u8,
    value: Value,
};
```

### Module System

**Location**: module_resolver.zig, evaluator.zig:createStdlibEnvironment

**Import Resolution**:
1. Check if path is absolute or relative (starts with `.` or `/`)
2. If not, search in `LAZYLANG_PATH` environment variable (colon-separated)
3. Default search path: `stdlib/lib`
4. Append `.lazy` extension if not present
5. Read file, parse, evaluate → the result is the module value

**Auto-Imported Modules**:

Certain stdlib modules are automatically imported and available without explicit `import` statements. These are defined in the `stdlib_modules` array in `evaluator.zig`:

```zig
const stdlib_modules = [_][]const u8{ "Array", "Basics", "Float", "Math", "Object", "Range", "Result", "String", "Tuple" };
```

**Special handling**:
- **Basics module**: All exported fields are exposed as unqualified identifiers (e.g., `isInteger`, `isFloat` are available directly, not just as `Basics.isInteger`)
- **Other modules**: Available by module name (e.g., `Array.map`, `String.split`, `Range.toArray`, `Result.ok`, `Tuple.first`)

**To add a new auto-imported module**:
1. Create the module file in `stdlib/lib/ModuleName.lazy`
2. Add the module name to the `stdlib_modules` array in `evaluator.zig`
3. Rebuild and test

**No caching**: Each import re-evaluates the file (simple but inefficient)

**Circular imports**: Not currently detected (can cause infinite loops)

### Error Handling

**Location**: error_context.zig, error_reporter.zig

**Strategy**: Zig errors can't carry data, so we use a global `ErrorContext` to track:
- Source location (line, column, offset, length)
- Available identifiers (for "did you mean" suggestions)
- Levenshtein distance algorithm for fuzzy matching

**Pretty printing**: error_reporter.zig formats errors with:
- File location indicator (`--> file.lazy:10:5`)
- Source line with gutter
- Caret/underline highlighting
- Helpful suggestions

---

## Codebase Navigation

### File Structure

```
lazylang/
├── src/
│   ├── main.zig                   # CLI entry point
│   ├── cli.zig                    # Command dispatcher
│   ├── cli_error_reporting.zig    # CLI error formatting
│   │
│   ├── eval.zig                   # ⭐ Re-export layer (~350 lines)
│   ├── ast.zig                    # AST and token type definitions (~500 lines)
│   ├── tokenizer.zig              # Lexical analysis (~650 lines)
│   ├── parser.zig                 # Recursive descent parser (~1600 lines)
│   ├── evaluator.zig              # Expression evaluation (~2500 lines)
│   ├── value.zig                  # Runtime value types (~160 lines)
│   ├── value_format.zig           # Value formatting (~800 lines)
│   ├── module_resolver.zig        # Module path resolution (~120 lines)
│   ├── builtin_env.zig            # Builtin environment setup (~130 lines)
│   │
│   ├── builtins.zig               # Native function implementations (~600 lines)
│   ├── spec.zig                   # Test framework (runs *Spec.lazy files)
│   ├── docs.zig                   # Documentation generation (~500 lines)
│   ├── error_context.zig          # Error location tracking
│   ├── error_reporter.zig         # Pretty error formatting
│   ├── formatter.zig              # Code formatter
│   ├── lsp.zig                    # LSP server implementation
│   ├── lsp_main.zig               # LSP entry point
│   ├── json_rpc.zig               # JSON-RPC for LSP
│   └── json_error.zig             # JSON error handling
├── stdlib/lib/
│   ├── Array.lazy            # Array utilities
│   ├── String.lazy           # String utilities
│   ├── Math.lazy             # Math utilities
│   ├── Object.lazy           # Object utilities
│   └── Spec.lazy             # Test DSL
├── tests/
│   ├── eval/                 # Unit tests (16 files)
│   ├── examples_test.zig     # Integration tests
│   ├── cli_test.zig          # CLI tests
│   └── formatter_tests.zig   # Formatter tests
├── examples/                  # Example .lazy files
├── research/                  # Design docs
│   ├── PLAN.md               # Implementation design
│   ├── EVAL.md               # CLI evaluation notes
│   └── SYNTAX_SPEC.md        # Formal syntax spec
├── build.zig                 # Build configuration
└── README.md                 # User-facing documentation
```

### Key Files Deep Dive

#### eval.zig (~350 lines) - RE-EXPORT LAYER

**Architecture**: eval.zig is now a thin re-export layer that provides backward compatibility while the interpreter is fully modularized.

**Current structure**:
- Re-exports AST types from ast.zig
- Re-exports Tokenizer from tokenizer.zig
- Re-exports Parser from parser.zig
- Re-exports evaluator functions from evaluator.zig
- Re-exports Value types from value.zig
- Re-exports module resolver from module_resolver.zig
- Re-exports value formatting from value_format.zig

**The refactoring is complete**. The monolithic eval.zig has been split into focused modules:

#### Core Modules

- **ast.zig** (~500 lines): All AST and token type definitions
- **tokenizer.zig** (~650 lines): Complete lexical analysis implementation
- **parser.zig** (~1600 lines): Recursive descent parser with operator precedence climbing
- **evaluator.zig** (~2500 lines): Expression evaluation, pattern matching, comprehensions, module imports
- **value.zig** (~160 lines): Runtime value types (Value union, Environment, Thunk, FunctionValue, etc.)
- **value_format.zig** (~800 lines): Value formatting for JSON, YAML, pretty-print, short format
- **module_resolver.zig** (~120 lines): Module path resolution and file loading
- **builtin_env.zig** (~130 lines): Builtin environment setup (registers all native functions)

#### builtins.zig (~600 lines)

**Structure**:
- Export individual functions: `arrayLength`, `arrayFold`, `stringConcat`, `crash`, etc.
- Each follows signature: `fn(arena: Allocator, args: []const Value) EvalError!Value`
- Categories: Array (5), String (9), Math (10), Object (3), Error handling (1)

**Integration**: Registered in `createBuiltinEnvironment` (builtin_env.zig). Most have `__` prefix, except for `crash` which is directly exposed.

**Notable builtins**:
- `crash`: Takes a string message and causes a runtime error with that message. Uses thread-local storage to preserve the message across arena deallocation.

#### spec.zig (~600 lines)

**Purpose**: Custom test framework that runs Lazylang test files

**Key functions**:
- `runSpecFile`: Parse and evaluate spec file, run tests
- `runTestItem`: Execute a single test (describe/it/xit)
- `compareValues`: Deep equality for assertions

**Test format**: Tests are Lazylang objects with structure:
```
{ type: "describe", description: "...", children: [...] }
{ type: "it", description: "...", test: value_or_assertion }
```

#### docs.zig (~500 lines)

**Purpose**: Documentation generation from doc comments in stdlib files

**Key functions**:
- `extractModuleDocs`: Parse `///` doc comments from .lazy files
- `renderMarkdownToHtml`: Convert markdown to HTML with syntax highlighting
- `renderInlineMarkdown`: Handle inline markdown (backticks, bold, links)

**Important notes**:
- The markdown parser needs to gracefully handle unclosed markers (`, [, **) by resetting the index when no closing marker is found
- When adding new inline markdown features, ensure the parser doesn't go out of bounds at the end of text
- Doc comments use standard markdown with code blocks (```) and inline code (`)

---

## Implementation Patterns

### 1. Adding New Syntax

**Example**: Let's say you want to add a `loop` keyword.

**Steps**:

1. **Add token kind** (eval.zig:TokenKind)
   ```zig
   const TokenKind = enum {
       // ... existing tokens
       loop,  // Add here
   };
   ```

2. **Update tokenizer** (eval.zig:Tokenizer.next)
   - If it's a keyword, add to keyword map in `makeIdentifierOrKeyword`:
   ```zig
   inline for (.{ /* ... */, "loop" }) |keyword| { ... }
   ```

3. **Add to AST** (eval.zig:Expression)
   ```zig
   pub const Expression = union(enum) {
       // ... existing
       loop_expr: Loop,
   };

   pub const Loop = struct {
       init: *Expression,
       condition: *Expression,
       body: *Expression,
   };
   ```

4. **Add parser method** (eval.zig:Parser)
   ```zig
   fn parseLoop(self: *Parser) ParseError!Expression {
       try self.expect(.loop);
       const init = try self.parseExpression();
       try self.expect(.comma);
       const condition = try self.parseExpression();
       try self.expect(.comma);
       const body = try self.parseExpression();

       const loop_ptr = try self.arena.create(Loop);
       loop_ptr.* = .{ .init = init, .condition = condition, .body = body };
       return .{ .loop_expr = loop_ptr };
   }
   ```

   Call it from `parsePrimary` when you see the `loop` token.

5. **Add evaluator case** (eval.zig:evaluateExpression)
   ```zig
   pub fn evaluateExpression(expr: Expression, env: ?*const Environment, ...) !Value {
       return switch (expr) {
           // ... existing cases
           .loop_expr => |loop| {
               // Implement loop logic
               var current_env = env;
               var result = Value.null_value;

               // Evaluation logic here

               return result;
           },
       };
   }
   ```

6. **Write tests** (tests/eval/loop_test.zig)
   ```zig
   const eval = @import("evaluator");
   const std = @import("std");

   test "loop: basic iteration" {
       const result = try eval.evalString(
           \\loop 0, i < 3, i + 1
       , std.testing.allocator);

       try std.testing.expectEqual(@as(i64, 3), result.integer);
   }
   ```

7. **Register test** in build.zig `eval_test_files` array

### 2. Adding a New Builtin Function

**Example**: Add `String.reverse`

**Steps**:

1. **Implement in builtins.zig**:
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

2. **Register in eval.zig** (createBuiltinEnvironment):
   ```zig
   try addBuiltin(arena, &env, "__string_reverse", builtins.stringReverse);
   ```

3. **Wrap in stdlib/lib/String.lazy**:
   ```
   // String.lazy
   {
       // ... existing functions
       reverse: str -> __string_reverse str
   }
   ```

4. **Write test** (tests/eval/strings_test.zig):
   ```zig
   test "String: reverse" {
       const String = try eval.evalString(
           \\import 'String'
       , std.testing.allocator);

       const reverse = String.object.get("reverse");
       const result = try eval.applyFunction(reverse, .{ .string = "hello" }, ...);

       try std.testing.expectEqualStrings("olleh", result.string);
   }
   ```

### 3. Adding a New Operator

**Example**: Add `**` (exponentiation) operator

**Steps**:

1. **Add to BinaryOperator enum** (eval.zig):
   ```zig
   pub const BinaryOperator = enum {
       // ... existing
       power,  // **
   };
   ```

2. **Update tokenizer** (eval.zig:Tokenizer.next):
   - Handle `**` before `*`:
   ```zig
   '*' => {
       self.offset += 1;
       if (self.peek() == '*') {
           self.offset += 1;
           return self.makeToken(.double_star);  // New token kind
       }
       return self.makeToken(.star);
   },
   ```

3. **Add TokenKind**:
   ```zig
   const TokenKind = enum {
       // ... existing
       double_star,
   };
   ```

4. **Update parser precedence** (eval.zig:getPrecedence):
   ```zig
   fn getPrecedence(kind: TokenKind) u8 {
       return switch (kind) {
           // ... existing
           .double_star => 7,  // Higher than * and /
           .star, .slash => 6,
           // ...
       };
   }
   ```

5. **Map token to operator** (eval.zig:Parser.parseBinary):
   ```zig
   fn tokenToBinaryOp(kind: TokenKind) ?BinaryOperator {
       return switch (kind) {
           // ... existing
           .double_star => .power,
           // ...
       };
   }
   ```

6. **Implement evaluation** (eval.zig:evaluateExpression, binary case):
   ```zig
   .binary => |bin| {
       const left = try evaluateExpression(bin.left.*, env, ...);
       const right = try evaluateExpression(bin.right.*, env, ...);

       return switch (bin.operator) {
           // ... existing
           .power => {
               const l = try expectInteger(left);
               const r = try expectInteger(right);
               const result = std.math.pow(f64, @floatFromInt(l), @floatFromInt(r));
               return .{ .integer = @intFromFloat(result) };
           },
       };
   }
   ```

### 4. Pattern Matching Implementation

Pattern matching is already implemented. To understand or modify it:

**Key functions**:
- `matchPattern` (eval.zig:~2090): Attempts to bind a pattern to a value
- Returns `?*const Environment` (null if no match)

**How it works**:
```zig
fn matchPattern(
    pattern: Pattern,
    value: Value,
    parent_env: ?*const Environment,
    arena: Allocator
) !?*const Environment {
    return switch (pattern) {
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
        // ... other cases
    };
}
```

**Used in**:
- Lambda application (bind parameter)
- Let bindings (bind variable)
- When-matches expressions (try each pattern)

---

## Testing Strategy

### Unit Tests (Zig)

**Location**: tests/eval/*.zig

**Pattern**:
```zig
const eval = @import("evaluator");
const std = @import("std");
const testing = std.testing;

test "feature: description" {
    const result = try eval.evalString(
        \\code here
    , testing.allocator);

    try testing.expectEqual(expected, result.integer);
}
```

**Run**: `zig build test`

**Coverage**: 16 test files covering all language features

### Integration Tests (Lazylang)

**Location**: examples/*.lazy

**Pattern**: Create `.lazy` file, run with `./zig-out/bin/lazylang eval examples/foo.lazy`

**Automated**: tests/examples_test.zig runs all example files and checks they don't crash

### Spec Tests (Lazylang Test Framework)

**Location**: stdlib/tests/*Spec.lazy

**Pattern**:
```
{ describe, it, mustEq } = import 'Spec'

describe "Array" [
  describe "map" [
    it "transforms each element" (
      mustEq [2, 4, 6] (Array.map (x -> x * 2) [1, 2, 3])
    )
  ]
]
```

**Run**: `./zig-out/bin/lazylang test stdlib/tests/`

**Features**:
- Nested describe blocks
- Line-based filtering (run single test)
- Colored output
- Deep value equality

---

## Common Tasks

### Adding a Language Feature Checklist

- [ ] Add token kind (if new syntax)
- [ ] Update tokenizer (keyword or operator)
- [ ] Add to Expression AST
- [ ] Implement parser method
- [ ] Add to evaluator switch
- [ ] Write unit tests
- [ ] Update README.md documentation
- [ ] Add example file

### Adding a Builtin Function Checklist

- [ ] Implement in builtins.zig
- [ ] Register in createBuiltinEnvironment
- [ ] Wrap in stdlib (optional)
- [ ] Write tests
- [ ] Update stdlib documentation (if public API)

### Debugging a Parser Issue

1. **Add debug prints** in parser:
   ```zig
   std.debug.print("Current token: {s}\n", .{@tagName(self.current.kind)});
   ```

2. **Check token stream**: Add prints in tokenizer to see what tokens are generated

3. **Verify precedence**: Check `getPrecedence` returns correct values

4. **Test minimal case**: Isolate the failing syntax to smallest possible example

### Debugging an Evaluator Issue

1. **Print intermediate values**:
   ```zig
   std.debug.print("Value: {any}\n", .{value});
   ```

2. **Check environment**: Print current scope chain

3. **Trace evaluation**: Add prints at start of each switch case

4. **Use evalString**: Write minimal test case with `evalString`

### Running the Interpreter

**Evaluate expression**:
```bash
./zig-out/bin/lazylang eval examples/hello.lazy
```

**Run program** (expects function taking `{args, env}`):
```bash
./zig-out/bin/lazylang run script.lazy
```

**Run tests**:
```bash
./zig-out/bin/lazylang test stdlib/tests/
```

**Format code**:
```bash
./zig-out/bin/lazylang format file.lazy
```

---

## Code Conventions

### Zig Style

- **Naming**:
  - Functions: `camelCase`
  - Types: `PascalCase`
  - Constants: `SCREAMING_SNAKE_CASE`

- **Allocation**: Always pass `arena: Allocator` parameter, never free manually

- **Error handling**: Use Zig's `try` for error propagation, `catch` rarely

- **Comments**: Explain WHY, not WHAT. Code should be self-documenting.

### Lazylang Style (stdlib)

- **Indentation**: 2 spaces
- **Naming**:
  - Variables and functions: `camelCase` (e.g., `jsonString`, `toUpper`, `myValue`)
  - Modules: `PascalCase` (e.g., `Array`, `String`, `JSON`)
  - **Always use camelCase, never snake_case**
- **Operators**: Space around binary operators
- **Line length**: Prefer 80 characters, max 100
- **If-expressions**: For multiline if-then-else expressions assigned to variables, place the `if` keyword on a new line after the `=`, with `then` on the same line as the condition. Indent branches one additional level:
  ```
  result =
    if condition then
      value1
    else if condition2 then
      value2
    else
      value3
  ```
  Single-line if-expressions can remain on one line: `x = if cond then a else b`

### Error Messages

- **Be specific**: "Expected ')' after function argument" not "Unexpected token"
- **Be helpful**: Suggest corrections, show context
- **Be consistent**: Use similar phrasing for similar errors

---

## Debugging Tips

### Common Pitfalls

1. **Do block scoping limitation**: `do` blocks are converted to lambda bodies, which means they can have multiple `let` bindings but only ONE final expression. Variables defined in a do block can't be used inside nested function calls within the same expression.

   **Does NOT work**:
   ```
   it "test" do
     arr = [1, 2, 3]
     mustEq 100 (Array.length arr)
     mustEq (#ok, 1) (Array.get 0 arr)  // Error: arr not defined
   ```

   **Workaround 1 - Separate test blocks**:
   ```
   it "test length" do
     arr = [1, 2, 3]
     mustEq 100 (Array.length arr)

   it "test first element" do
     arr = [1, 2, 3]
     mustEq (#ok, 1) (Array.get 0 arr)
   ```

   **Workaround 2 - Extract to intermediate variables**:
   ```
   it "test" do
     arr = [1, 2, 3]
     len = Array.length arr
     first = Array.get 0 arr
     mustEq 100 len
     mustEq (#ok, 1) first
   ```

2. **Arena allocation**: Never store pointers outside arena lifetime. All Expression/Pattern/Value pointers must be arena-allocated.

3. **Token lookahead**: Parser has 2-token lookahead. Use `peek(0)` for next, `peek(1)` for next+1.

4. **Newline handling**: Newlines are significant for indentation but ignored in some contexts (inside parentheses). Check `newlines_before` on tokens.

5. **Environment chaining**: Always create new Environment nodes, never mutate existing ones (immutable scope chain).

6. **Pattern matching null return**: `matchPattern` returns `null` if pattern doesn't match. Don't forget to handle this case.

7. **String slicing**: Token lexemes are slices into source. Don't mutate source after tokenization.

### Useful Commands

**Build and test**:
```bash
zig build test                    # Run all tests
zig build test 2>&1 | grep FAIL   # See only failures
```

**Run interpreter**:
```bash
zig build
./zig-out/bin/lazylang eval -e "1 + 2"
```

**Quick iteration**:
```bash
# Set LAZYLANG_PATH so imports work
export LAZYLANG_PATH=./stdlib/lib

# Run examples
for file in examples/*.lazy; do
    echo "=== $file ==="
    ./zig-out/bin/lazylang eval $file
done
```

**Debug build**:
```bash
zig build -Doptimize=Debug
# Now binary has debug symbols for lldb/gdb
```

### Error Context Debugging

If you see an error without location info:

1. **Check error_context was set**: In parser/evaluator, ensure `setErrorContext` or `setErrorContextForToken` is called before returning error

2. **Check identifier registry**: For "did you mean" suggestions, ensure identifiers are registered with `registerIdentifier`

3. **Print error context**:
   ```zig
   const ctx = error_context.getLastErrorContext();
   std.debug.print("Error at line {}, col {}\n", .{ctx.line, ctx.column});
   ```

---

## Advanced Topics

### Lazy Evaluation Implementation

**Thunks**: Values that are computed on demand. **Fully implemented** - object fields are lazily evaluated using thunks.

**Implementation details**:

1. **Thunk type** (value.zig):
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

   pub const Value = union(enum) {
       // ... existing types
       thunk: *Thunk,
   };
   ```

2. **Object construction** (evaluator.zig): When creating objects, field values are wrapped in thunks instead of being eagerly evaluated:
   ```zig
   .object => |object| blk: {
       const fields = try arena.alloc(ObjectFieldValue, object.fields.len);
       for (object.fields, 0..) |field, i| {
           const key_copy = try arena.dupe(u8, field.key);
           const thunk = try arena.create(Thunk);
           thunk.* = .{
               .expr = field.value,
               .env = env,
               .current_dir = current_dir,
               .ctx = ctx,
               .state = .unevaluated,
           };
           fields[i] = .{ .key = key_copy, .value = .{ .thunk = thunk } };
       }
       break :blk Value{ .object = .{ .fields = fields } };
   }
   ```

3. **Force function** (evaluator.zig): Evaluates thunks on demand with cycle detection:
   ```zig
   pub fn force(arena: std.mem.Allocator, value: Value) EvalError!Value {
       return switch (value) {
           .thunk => |thunk| {
               switch (thunk.state) {
                   .evaluated => |v| return v,
                   .evaluating => return error.CyclicReference,
                   .unevaluated => {
                       thunk.state = .evaluating;
                       const result = try evaluateExpression(arena, thunk.expr, ...);
                       thunk.state = .{ .evaluated = result };
                       return result;
                   },
               }
           },
           else => value,
       };
   }
   ```

4. **Forcing locations**: Thunks are forced at:
   - Field access (evaluator.zig)
   - Pattern matching for object destructuring (evaluator.zig)
   - Object comprehensions when iterating over objects (evaluator.zig)
   - Object patching when merging nested objects (evaluator.zig)
   - Value formatting/printing (value_format.zig)

**Benefits**:
- Allows recursive object definitions
- Prevents errors in unused fields from crashing the program
- Improves performance by only computing values that are accessed
- Enables conditional configuration patterns

### Module Caching

Currently each import re-evaluates. To add caching:

1. Add cache to evaluation context:
   ```zig
   const ModuleCache = std.StringHashMap(Value);
   ```

2. Check cache in `importModule`:
   ```zig
   fn importModule(path: []const u8, cache: *ModuleCache, ...) !Value {
       if (cache.get(path)) |cached| return cached;

       // ... existing load logic

       try cache.put(path, result);
       return result;
   }
   ```

3. Detect circular imports with "loading" set

### Performance Optimization

Current performance is acceptable for config files. If needed:

1. **Add bytecode compiler**: Compile AST to bytecode, use VM instead of tree-walking
2. **Inline primitives**: Don't allocate for integers, use tagged pointers
3. **Optimize string concatenation**: Use rope data structure
4. **Cache module imports**: See above

Don't optimize prematurely. Profile first.

---

## Quick Reference

### File → Purpose Map

| File | Purpose | Modify When |
|------|---------|------------|
| eval.zig | Re-export layer | Never (use specific modules below) |
| ast.zig | AST and token definitions | Adding new syntax constructs |
| tokenizer.zig | Lexical analysis | Adding new tokens or keywords |
| parser.zig | Parsing | Adding new syntax or operators |
| evaluator.zig | Expression evaluation | Adding evaluation logic, comprehensions |
| value.zig | Runtime value types | Adding new value types |
| value_format.zig | Value formatting | Changing JSON/YAML/pretty-print output |
| module_resolver.zig | Module loading | Changing module search paths |
| builtin_env.zig | Builtin registration | Adding auto-imported modules |
| builtins.zig | Native functions | Adding builtin functions |
| spec.zig | Test framework | Modifying test runner behavior |
| docs.zig | Documentation generation | Changing doc comment parsing or HTML output |
| error_context.zig | Error tracking | Changing error location tracking |
| error_reporter.zig | Error formatting | Changing error display |
| cli.zig | Command parsing | Adding CLI commands |
| main.zig | CLI entry | Changing CLI interface |
| lsp.zig | LSP server | Adding LSP features |
| formatter.zig | Code formatter | Changing code formatting |

### Common Functions

| Function | Location | Purpose |
|----------|----------|---------|
| `evalString` | eval.zig | Parse and evaluate a string |
| `evaluateExpression` | eval.zig | Main evaluation dispatch |
| `matchPattern` | eval.zig | Pattern matching for destructuring |
| `expectInteger` / `expectString` / etc | eval.zig | Type checking helpers |
| `createBuiltinEnvironment` | eval.zig | Setup stdlib |
| `importModule` | eval.zig | Load .lazy file |
| `reportError` | error_reporter.zig | Pretty print error |

### Expression Types Quick Reference

| Type | Example | AST Node |
|------|---------|----------|
| Integer | `42` | `integer: i64` |
| String | `"hello"` | `string_literal: []const u8` |
| Symbol | `#ok` | `symbol: []const u8` |
| Lambda | `x -> x + 1` | `lambda: Lambda` |
| Let | `x = 5; x` | `let: Let` |
| If | `if x > 0 then 1 else 0` | `if_expr: If` |
| Array | `[1, 2, 3]` | `array: []Expression` |
| Object | `{ x: 1 }` | `object: Object` |
| Application | `f x` | `application: Application` |
| Field Access | `obj.field` | `field_access: FieldAccess` |
| Comprehension | `[x * 2 for x in xs]` | `array_comprehension: ...` |

---

## Conclusion

This guide should help you navigate and modify the Lazylang codebase effectively. Key takeaways:

1. **eval.zig is the core**: Tokenizer, parser, evaluator all in one place
2. **Arena allocation**: No manual memory management
3. **Tree-walking**: AST directly evaluated, no IR
4. **Add features incrementally**: Token → AST → Parser → Evaluator → Tests
5. **Test thoroughly**: Unit tests + integration tests + spec tests
6. **Follow conventions**: Zig style, clear error messages, helpful documentation

When in doubt, look at existing similar features and follow the same pattern. The codebase is designed to be straightforward and hackable.

Happy hacking!
