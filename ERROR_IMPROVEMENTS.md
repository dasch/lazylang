# Error Message Improvement Plan

This document outlines planned improvements to error messages in lazylang.

## Current State

Based on the comprehensive test suite, we have identified several areas where error messages can be improved:

- **423/432 tests pass** (9 expected failures)
- Error messages exist but lack specificity in many cases
- Some errors don't set proper location context
- Generic messages like "Unexpected token" don't help users understand what went wrong

## Improvement Areas

### 1. Parser Errors - Context-Specific Messages

**Current**: Generic "Unexpected token" message
**Improved**: Specific messages based on context

Examples:
- "Expected ')' to close expression" instead of "Unexpected token"
- "Expected '}' to close object literal" instead of "Unexpected token"
- "Expected expression after '+' operator" instead of "Expected expression"
- "Expected identifier after 'let' keyword" instead of "Unexpected token"
- "Expected '=' in let binding" instead of "Unexpected token"
- "Expected 'then' keyword in if expression" instead of "Unexpected token"

**Implementation**: Add expected token parameter to parser error functions

### 2. Error Location Tracking

**Current**: Some errors don't set location information
**Improved**: All errors set proper source location

Examples:
- Unterminated string errors should point to the start of the string
- End-of-file errors should point to the last valid token
- Expression errors should point to the specific token

**Implementation**: Ensure recordError() is called before every error return

### 3. Pattern Matching Errors

**Current**: Generic "TypeMismatch" for pattern matching failures
**Improved**: Specific pattern matching error messages

Examples:
- "Pattern expects tuple with 3 elements, found tuple with 2 elements"
- "Pattern expects array, found integer"
- "Pattern expects object with field 'y', but field is missing"
- "Pattern match failed: expected value 1, found value 2"

**Implementation**: Extend ErrorData to include pattern matching info, set detailed error data during pattern matching

### 4. Type Mismatch Context

**Current**: Some type mismatches have operation context, some don't
**Improved**: All type mismatches explain the operation and expected types

Examples:
- "Cannot multiply string by integer" (current: good!)
- "Cannot call non-function value of type 'integer'"
- "Cannot access field on non-object value of type 'array'"
- "Cannot iterate over non-array value of type 'integer' in comprehension"

**Implementation**: Add more operation context when setting TypeMismatch errors

### 5. Evaluator Errors with Better Context

**Current**: Runtime errors sometimes don't explain what failed
**Improved**: Clear explanation of what operation failed and why

Examples:
- Builtin function errors explain which function and what argument failed
- Field access errors show available fields (already done!)
- Array index errors show the invalid index and array length

**Implementation**: Set detailed error context in evaluator before returning errors

### 6. Multi-Error Support (Future)

**Current**: Only first error is reported
**Future**: Could report multiple errors at once (like tsc)

This is a larger change and not part of the initial improvement.

## Implementation Strategy

### Phase 1: Parser Error Messages (Priority: HIGH)
- Add helper functions for common error cases
- Add `expectToken()` method that provides better error messages
- Replace generic error returns with context-specific ones
- Ensure all parser errors set location

### Phase 2: Evaluator Error Messages (Priority: HIGH)
- Ensure all evaluator errors set location
- Add more detailed error data for type mismatches
- Improve builtin function error messages

### Phase 3: Pattern Matching Errors (Priority: MEDIUM)
- Extend ErrorData union with pattern matching types
- Set detailed error data during pattern matching
- Update error reporting to show pattern mismatch details

### Phase 4: Polish and Edge Cases (Priority: LOW)
- Review all error messages for consistency
- Add more helpful suggestions
- Improve error message wording

## Testing Strategy

- Use comprehensive_error_messages_test.zig to track improvements
- Each improvement should reduce the number of failing tests
- Add new tests for newly-improved error messages
- Manually test error messages to ensure they're helpful

## Success Criteria

- All 432 tests pass (or expected failures are documented as language limitations)
- Every error has a clear, actionable message
- Every error points to the correct source location
- Error messages follow consistent format and tone
- Users can understand and fix errors without looking at source code
