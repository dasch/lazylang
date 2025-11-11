# Lazylang Style Guide

This document describes the canonical formatting style for Lazylang code.

## General Principles

- Use 2 spaces for indentation (never tabs)
- Prefer newlines over commas for separating elements
- Use blank lines to separate logical groups
- Multi-line expressions must be indented by 2 spaces

## Variables

Variables are defined with `=` on a single line when the value is simple:

```
name = "Alice"
age = 30
isActive = true
```

When the right-hand side is complex or multi-line, indent by 2 spaces:

```
greeting =
  if isActive then
    "Welcome back!"
  else
    "Please log in"
```

## Objects

### Single-line objects

Use single-line format when the object is short and simple:

```
point = { x: 10, y: 20 }
user = { name: "Bob", age: 25 }
```

Always include inner spaces in non-empty objects.

### Multi-line objects

Use multi-line format for objects with more than 2-3 fields or complex values:

```
person = {
  name: "Alice"
  age: 30
  address: "123 Main St"
  isActive: true
}
```

Blank lines separate logical groups of fields:

```
config = {
  host: "localhost"
  port: 8080

  timeout: 30
  retries: 3

  logging: {
    level: "info"
    format: "json"
  }
}
```

### Nested objects

When nesting objects, maintain consistent indentation:

```
company = {
  name: "Tech Corp"

  location: {
    city: "San Francisco"
    state: "CA"
    zip: "94105"
  }

  employees: [
    { name: "Alice", role: "Engineer" }
    { name: "Bob", role: "Designer" }
  ]
}
```

### Object extensions

When extending objects, use this format:

```
extendedUser = baseUser {
  premium: true
  credits: 100
}
```

When patching (without colon), use the same style:

```
patchedConfig = baseConfig {
  database {
    maxConnections: 50
  }
}
```

## Arrays

### Single-line arrays

Use single-line format for short arrays:

```
numbers = [1, 2, 3, 4, 5]
colors = ["red", "green", "blue"]
```

### Multi-line arrays

Use one element per line for longer arrays or complex elements:

```
fruits = [
  "apple"
  "banana"
  "cherry"
  "date"
]
```

For objects in arrays, use this format:

```
users = [
  { name: "Alice", age: 30 }
  { name: "Bob", age: 25 }
  { name: "Charlie", age: 35 }
]
```

## Functions

### Single-line functions

Simple functions fit on one line:

```
double = x -> x * 2
greet = name -> "Hello, " + name + "!"
```

### Multi-line functions

When the body is complex, indent by 2 spaces after `->`:

```
calculateTotal = items ->
  subtotal = sum items
  tax = subtotal * 0.08
  subtotal + tax
```

For curried functions, continue on the same line when arguments are simple:

```
add = x -> y -> x + y
multiply = x -> y -> x * y
```

When the body is long, break before the arrow:

```
processOrder = order -> customer -> options ->
  validateOrder order
  calculatePrice order customer.discount
  applyOptions options
```

### Functions with pattern matching

Pattern matching parameters should be clear:

```
fullName = { first, last } -> first + " " + last
getPoint = (x, y) -> { x, y }
```

## Conditionals

### Simple conditionals

Single-line for simple cases:

```
status = if isOnline then "available" else "away"
```

### Multi-line conditionals

Indent branches by 2 spaces:

```
message =
  if score >= 90 then
    "Excellent!"
  else if score >= 70 then
    "Good job"
  else
    "Keep trying"
```

Multiple conditions should be aligned:

```
grade =
  if score >= 90 then "A"
  else if score >= 80 then "B"
  else if score >= 70 then "C"
  else "F"
```

## `where` Clauses

Use `where` to define variables after an expression:

```
total = subtotal + tax where
  subtotal = price * quantity
  tax = subtotal * 0.08
```

For single variables, keep it on one line if short:

```
doubled = x * 2 where x = getValue()
```

Multiple definitions in a `where` clause should be aligned:

```
circle = { center, radius, area, circumference } where
  center = (x, y)
  radius = 5
  area = Math.pi * radius * radius
  circumference = 2 * Math.pi * radius
```

## `do` Blocks

Use `do` for complex arguments:

```
processData items do
  filtered = filter items isValid
  sorted = sort filtered byDate
  take 10 sorted
```

## Pattern Matching

Format `when` expressions with consistent indentation:

```
result =
  when value matches
    (#ok, data) then processData data
    (#error, msg) then logError msg
    otherwise null
```

For complex branches, use indentation:

```
handleResponse = response -> when response matches
  (#ok, data) then
    transformData data
  (#error, message) then
    defaultValue
  otherwise
    null
```

## Comprehensions

### Array comprehensions

Single-line for simple cases:

```
doubled = [x * 2 for x in numbers]
```

Multi-line for complex expressions:

```
results = [
  processItem item
  for item in items
  when item.isActive
]
```

Multiple generators should be clear:

```
pairs = [
  (x, y)
  for x in [1, 2, 3]
  for y in [4, 5, 6]
  when x < y
]
```

### Object comprehensions

Format similarly to array comprehensions:

```
indexed = {
  [item.id]: item.name
  for item in items
}
```

Multiple lines for complex cases:

```
transformed = {
  [toUpper(key)]: processValue value
  for (key, value) in sourceObject
  when isValid value
}
```

## Imports

Keep imports at the top of the file:

```
Math = import 'lib/Math'
String = import 'lib/String'
```

Destructuring imports:

```
{ format, parse } = import 'lib/Phone'
{ describe, it, mustEq } = import 'Spec'
```

## Comments

Use `//` for single-line comments:

```
// Calculate the total price including tax
total = price * 1.08
```

Comments should be on their own line, not at the end of code lines.

## Blank Lines

Use blank lines to separate logical sections:

```
// Configuration
host = "localhost"
port = 8080

// User data
user = {
  name: "Alice"
  email: "alice@example.com"
}

// Process the request
response = processRequest user
```

In objects and arrays, use blank lines to group related fields:

```
config = {
  // Server settings
  host: "localhost"
  port: 8080

  // Database settings
  dbHost: "db.example.com"
  dbPort: 5432

  // Logging
  logLevel: "info"
}
```

## Line Length

While there's no strict limit, aim to keep lines under 80-100 characters for readability. Break long expressions across multiple lines:

```
// Good
result =
  calculateValue param1 param2 param3 param4

// Also good
result = calculateValue
  param1
  param2
  param3
  param4

// Avoid
result = calculateValue param1 param2 param3 param4 param5 param6 param7 param8
```

## Complete Example

Here's a well-formatted Lazylang file:

```
// User management module
{ createUser, validateUser, formatUserName } = import 'lib/User'
Database = import 'lib/Database'

// Configuration
config = {
  maxUsers: 1000
  defaultRole: "member"

  features: {
    notifications: true
    analytics: false
  }
}

// Create a new user with validation
registerUser = userData ->
  validationResult = validateUser userData
  when validationResult matches
    (#ok, user) then
      saved = Database.save "users" user
      { success: true, user: saved }
    (#error, message) then
      { success: false, error: message }
    otherwise
      { success: false, error: "Unknown error" }

// Get user display name
getUserDisplay = user ->
  name = formatUserName user
  status = if user.isActive then "online" else "offline"
  name + " (" + status + ")"

// Export public API
{
  registerUser
  getUserDisplay
  config
}
```
