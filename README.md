# Lazylang
A pure, dynamically typed, lazy functional language for configuration management.

## Basics
The language is inspired by Jsonnet and Erlang, with a syntax that optimizes for transforming objects and arrays.

It is a superset of JSON; any JSON file is a valid Lazylang file.

Lazylang files have the extension `.lazy`.

Variables are defined using `=`:
```
x = 42
name = "John Doe"
isActive = true
```

## Tuples

Tuples are defined using parentheses:
```
point = (10, 20)
record = ("Alice", "female", 30)
```

## Objects

Objects are defined like this:
```
obj = {
  one: 1
  two: 2

  rest {
    three: 3
  }
}
```

Note how a comma is not required at the end of each line; rather, newlines separate fields. Commas are allowed, though, including after the last field.

They can also be defined on a single line like this:
```
obj = { one: 1, two: 2, rest: { three: 3 } }
```

Fields can be quoted strings or unquoted identifiers.

An object can be extended like this:
```
obj2 = obj1 {
  one: "1"
}
```

The `<field>:` syntax overwrites the field.

An object can also be "patched" like this:

```
obj3 = obj1 {
  rest {
    four: 4
  },
}
```

The `<field>` syntax (without the colon) modifies the value of the field rather than overwrites it.

It's allowed, and encouraged, to omit colons when defining new objects as well:

```
obj4 = {
  foo: "bar"
  baz {
    bim: "bum"
  }
}
```

Doing this allows the object to be *merged* into other objects, using the extension syntax or the object merge operator `&`:

```
obj1 & obj2
```

### Dynamically computed fields

```
{
  // A null dynamic field will result in no field being added.
  [null]: 42

  // This is useful for conditional fields, since `if ... then ...` expressions can return null.
  [if foo then 'bar']: 42

  // This results in `{ bim: 42, boo: 42 }`.
  ['bim', 'boo', null]: 42

  // This results in `{ KEY1: 42, KEY2: 42 }`. Multiple fields can be created by returning an array.
  [toUpper(key) for key in keys]: 42
}
```

### Object comprehensions

```
{
  [user.name]: user.address
  for user in users  // `users` is an array of objects with `name` and `address` fields
}
```

```
{
  [key]: modify(value)
  for (key, value) in otherObject // `otherObject` is an object
}
```

## Arrays

```
arr1 = [1, 2, 3]

// Newlines can be used instead of commas
arr2 = [
  'one'
  'two'
  'three'
]
```

### Array comprehensions

```
[
  doSomething(thing, otherThing)
  for thing in things
  for otherThing in otherThings
  when thing.isActive
]
```

## Expressions

An expression consists of zero or more variable assignments followed by an actual expression:

```
person =
  name = "Joe"
  age = 42
  { name, age }
```

An expression spanning multiple lines must be indented by two spaces.

Instead of newlines, semicolons can be used to separate variable assignments:

```
name = "Joe"; age = 42; { name, age }
```

## Conditional expressions

Conditional expressions use the `if-then-else` syntax:

```
status = if isActive then "online" else "offline"

result = if score > 90 then
  "excellent"
else if score > 70 then
  "good"
else
  "needs improvement"
```

The condition must evaluate to a boolean value; a runtime error occurs if it doesn't.

The `else` branch is optional. If omitted and the condition is false, the expression evaluates to `null`:

```
message = if hasError then "Error occurred"  // null if hasError is false
```

## Functions

Functions are defined using the `->` operator:

```
add = (a, b) -> a + b
greet = name -> "Hello, " + name + "!"
```

Functions can only take one argument, but can easily be chained together:

```
addThreeNumbers = a -> b -> c -> a + b + c
```

## Pattern matching and destructuring

Lazylang supports pattern matching and destructuring for many data types, including objects, arrays, and tuples.

Destructuring can be used in variable assignments:
```
(first, last) = ("John", "Doe")
{ first, last } = { first: "John", last: "Doe" }
[head, ...tail] = [1, 2, 3, 4]
```

The argument of a function definition can also be destructured:

```
fullname = { first, last } -> first + ' ' + last
```

Pattern matching can be used in `when` expressions:

```
when value matches
  (x, y) then ...
  [head, ...tail] then ...
  { key1, key2 } then ...
  otherwise ...
```

The `otherwise` keyword will match anything. If left out, a value that doesn't match any pattern will result in a crash.

## Expression pipelining

The `\` operator allows piping the result of an expression into another expression as the last argument:

```
fullname
\ String.split " "
\ Array.first
```

This corresponds to:

```
Array.first (String.split " " fullname)
```

## `where` and `do` syntax

`where` allows defining variables *after* an expression:

```
bill + tip where
  bill = ...
  tip = bill * 0.2

center = (width, heiht) -> (x, y) where
  x = (screenWidth - width) / 2
  y = (screenHeight - height) / 2
```

`do` changes precedence; instead of `foo x (y = ...; z y)` you can do:

```
  foo x do
    y = ...
    x y
```

There is also special syntax for function arguments:

## Tags

Tags are symbolic values with fixed identity, similar to atoms in Erlang or symbols in Ruby. They are identifiers prefixed with a single `#` character:

```
#name
#region
```

## Error handling

Errors are handled similar to Erlang; code that may fail should evaluate to a tuple `(#ok, value)` rather than just `value`, and on failure should use some other value, e.g. `#noSuchKey`. Then, pattern matching can be used to handle errors:

```
when Object.find "team" resource matches
  (#ok, team) then team
  #noSuchKey then defaultTeam
```

## Modules and imports

Modules are `.lazy` files that can be imported using the `import` keyword:

```
Phone = import 'lib/Phone'

Phone.format { countryCode: "+1", number: "5551234" }
```

It is also possible to import specific values from a module:

```
{ format, parse } = import 'lib/Phone'

format { countryCode: "+1", number: "5551234" }
```

In general, files/modules should export a single object containing all public values. However, a module can export any single value; the value of a module is the expression of the file, of which there can only be one.

```
// Phone.lazy
{ format, parse } where
  format = phone -> ...
  parse = str -> ...
```

## Testing

```
{ describe, it, mustEq } = import Spec

describe "List" [
  describe "concat" [
    it "concatenates two lists" (mustEq [1, 2, 3, 4] result) where
      result = List.concat [1, 2] [3, 4]
  ]

  describe "sort" [
    it "sorts the items in the list" do
      items = [3, 1, 2]
      mustEq [1, 2, 3] (List.sort items)
  ]
]
```

## The `lazy` CLI

The `lazy` command line tool can evaluate and execute Lazylang files, and is used for a variety of tasks, such as running tests.

```
lazy eval path/to/file.lazy
lazy run path/to/file.lazy --manifest output/dir
lazy test tests/
```

### Evaluation and execution

Two modes: `eval` and `run`.
* `eval` is guaranteed idempotent; it can evaluate files, but the file values cannot contain functions.
* `run` is more flexible; a single file is passed, and the top level value must be a function that takes as argument the system context.
In both cases, passing the `--manifest` argument will make Lazylang expect the result to be an object with string file path keys and string values, and will write the values to the paths.

### `run` example
When a module is executed with `lazylang run`, the top-level expression must be a function that takes a single object as argument.

The object has two fields:
* `args`: an array of command line arguments passed to the program (excluding the program name)
* `env`: an object containing the environment variables

```
// Execute with `lazylang run hello.lazy

{ args, env } ->
  if env.HELLO == 'world' then
    ...
  else
    ...
    target = args[1]
```
