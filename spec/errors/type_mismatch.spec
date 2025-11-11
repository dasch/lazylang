# Type Mismatch Errors

## Test: adding number to boolean
CODE:
1 + true
EXPECTED_ERROR:
TypeMismatch

## Test: adding number to string
CODE:
5 + "hello"
EXPECTED_ERROR:
TypeMismatch

## Test: multiplying boolean values
CODE:
true * false
EXPECTED_ERROR:
TypeMismatch

## Test: logical and with number
CODE:
5 && true
EXPECTED_ERROR:
TypeMismatch
