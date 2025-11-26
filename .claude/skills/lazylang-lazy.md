---
skill: lazylang-lazy
description: Guide for writing Lazylang (.lazy) code with proper style, formatting, and patterns
---

# Lazylang Code Writing Guide

This skill helps you write idiomatic Lazylang code with proper style, formatting, and common patterns.

## Critical Rule: Always Format Code!

**ALWAYS** run the formatter on any Lazylang code you write:

```bash
./bin/lazy format file.lazy
```

If the user requests different formatting than what the formatter produces:
1. Create a test fixture in `tests/fixtures/formatter/`
2. Put desired formatted output as `//` comments at the top
3. Put unformatted input code below
4. Run `zig build test` to verify
5. If formatter fails, update `src/formatter.zig` to handle the new case

## Style Conventions

### Naming
- **Variables and functions**: `camelCase` (e.g., `jsonString`, `toUpper`, `myValue`)
- **Modules**: `PascalCase` (e.g., `Array`, `String`, `JSON`)
- **NEVER use snake_case**

### Indentation & Line Length
- **Indentation**: 2 spaces
- **Line length**: Prefer 80 characters, max 100

### Spacing Rules

**Operators**: Space around binary operators
```
a + b
x * y
a == b
```

**Unary operators**: No space after
```
!flag
-5
```

**Arrows**: Space around arrows
```
x -> x + 1
x -> y -> x + y
```

**Commas**: Space after commas
```
[1, 2, 3]
(a, b, c)
```

**Colons**: Space after colons in objects
```
{ x: 10, y: 20 }
```

**Function application**: Space between function and argument
```
f x
map fn list
Array.map (x -> x * 2) numbers
```

## Collections

### Objects

**Single-line**: Space inside braces
```
person = { name: "Alice", age: 30 }
```

**Empty**: Two spaces inside braces
```
empty = {  }
```

**Multi-line**: No spaces inside braces, indent fields
```
person = {
  name: "Alice"
  age: 30
  email: "alice@example.com"
}
```

**Object projections**: Space inside braces
```
coords = obj.{ x, y, z }
```

### Arrays

**Single-line**: No space inside brackets
```
numbers = [1, 2, 3]
```

**Multi-line**: No spaces inside brackets, indent elements
```
items = [
  1
  2
  3
]
```

### Comprehensions

**Single-line**: Keep on one line
```
squared = [x * x for x in numbers]
filtered = [x for x in items when x > 5]
```

**Multi-line**: Put `for` on separate line, indent properly
```
squared = [
  x * x
  for x in numbers
]

objComp = {
  x: x * 2
  for x in range
}
```

## Functions & Lambdas

**Simple lambda**: Space around arrow
```
double = x -> x * 2
```

**Multi-parameter**: Chain arrows
```
add = x -> y -> x + y
```

**Application**: Space between function and arguments
```
result = map (x -> x * 2) [1, 2, 3]
value = fold add 0 numbers
```

## Control Flow

### If-Expressions

**Single-line**: Keep on one line
```
x = if cond then a else b
```

**Multi-line**: Place `if` on new line after `=`, indent branches
```
result =
  if condition then
    value1
  else if condition2 then
    value2
  else
    value3
```

### Let Bindings

**Multi-line parenthesized blocks**: Omit semicolons between statements
```
result = (
  x = 10
  y = 20
  x + y
)
```

Note: Semicolons in source are removed by formatter in multi-line parens

### Pattern Matching

**Basic syntax**: Use `when expr matches` for pattern matching
```
status = when result matches
  (#ok, value) then value
  (#error, msg) then 0
  otherwise null
```

**Multiple patterns**: Each pattern uses `pattern then expression`
```
itemType = "describe"
action = when itemType matches
  "describe" then "run suite"
  "it" then "run test"
  "xit" then "skip test"
  otherwise "unknown"
```

**Single-expression arms**: No parentheses needed
```
classify = when x matches
  0 then "zero"
  1 then "one"
  otherwise "many"
```

**Multi-expression arms**: MUST use parentheses to group expressions
```
process = when itemType matches
  "describe" then (
    description = getDescription item;
    children = getChildren item;
    processChildren description children
  )
  "it" then (
    test = getTest item;
    runTest test
  )
  otherwise { result: "unknown" }
```

**Key points**:
- Use `otherwise` for default case (not `_` or `else`)
- Parentheses required for multi-line/multi-expression arms
- Inside parentheses, use semicolons between expressions (formatter keeps them)
- Without parentheses, parser expects single expression

## Do Blocks

**Indentation**: 2 spaces
```
it "test" do
  arr = [1, 2, 3]
  mustEq 3 (Array.length arr)
```

