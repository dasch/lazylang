.PHONY: all build test test-zig test-stdlib stdlib-docspecs docs clean repl

all: test docs

# Build the lazy binary
build:
	zig build

# Alias for build target
lazy: build

# Run Zig unit tests
test-zig: build
	zig build test

# Run Lazylang stdlib specs
test-stdlib: build
	./bin/lazy spec stdlib/spec

# Run all tests (both Zig tests and stdlib specs)
test: test-zig test-stdlib

# Launch the interactive REPL
repl: build
	./bin/lazy repl

# Generate stdlib documentation
docs: build
	cd stdlib && $(MAKE) docs

# Run stdlib documentation specs
stdlib-docspecs: build
	cd stdlib && $(MAKE) docspecs

# Clean build artifacts
clean:
	rm -rf zig-out zig-cache bin
