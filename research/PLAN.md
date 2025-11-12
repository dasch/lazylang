# Lazylang Implementation Design

## Goal
Create a simple, fast interpreter for Lazylang using a straightforward, modern approach.

## Implementation Language: Zig

**Why Zig**:
- Simple, readable syntax - no hidden control flow
- Compiles to fast native code
- Manual memory management with allocators (explicit, safe)
- Single binary distribution (static linking)
- Excellent cross-compilation
- Small runtime, no GC pauses

**Not going with**:
- Go: Runtime overhead, GC pauses, verbose error handling
- OCaml/Haskell: Niche, harder for others to contribute
- Rust: Borrow checker complexity, slower compile times
- C/C++: Too low-level, easy to make memory mistakes

## Architecture: Tree-Walking Interpreter

**Why tree-walking**:
- Simplest to implement (~2000 lines for full interpreter)
- No bytecode compiler needed
- Easy to debug (AST directly maps to source)
- Performance is fine for a config/scripting language
- Can add bytecode layer later if needed

**Not going with**:
- Bytecode VM: Adds ~1000 lines of complexity, only needed for performance-critical loops
- JIT compilation: Massive overkill for a config language

## Pipeline

```
Source Code (.lazy file)
    ↓
┌─────────────────────┐
│   Lexer/Tokenizer   │  Split into tokens, track indentation
└──────────┬──────────┘
           ↓
┌─────────────────────┐
│       Parser        │  Build AST, handle precedence
└──────────┬──────────┘
           ↓
┌─────────────────────┐
│   AST (in memory)   │  Immutable tree structure
└──────────┬──────────┘
           ↓
┌─────────────────────┐
│     Evaluator       │  Walk AST, produce values
│   (tree-walking)    │  Handle laziness with thunks
└──────────┬──────────┘
           ↓
      Value Result
```

## Core Data Structures

### 1. Token (Lexer Output)
```zig
const TokenType = enum {
    // Literals
    number, string, true, false, null, tag,
    // Identifiers & keywords
    ident, import, for, in, when, where, do, let,
    if_kw, then, else_kw, matches,
    // Operators
    equal, arrow, backslash, ampersand, plus, minus, star, slash,
    dot, colon, semicolon, comma,
    // Delimiters
    lparen, rparen, lbrace, rbrace, lbracket, rbracket,
    // Special
    newline, indent, dedent, eof,
};

const Token = struct {
    type: TokenType,
    lexeme: []const u8,  // slice into source
    line: u32,
    col: u32,
};
```

### 2. AST Nodes
```zig
const Expr = union(enum) {
    // Literals
    number: f64,
    string: []const u8,
    boolean: bool,
    null_lit,
    tag: []const u8,

    // Collections
    array: []Expr,
    object: []Field,
    tuple: []Expr,

    // Variables
    ident: []const u8,
    var_decl: struct { name: []const u8, value: *Expr },

    // Functions
    lambda: struct { param: []const u8, body: *Expr },
    call: struct { callee: *Expr, arg: *Expr },

    // Operators
    binary: struct { op: BinOp, left: *Expr, right: *Expr },
    pipeline: struct { value: *Expr, stages: []*Expr },

    // Object operations
    field_access: struct { object: *Expr, field: []const u8 },
    object_extend: struct { base: *Expr, fields: []Field },

    // Comprehensions
    array_comp: struct { expr: *Expr, clauses: []CompClause },
    object_comp: struct { key: *Expr, value: *Expr, clauses: []CompClause },

    // Control flow
    if_then_else: struct { cond: *Expr, then_: *Expr, else_: ?*Expr },
    when_matches: struct { value: *Expr, cases: []MatchCase },

    // Other
    import_expr: struct { path: []const u8, fields: ?[][]const u8 },
    block: []Expr,  // sequence with bindings
};

const Field = struct {
    key: FieldKey,
    value: Expr,
    is_patch: bool,  // true if no colon (merge), false if colon (overwrite)
};

const FieldKey = union(enum) {
    static: []const u8,
    dynamic: Expr,
};
```

