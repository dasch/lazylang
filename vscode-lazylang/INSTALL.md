# Installation Guide

## Quick Start

### 1. Build the LSP Server

First, make sure the Lazylang LSP server is built:

```bash
cd /path/to/lazylang
zig build
```

This creates `zig-out/bin/lazylang-lsp`.

### 2. Install the Extension

You have two options:

#### Option A: Development Mode (Recommended for testing)

1. Open the `vscode-lazylang` directory in VS Code:
   ```bash
   cd vscode-lazylang
   code .
   ```

2. Press `F5` to launch a new VS Code window with the extension loaded

3. In the new window, open a `.lazy` file to test

#### Option B: Install as VSIX (For regular use)

1. Package the extension:
   ```bash
   npm install -g @vscode/vsce
   vsce package
   ```

2. Install the generated `.vsix` file:
   ```bash
   code --install-extension lazylang-0.1.0.vsix
   ```

   Or in VS Code: Extensions view → "..." menu → "Install from VSIX..."

### 3. Configure (Optional)

If the LSP server is not in your PATH or the default locations, configure it:

1. Open VS Code Settings (Cmd+, or Ctrl+,)
2. Search for "lazylang"
3. Set "Lazylang: Lsp Path" to your `lazylang-lsp` executable path

Example:
```json
{
  "lazylang.lspPath": "/Users/you/projects/lazylang/zig-out/bin/lazylang-lsp"
}
```

## Testing the Extension

1. Create a test file `test.lazy`:
   ```lazylang
   // Test syntax highlighting
   let x = 42;
   let add = fn(a) -> fn(b) -> a + b;
   let result = add(5)(3);
   ```

2. Open it in VS Code
3. You should see:
   - Syntax highlighting (via LSP semantic tokens)
   - Auto-closing brackets and quotes
   - Comment toggling (Cmd+/ or Ctrl+/)

## Troubleshooting

### LSP Server Not Found

If you see "Lazylang LSP server not found":

1. Check the path is correct: `ls /path/to/lazylang-lsp`
2. Make it executable: `chmod +x /path/to/lazylang-lsp`
3. Set the path in VS Code settings (see step 3 above)

### No Syntax Highlighting

1. Check the Output panel: View → Output → Select "Lazylang Language Server"
2. Look for connection errors
3. Try reloading the window: Cmd+Shift+P → "Developer: Reload Window"

### Extension Not Loading

1. Check the Developer Tools: Help → Toggle Developer Tools
2. Look for errors in the Console
3. Ensure TypeScript compiled: `npm run compile`

## Development

To work on the extension:

```bash
# Install dependencies
npm install

# Compile TypeScript
npm run compile

# Watch mode (auto-recompile on changes)
npm run watch

# Test in VS Code
# Press F5 to launch Extension Development Host
```

## Uninstall

```bash
code --uninstall-extension lazylang
```

Or through VS Code: Extensions view → Lazylang → Uninstall
