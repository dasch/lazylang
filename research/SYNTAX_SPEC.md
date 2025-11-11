# Lazylang Syntax Specification

## 1. Source Files and Lexical Structure
- Lazylang files use the `.lazy` extension and every valid JSON document is a valid Lazylang module, preserving JSON lexical rules for numbers, strings, booleans, and `null`. 【F:README.md†L7-L16】
- Single-line comments begin with `//` and continue to the end of the line. These comments are ignored by the parser and have no semantic meaning. 【F:README.md†L317-L334】
- Documentation comments begin with `///` and continue to the end of the line. These comments are Markdown-formatted and are attached to the construct they document (the next non-comment token or declaration). Multiple consecutive documentation comments are combined into a single documentation block. Documentation comments are stored alongside the value they document and can be extracted for generating documentation. 【F:README.md†L336-L362】
- Whitespace is significant in multi-line expressions: subsequent lines in an expression block must be indented by two spaces. Semicolons can be used as explicit separators when not relying on indentation. 【F:README.md†L145-L162】

## 2. Primitive Values and Tags
- Primitive literals mirror JSON (numbers, strings, booleans, `null`) and can appear anywhere an expression is expected. 【F:README.md†L13-L16】
- Strings support interpolation of variables and expressions using `$identifier` for simple variable references and `${expression}` for complex expressions. 【F:README.md†L18-L46】
- Tags are atom-like symbols introduced with `#` and behave as unique symbolic values. 【F:README.md†L248-L255】

## 3. Bindings and Expressions
- A variable binding uses `name = expression`. Bindings can appear at the module top level or inside expression blocks. 【F:README.md†L11-L16】【F:README.md†L145-L154】
- An expression block consists of zero or more bindings (each introduced with `=`) followed by a final expression whose value is returned. 【F:README.md†L145-L154】
- Bindings separated by newlines require two-space indentation; semicolons offer an inline alternative. 【F:README.md†L145-L162】
- `where` clauses attach trailing bindings to a preceding expression; those bindings share the same indentation rule. 【F:README.md†L224-L236】
- `do` blocks rebind operator precedence so that the block’s indented bindings/expression are evaluated and supplied as the final argument to the preceding function call. 【F:README.md†L238-L244】
- Pipeline operator `\` feeds the value of the preceding expression as the last argument to the following function call chain. 【F:README.md†L208-L222】

## 4. Tuples
- Tuple literals use parentheses with comma-separated elements. They can mix heterogeneous values and support positional destructuring. 【F:README.md†L18-L24】【F:README.md†L183-L188】

## 5. Arrays
- Array literals use square brackets; commas are optional when each element is on its own line. 【F:README.md†L123-L132】
- Array comprehensions combine a body expression with one or more `for` clauses and optional `when` filters. The body runs for every iteration of the nested loops that satisfy the filters. 【F:README.md†L134-L142】

## 6. Objects
- Object literals use `{}` with fields separated by newlines or commas. Field keys may be bare identifiers or quoted strings. 【F:README.md†L28-L48】
- Nested object literals can omit colons before child objects to indicate structural merging in later extensions. 【F:README.md†L70-L79】
- Object extension syntax `base { ... }` produces a copy of `base` with field overrides or patches. Fields written with `field: value` replace the field entirely, while nested blocks without a colon merge into the existing value. 【F:README.md†L49-L69】
- The binary merge operator `&` merges two objects, respecting the colon omission semantics for nested merges. 【F:README.md†L81-L85】
- Dynamic field definitions wrap an expression in `[...]` as the key. `null` keys are skipped, arrays of keys emit multiple fields, and array comprehensions can generate batches of keys. 【F:README.md†L87-L103】
- Object comprehensions mirror array comprehensions, allowing computed `[key]: value` entries derived from arrays or objects via `for` clauses. 【F:README.md†L105-L119】

## 7. Functions and Application
- Functions are defined with `->`. Multiple parameters are modeled via currying, chaining successive single-argument arrows. 【F:README.md†L166-L177】
- Function arguments can be destructured directly in the parameter position, supporting pattern matching on tuples, arrays, or objects. 【F:README.md†L190-L194】

## 8. Control Flow and Lazy Evaluation Constructs
- Conditional expressions use the `if-then-else` syntax: `if condition then expr else expr`. The condition must evaluate to a boolean value at runtime; a `TypeMismatch` error occurs if it doesn't. These expressions can appear in dynamic field computations, runtime modules, and anywhere an expression is expected. 【F:README.md†L164-L185】
- The `else` branch is optional. When omitted (`if condition then expr`), the expression evaluates to `null` if the condition is false. This allows for concise conditional field definitions and nullable results. 【F:README.md†L181-L185】
- Chained if-else-if patterns are supported by nesting if expressions in the else branch: `if a then 1 else if b then 2 else 3`. This provides multi-way branching for decision logic. 【F:README.md†L171-L176】
- `when` expressions perform pattern matching with a sequence of `pattern then expression` branches and an optional `otherwise` catch-all. Failing to match without `otherwise` causes a runtime crash. 【F:README.md†L196-L207】
- Comprehension clauses also support `when` filters to discard iterations. 【F:README.md†L137-L142】

## 9. Pattern Matching and Destructuring
- Tuple patterns `(a, b)` bind positional elements; array patterns support head/rest syntax `[head, ...tail]`; object patterns `{ field1, field2 }` bind selected keys. 【F:README.md†L183-L202】
- Pattern matching is available in assignments, function parameters, and `when ... matches` expressions. 【F:README.md†L183-L203】

## 10. Modules and Imports
- Modules correspond to `.lazy` files. `import 'path/to/Module'` loads a module using a string path. Specific values can be imported via destructuring: `{ a, b } = import 'path/to/Module'`. 【F:README.md†L269-L283】
- A module's exported value is the result of evaluating its top-level expression, which can be any Lazylang value (commonly an object aggregating public functions). 【F:README.md†L285-L292】

## 11. Error-Handling Conventions
- Functions that may fail are expected to return tagged tuples such as `(#ok, value)` or a tag like `#noSuchKey`, to be handled via pattern matching. 【F:README.md†L257-L265】

## 12. Execution Model (CLI Context)
- Lazylang programs are evaluated via the `lazy` CLI. `eval` executes pure, non-functional modules; `run` expects the module to evaluate to a function receiving `{ args, env }` and can perform effects such as manifest generation. 【F:README.md†L313-L345】

This specification consolidates the syntax features described in the README so that they can later be implemented consistently across the language parser, evaluator, and tooling.