### 3. Runtime Values
```zig
const Value = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    null_val,
    tag: []const u8,
    array: ArrayList(Value),
    object: StringHashMap(Value),
    tuple: []Value,
    function: Function,
    thunk: *Thunk,  // Lazy value
};

const Function = struct {
    param: []const u8,
    body: *Expr,
    closure: *Environment,
    is_native: bool,
    native_fn: ?*const fn(Value) anyerror!Value,
};

const Thunk = struct {
    expr: *Expr,
    env: *Environment,
    state: union(enum) {
        unevaluated,
        evaluating,  // cycle detection
        evaluated: Value,
    },
};
```

### 4. Environment (Scope)
```zig
const Environment = struct {
    bindings: StringHashMap(Value),
    parent: ?*Environment,
    allocator: Allocator,
};
```

## Lazy Evaluation Strategy

**Status**: ✅ **IMPLEMENTED** - Object fields are lazily evaluated using thunks.

**Key insight**: Not everything needs to be lazy. Only make lazy what needs to be lazy.

### What's lazy (wrapped in thunks):
- ✅ **Object field values** (for recursive definitions and conditional fields) - IMPLEMENTED
- ❌ Array elements (not implemented - arrays are evaluated eagerly)
- ✅ **Function bodies** (already lazy by nature) - IMPLEMENTED
- ❌ Comprehension elements (not implemented - comprehensions are evaluated eagerly)

