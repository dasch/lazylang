# Parse Errors

## Test: unterminated string single quote
CODE:
'hello world
EXPECTED_ERROR:
UnterminatedString

## Test: unterminated string double quote
CODE:
"hello world
EXPECTED_ERROR:
UnterminatedString

## Test: unexpected character
CODE:
1 + 2 @ 3
EXPECTED_ERROR:
UnexpectedCharacter

## Test: expected expression
CODE:
let x =
EXPECTED_ERROR:
ExpectedExpression
