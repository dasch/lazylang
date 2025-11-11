# Unknown Identifier Error

## Test: undefined variable
CODE:
undefinedVariable
EXPECTED_ERROR:
UnknownIdentifier

## Test: typo in variable name
CODE:
let x = 5 in y
EXPECTED_ERROR:
UnknownIdentifier

## Test: using variable before definition
CODE:
let result = x + 1 in
let x = 5 in
result
EXPECTED_ERROR:
UnknownIdentifier
