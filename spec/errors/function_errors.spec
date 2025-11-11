# Function Call Errors

## Test: calling non-function
CODE:
let x = 5 in x(10)
EXPECTED_ERROR:
ExpectedFunction

## Test: calling boolean
CODE:
true(42)
EXPECTED_ERROR:
ExpectedFunction

## Test: calling null
CODE:
null(1)
EXPECTED_ERROR:
ExpectedFunction
