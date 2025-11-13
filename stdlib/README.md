# Lazylang Standard Library

The Lazylang standard library provides a comprehensive set of utilities for working with common data types and operations in your configuration files.

## Automatically Imported Modules

The following modules are automatically available in the global scope without explicit imports:

- **Array** - Functions for working with arrays (map, filter, fold, etc.)
- **Float** - Floating-point number operations and conversions
- **Math** - Mathematical functions (abs, min, max, floor, ceil, etc.)
- **Object** - Object manipulation utilities (keys, values, merge, etc.)
- **String** - String processing functions (split, join, trim, etc.)

## Other Modules

Additional modules can be imported explicitly using `import`:

- **JSON** - JSON encoding and decoding
- **YAML** - YAML encoding and decoding
- **Spec** - Testing framework for writing specifications

## Usage

Since the core modules are automatically imported, you can use them directly:

```lazylang
# Array operations
numbers = [1, 2, 3, 4, 5]
doubled = Array.map (x -> x * 2) numbers

# String operations
text = "hello world"
uppercase = String.toUpper text

# Math operations
result = Math.max 10 20
```

For modules that aren't automatically imported, use explicit imports:

```lazylang
JSON = import 'JSON'
data = { name: "Alice", age: 30 }
jsonString = JSON.encode data
```
