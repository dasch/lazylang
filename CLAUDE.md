# CLAUDE.md - Lazylang Development Guide

Quick reference for AI assistants and developers working on Lazylang. For detailed implementation guidance, use the Claude Code skills:
- **Writing .lazy files**: Use `/lazylang-lazy` skill
- **Writing .zig interpreter code**: Use `/lazylang-zig` skill

## Project Overview

**Lazylang** is a pure, lazy functional language for configuration management inspired by Jsonnet and Erlang.

**Key Characteristics**:
- Pure functional (no side effects)
- Lazy evaluation (values computed on demand via thunks)
- JSON superset (any JSON is valid Lazylang)
- Single-pass tree-walking interpreter
- Built in Zig 0.12.0 with arena allocation
- ~5500 LOC: evaluator ~2500, parser ~1600, value_format ~800, builtins ~600, tokenizer ~650, ast ~500

## Architecture Pipeline

```
Source Code (.lazy)
    ↓
Tokenizer (tokenizer.zig)     → Tokens with position tracking
    ↓
Parser (parser.zig)           → AST via recursive descent
    ↓
Evaluator (evaluator.zig)     → Tree-walking with environments
    ↓
Value (value.zig)             → Runtime values (Integer, String, Array, Object, Function, etc.)
```

### Core Data Structures

**Token** (ast.zig): 38 token types with lexeme, line, column, offset
**Expression** (ast.zig): AST union (literals, lambdas, let, if, arrays, objects, operators, comprehensions, imports)
**Pattern** (ast.zig): For destructuring (identifier, tuple, array, object)
**Value** (value.zig): Runtime union (integer, string, array, tuple, object, function, native_fn, thunk)
**Environment** (value.zig): Linked-list scope chain for lexical scoping

### Module System

**Auto-Imported Modules** (defined in evaluator.zig):
- `Array`, `Basics`, `Float`, `Math`, `Object`, `Range`, `Result`, `String`, `Tuple`
- **Basics** fields are exposed as unqualified identifiers
- Others available by module name (e.g., `Array.map`)

**Import Resolution**:
1. Check if absolute or relative (starts with `.` or `/`)
2. Search `LAZYLANG_PATH` environment variable (colon-separated)
3. Default: `stdlib/lib`
4. Append `.lazy` if not present

**Limitations**: No caching (each import re-evaluates), no circular import detection

## File Structure

```
src/
├── eval.zig                  # Re-export layer (~350 lines)
├── ast.zig                   # AST & token definitions (~500)
├── tokenizer.zig             # Lexical analysis (~650)
├── parser.zig                # Recursive descent (~1600)
├── evaluator.zig             # Expression evaluation (~2500)
├── value.zig                 # Runtime values (~160)
├── value_format.zig          # Formatting: JSON, YAML, pretty-print (~800)
├── module_resolver.zig       # Module path resolution (~120)
├── builtin_env.zig           # Builtin registration (~130)
├── builtins.zig              # Native functions (~600)
├── formatter.zig             # Code formatter
├── spec.zig                  # Test framework
├── docs.zig                  # Doc generation (~500)
├── error_context.zig         # Error tracking
├── error_reporter.zig        # Pretty error formatting
├── cli.zig                   # Command dispatcher
├── main.zig                  # CLI entry
└── lsp*.zig                  # LSP server

stdlib/lib/                   # Auto-imported modules
tests/eval/                   # Unit tests (16 files)
tests/fixtures/formatter/     # Formatter test fixtures
examples/                     # Example .lazy files
```

## Quick Reference Tables

### File → Purpose

| File | Purpose | Modify When |
|------|---------|-------------|
| ast.zig | AST & token definitions | New syntax constructs |
| tokenizer.zig | Lexical analysis | New tokens/keywords |
| parser.zig | Parsing | New syntax/operators |
| evaluator.zig | Expression evaluation | Evaluation logic, comprehensions |
| value.zig | Runtime value types | New value types |
| value_format.zig | Value formatting | JSON/YAML output |
| module_resolver.zig | Module loading | Module search paths |
| builtin_env.zig | Builtin registration | Auto-imported modules |
| builtins.zig | Native functions | Builtin functions |
| formatter.zig | Code formatter | Formatting rules |

### Common Functions

| Function | Location | Purpose |
|----------|----------|---------|
| `evalString` | eval.zig | Parse and evaluate string |
| `evaluateExpression` | evaluator.zig | Main evaluation dispatch |
| `matchPattern` | evaluator.zig | Pattern matching |
| `createBuiltinEnvironment` | builtin_env.zig | Setup stdlib |
| `importModule` | evaluator.zig | Load .lazy file |
| `formatSource` | formatter.zig | Format code |

### Expression Types

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
| Comprehension | `[x * 2 for x in xs]` | `array_comprehension: ...` |

## Testing

**Unit Tests (Zig)**: `tests/eval/*.zig` - Run with `zig build test`
**Spec Tests (Lazylang)**: `stdlib/tests/*Spec.lazy` - Run with `./bin/lazy spec stdlib/tests/`
**Formatter Tests**: `tests/fixtures/formatter/*.lazy` - Fixture-based with `//` comment format
**Integration Tests**: `examples/*.lazy` - Automated via `tests/examples_test.zig`

## Error Handling

**Global ErrorContext** (error_context.zig): Tracks source location, available identifiers, Levenshtein distance for "did you mean" suggestions
**Pretty Printing** (error_reporter.zig): File location, source line with gutter, caret highlighting

## Lazy Evaluation

**Thunks** (value.zig): Object fields wrapped in thunks, forced on access
**States**: unevaluated → evaluating (cycle detection) → evaluated
**Forced at**: Field access, pattern matching, object comprehensions, value formatting

## CLI Commands

```bash
./bin/lazy eval file.lazy       # Evaluate expression
./bin/lazy run script.lazy      # Run program (expects fn taking {args, env})
./bin/lazy spec tests/          # Run spec tests
./bin/lazy format file.lazy     # Format code
```

## Key Design Principles

1. **Modular architecture**: Focused modules (was monolithic eval.zig)
2. **Arena allocation**: Bulk memory deallocation, no manual free
3. **Tree-walking**: AST directly evaluated, no IR
4. **Lazy objects**: Fields wrapped in thunks for recursive definitions
5. **No type system**: Runtime type checking only

## Development Workflow

**CRITICAL: Always run `make` before committing or considering a task complete.**
The `make` command runs all tests (Zig unit tests, Lazylang spec tests, formatter tests, and docs generation). Never commit without a successful `make` run.

For **implementing Lazylang features** (syntax, operators, builtins):
→ Use `/lazylang-zig` skill for detailed Zig implementation patterns

For **writing Lazylang code** (stdlib, examples, tests):
→ Use `/lazylang-lazy` skill for style conventions and formatter usage

## Skills Overview

- **`/lazylang-lazy`**: Lazylang style guide, formatter usage, common patterns, testing
- **`/lazylang-zig`**: Zig implementation patterns, adding syntax/operators/builtins, debugging

---

**Quick Start**: Load the appropriate skill based on your task. The skills contain detailed implementation patterns, checklists, and examples.
