#!/usr/bin/env bash
# Manual REPL tests - run each test independently
#
# Usage: ./test_repl_manual.sh

set -e

REPL="./zig-out/bin/lazylang repl"

strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

echo "=== Manual REPL Tests ==="
echo
echo "Test 1: Basic arithmetic (1 + 2 = 3)"
printf "1 + 2\n:quit\n" | gtimeout 3 $REPL 2>&1 | strip_ansi | grep "=> 3" && echo "✓ PASS" || echo "✗ FAIL"

echo
echo "Test 2: Variable assignment (x = 42)"
printf "x = 42\n:quit\n" | gtimeout 3 $REPL 2>&1 | strip_ansi | grep "=> 42" && echo "✓ PASS" || echo "✗ FAIL"

echo
echo "Test 3: Variable persistence (x = 10, y = 20, x + y = 30)"
printf "x = 10\ny = 20\nx + y\n:quit\n" | gtimeout 3 $REPL 2>&1 | strip_ansi | grep "=> 30" && echo "✓ PASS" || echo "✗ FAIL"

echo
echo "Test 4: Object creation"
printf '{ name: "Alice", age: 30 }\n:quit\n' | gtimeout 3 $REPL 2>&1 | strip_ansi | grep "Alice" && echo "✓ PASS" || echo "✗ FAIL"

echo
echo "Test 5: Array creation"
printf "[1, 2, 3]\n:quit\n" | gtimeout 3 $REPL 2>&1 | strip_ansi | grep "\[1, 2, 3\]" && echo "✓ PASS" || echo "✗ FAIL"

echo
echo "Test 6: Help command"
printf ":help\n:quit\n" | gtimeout 3 $REPL 2>&1 | strip_ansi | grep "Commands:" && echo "✓ PASS" || echo "✗ FAIL"

echo
echo "Test 8: Nested arithmetic"
printf "(5 + 3) * 2\n:quit\n" | gtimeout 3 $REPL 2>&1 | strip_ansi | grep "=> 16" && echo "✓ PASS" || echo "✗ FAIL"

echo
echo "All tests completed!"