### What's strict (evaluated immediately):
- Function arguments (we're call-by-value for simplicity)
- Operators (arithmetic, comparison)
- Control flow conditions (if, when)
- Array elements
- Comprehension bodies

### Thunk forcing:
```zig
fn force(value: Value, eval: *Evaluator) !Value {
    return switch (value) {
        .thunk => |thunk| {
            switch (thunk.state) {
                .evaluated => |v| v,
                .evaluating => error.CyclicReference,
                .unevaluated => {
                    thunk.state = .evaluating;
                    const result = try eval.eval(thunk.expr, thunk.env);
                    thunk.state = .{ .evaluated = result };
                    return result;
                },
            }
        },
        else => value,
    };
}
```

## Parser Design

**Approach**: Recursive descent with operator precedence

### Precedence levels (lowest to highest):
1. Declarations (`x = ...`)
2. `where` clauses
3. Pipeline (`\`)
4. Logical (`and`, `or`)
5. Comparison (`==`, `!=`, `<`, `>`, etc.)
6. Merge (`&`)
7. Additive (`+`, `-`)
8. Multiplicative (`*`, `/`)
9. Function call (application)
10. Field access (`.`)
11. Atoms (literals, identifiers, parentheses)

### Indentation handling:
- Lexer emits `indent`, `dedent`, and `newline` tokens
- Parser uses these to determine block boundaries
- Newlines can substitute for commas in arrays/objects
- Indent level tracks nesting depth

### Key parsing challenges:

**1. Object syntax**:
```
{
  foo: 1        // colon = overwrite
  bar { x: 2 }  // no colon = patch/merge
}
```
Parse by looking ahead: if next token is `{`, it's a patch.

**2. Function currying**:
```
f = a -> b -> c -> a + b + c
```
Parse right-to-left: `a -> (b -> (c -> (a + b + c)))`

**3. Pipeline**:
```
x \ f \ g  means  g(f(x))
```
Parse as left-associative, evaluate right-to-left.

**4. Comprehensions**:
```
[ expr for x in xs for y in ys when cond ]
```
Parse multiple `for` and `when` clauses.

## Module System

### Import resolution:
```
import lib.Phone  →  lib/Phone.lazy
import lib.Phone.{ format }  →  lib/Phone.lazy, extract field
```

### Module loading:
1. Resolve import path to file path
2. Check cache - if loaded, return cached value
3. Read source file
4. Parse → AST
5. Evaluate AST (result is the module value)
6. Cache result
7. Return value (or extract specific fields)

### Cycle detection:
- Keep a `Set<string>` of "currently loading" modules
- If we try to load a module already in the set → cycle error

```zig
const ModuleLoader = struct {
    cache: StringHashMap(Value),
    loading: StringHashSet,

    fn load(self: *Self, path: []const u8) !Value {
        if (self.cache.get(path)) |cached| return cached;
        if (self.loading.contains(path)) return error.CircularImport;

        try self.loading.put(path, {});
        defer _ = self.loading.remove(path);

        const source = try readFile(path);
        const ast = try parse(source);
        const value = try eval(ast);

        try self.cache.put(path, value);
        return value;
    }
};
```

## Standard Library

Implement as native Zig functions bound into the global environment.

### Core modules:
- **String**: `split`, `join`, `upper`, `lower`, `trim`, `length`
- **Array**: `map`, `filter`, `fold`, `length`, `first`, `last`, `concat`
- **Object**: `keys`, `values`, `find`, `merge`, `mapValues`
- **Math**: `floor`, `ceil`, `round`, `abs`, `sqrt`

### Implementation:
```zig
fn arrayMap(args: []Value, eval: *Evaluator) !Value {
    const func = args[0];
    const array = try force(args[1]);
    var result = ArrayList(Value).init(eval.allocator);
    for (array.array.items) |item| {
        const mapped = try applyFunction(func, item, eval);
        try result.append(mapped);
    }
    return Value{ .array = result };
}

// Bind into environment:
try global_env.define("map", .{ .function = .{
    .native_fn = arrayMap,
    .is_native = true,
    ...
}});
```

## CLI Implementation

### Commands:
```
lazy eval <file>                  # Evaluate, print JSON result
lazy eval <file> --manifest <dir> # Write object fields to files
lazy run <file>                   # Execute with system context
lazy test <path>                  # Run tests
```

### Manifest mode:
```zig
fn writeManifest(value: Value, dir: []const u8) !void {
    if (value != .object) return error.ManifestRequiresObject;

    for (value.object.items()) |entry| {
        const path = try fs.path.join(allocator, &[_][]const u8{ dir, entry.key });
        const content = try valueToString(entry.value);
        try fs.writeFile(path, content);
    }
}
```

### Run mode:
```zig
fn runMode(file: []const u8, manifest: ?[]const u8) !void {
    const source = try fs.readFile(file);
    const ast = try parse(source);
    const module = try eval(ast);

    // Module must be a function
    if (module != .function) return error.RunRequiresFunction;

    // Create system context
    const ctx = Value{ .object = .{
        "args" => argsArray(),
        "env" => envObject(),
    }};

    const result = try applyFunction(module, ctx);

    if (manifest) |dir| {
        try writeManifest(result, dir);
    } else {
        try printValue(result);
    }
}
```

## Error Handling

### Error types:
```zig
const LazyError = error{
    // Lexer
    UnterminatedString,
    InvalidNumber,
    UnexpectedCharacter,

    // Parser
    UnexpectedToken,
    InvalidSyntax,
    IndentationError,

    // Runtime
    UndefinedVariable,
    TypeError,
    DivisionByZero,
    CyclicReference,
    PatternMatchFailure,

    // Module
    ImportNotFound,
    CircularImport,

    // Manifest
    ManifestRequiresObject,
    ManifestValueMustBeString,
};
```

### Error reporting:
```zig
fn reportError(err: LazyError, token: Token, message: []const u8) void {
    std.debug.print("Error at {}:{}: {s}\n", .{
        token.line,
        token.col,
        message,
    });
    // TODO: Show source line with caret pointer
}
```

### Runtime error builtin:
✅ **IMPLEMENTED** - `crash` builtin function

The `crash` function takes a string message and causes a runtime error:
```
crash "Something went wrong!"
```

**Implementation notes**:
- Uses thread-local storage to preserve error message across arena deallocation
- Message is freed when `clearUserCrashMessage()` is called after reporting
- Works seamlessly with lazy evaluation - errors only trigger when accessed

## Implementation Order

### Phase 1: Core interpreter (get something running)
1. Lexer for basic tokens (numbers, strings, identifiers, operators)
2. Parser for expressions (literals, binary ops, variables)
3. Basic evaluator (arithmetic, variables)
4. Simple REPL or file evaluator

### Phase 2: Functions and laziness
5. Parse and evaluate lambdas
6. Function application
7. Implement thunks
8. Currying

### Phase 3: Collections
9. Arrays (literals, comprehensions)
10. Objects (literals, field access)
11. Tuples
12. Object extension/patching

### Phase 4: Advanced features
13. Pattern matching (`when...matches`)
14. Pipeline operator
15. `where` and `do` syntax
16. Comprehensions with multiple clauses

### Phase 5: Module system
17. Import parsing
18. Module loading and caching
19. Circular import detection

### Phase 6: Standard library
20. String functions
21. Array functions
22. Object functions
23. Math functions

### Phase 7: CLI and tooling
24. Command line parser
25. Manifest generation
26. Test runner
27. Better error messages

## Testing Strategy

### Unit tests (Zig's built-in testing):
```zig
test "lexer: basic tokens" {
    const source = "x = 42";
    var lexer = Lexer.init(testing.allocator, source);

    const tok1 = try lexer.next();
    try testing.expectEqual(.ident, tok1.type);

    const tok2 = try lexer.next();
    try testing.expectEqual(.equal, tok2.type);

    const tok3 = try lexer.next();
    try testing.expectEqual(.number, tok3.type);
}

test "eval: arithmetic" {
    const source = "21 + 21";
    const result = try evalString(source);
    try testing.expectEqual(@as(f64, 42), result.number);
}
```

### Integration tests:
- Put `.lazy` files in `tests/`
- Run each file, check output matches `.expected` file

### Example programs:
Create comprehensive examples showing all features.

## Why This Design is Straightforward

1. **Tree-walking**: No bytecode indirection, AST is the IR
2. **Thunks**: Simple lazy evaluation, easy to understand
3. **Manual memory**: Zig allocators make tracking explicit but safe
4. **Recursive descent**: Parser is straightforward, one function per grammar rule
5. **Dynamic typing**: No type checker needed, just runtime checks
6. **Single-pass**: No complex multi-pass compilation

## Performance Expectations

- Parsing: ~10MB/s (fast enough)
- Evaluation: ~1M ops/s for arithmetic (fast enough for configs)
- Memory: <50MB for typical config files
- Binary size: ~500KB statically linked

If performance becomes an issue later, we can:
1. Add bytecode compilation
2. Optimize hot paths
3. Use more efficient data structures

But start simple. Optimize only when needed.

## File Structure

```
src/
  main.zig          # CLI entry point
  lexer.zig         # Tokenization
  token.zig         # Token types
  parser.zig        # AST construction
  ast.zig           # AST node definitions
  eval.zig          # Evaluation engine
  value.zig         # Runtime value types
  env.zig           # Environment/scope
  module.zig        # Module loading
  stdlib.zig        # Standard library
  error.zig         # Error types

tests/
  lexer_test.zig
  parser_test.zig
  eval_test.zig
  examples/
    *.lazy

build.zig           # Build configuration
```

## Build Configuration

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "lazy",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
```

## Summary

**Simple, modern, fast approach**:
- Language: Zig
- Architecture: Tree-walking interpreter
- Lazy evaluation: Thunk-based with memoization
- Parser: Hand-written recursive descent
- Memory: Explicit allocators
- Distribution: Single static binary

This design avoids overengineering while being fast enough for a config language. Start simple, add complexity only when proven necessary.
