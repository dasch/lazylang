.PHONY: all build test test-zig test-spec docs clean

all: test

# Build the lazylang binary
build:
	zig build

# Alias for build target
lazylang: build

# Run Zig unit tests
test-zig: build
	zig build test

# Run Lazylang stdlib specs
test-spec: build
	./zig-out/bin/lazylang spec stdlib/spec

# Run all tests (both Zig tests and stdlib specs)
test: test-zig test-spec

# Generate stdlib documentation
docs: build
	cd stdlib && ../zig-out/bin/lazylang docs lib

# Clean build artifacts
clean:
	rm -rf zig-out zig-cache