**CRITICAL LIMITATION**: Do blocks convert to lambda bodies with ONE final expression. Variables can't be used in nested function calls.

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
  mustEq 3 (Array.length arr)

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
  mustEq 3 len
  mustEq (#ok, 1) first
```

## Module System

### Auto-Imported Modules

Available without explicit `import`:
- `Array` - Array utilities (`.map`, `.filter`, `.fold`, `.length`, etc.)
- `Basics` - Basic utilities (fields exposed as unqualified identifiers)
- `Float` - Float operations
- `Math` - Math functions
- `Object` - Object utilities
- `Range` - Range operations
- `Result` - Result type (`#ok`, `#error`)
- `String` - String utilities
- `Tuple` - Tuple operations

**Basics module special handling**: All fields exposed directly
```
// These work without qualification:
isInteger 42      // instead of Basics.isInteger
isFloat 3.14      // instead of Basics.isFloat
```

**Other modules**: Use qualified names
```
Array.map (x -> x * 2) [1, 2, 3]
String.split "," "a,b,c"
Range.toArray (Range.new 1 10)
```

### Importing Custom Modules

**Relative imports**:
```
config = import './config.lazy'
utils = import '../lib/utils.lazy'
```

**Absolute imports** (from `LAZYLANG_PATH`):
```
MyModule = import 'MyModule'
```

**Import destructuring**:
```
{ describe, it, mustEq } = import 'Spec'
```

## Testing with Spec

### Test Structure

```
{ describe, it, mustEq, mustNotEq } = import 'Spec'

describe "Module Name" [
  describe "function name" [
    it "does something" (
      mustEq expected actual
    )

    it "handles edge case" (
      mustNotEq unexpected result
    )
  ]
]
```

### Assertions

- `mustEq expected actual` - Deep equality check
- `mustNotEq unexpected actual` - Deep inequality check

### Running Tests

```bash
# Run all tests
./bin/lazy spec stdlib/tests/

# Run tests in specific directory
./bin/lazy spec stdlib/tests/ArraySpec.lazy
```

## Formatter Tests

### Creating Formatter Test Fixtures

**Location**: `tests/fixtures/formatter/*.lazy`

**Format**: Expected output as `//` comments, followed by input code
```
// squared = [x * x for x in numbers]
// filtered = [x for x in items when x > 5]

squared = [x*x for x in numbers]
filtered = [x for x in items when x>5]
```

**Multi-line example**:
```
// longerSquared = [
//   x * x
//   for x in numbers
// ]

longerSquared = [
  x * x for x in numbers ]
```

**Running formatter tests**:
```bash
zig build test
```

## Common Patterns

### Array Operations

```
numbers = [1, 2, 3, 4, 5]

doubled = Array.map (x -> x * 2) numbers
evens = Array.filter (x -> x % 2 == 0) numbers
sum = Array.fold (acc -> x -> acc + x) 0 numbers
first = Array.get 0 numbers  // Returns (#ok, value) or (#error, msg)
```

### Object Operations

```
person = { name: "Alice", age: 30 }

// Field access
name = person.name

// Field projection
initials = person.{ firstName, lastName }

// Object extension
updated = person { age: 31, email: "alice@example.com" }

// Object merging
defaults = { port: 8080, host: "localhost" }
config = defaults { port: 3000 }
```

### String Operations

```
str = "hello, world"

upper = String.toUpper str
lower = String.toLower str
parts = String.split ", " str
joined = String.join ", " ["a", "b", "c"]
length = String.length str
```

### Result Type

```
// Success
result = (#ok, value)

// Error
result = (#error, "Something went wrong")

// Pattern matching (see "Pattern Matching" section for details)
formatted = when result matches
  (#ok, v) then "Success: " ++ String.show v
  (#error, msg) then "Error: " ++ msg
  otherwise "Unknown"
```

## Common Pitfalls

1. **Do block scoping**: See "Do Blocks" section above
2. **Lazy evaluation**: Object fields computed on access (can hide errors)
3. **Module imports**: No caching, each import re-evaluates
4. **Circular imports**: Not detected (causes infinite loops)
5. **No type checking**: Runtime errors only

## Best Practices

1. **Always format**: Run `./bin/lazy format` before committing
2. **Use comprehensions**: More idiomatic than manual recursion
3. **Leverage auto-imports**: Use `Array`, `String`, etc. modules
4. **Test with Spec**: Write comprehensive test suites
5. **Avoid deep nesting**: Use `let` bindings to flatten code
6. **Use Result type**: For operations that can fail
7. **Document with comments**: Use `//` for inline, `///` for doc comments

## Example: Complete Module

```
///
/// Utilities for working with user data
///

{ isString } = import 'Basics'

{
  /// Validates a user object
  validate: user ->
    when user matches
      { name, email } when isString name && isString email ->
        (#ok, user)
      _ ->
        (#error, "Invalid user format")

  /// Formats a user for display
  format: user ->
    name = user.name
    email = user.email
    name ++ " <" ++ email ++ ">"

  /// Creates a new user
  create: name -> email -> {
    name: name
    email: email
    createdAt: 1234567890
  }
}
```

---

**Remember**: When writing Lazylang code, prioritize readability and always run the formatter!
