# Lazylang for Visual Studio Code

This extension provides language support for Lazylang, including syntax highlighting and LSP-powered intelligent features.

## Features

- **Syntax Highlighting**: Rich syntax highlighting for Lazylang code via semantic tokens
- **Language Server Protocol**: Powered by the Lazylang LSP server for intelligent code features
- **Auto-completion**: Bracket and quote auto-closing
- **Code Folding**: Support for folding code blocks

### Coming Soon

- Go to Definition
- Hover Information
- Code Completion
- Error Diagnostics
- Find References

## Requirements

The Lazylang LSP server must be available. The extension will look for it in the following locations (in order):

1. Custom path configured in settings (`lazylang.lspPath`)
2. `zig-out/bin/lazylang-lsp` in your workspace
3. `lazylang-lsp` in your system PATH

To build the LSP server:

```bash
cd /path/to/lazylang
zig build
```

This will create the `lazylang-lsp` executable in `zig-out/bin/`.

## Extension Settings

This extension contributes the following settings:

* `lazylang.lspPath`: Path to the Lazylang LSP server executable
* `lazylang.trace.server`: Enable/disable tracing of communication between VS Code and the language server

## Usage

1. Install the extension
2. Open a `.lazy` file
3. The extension will automatically start the Lazylang LSP server
4. Enjoy syntax highlighting and language features!

## Development

To work on this extension:

```bash
cd vscode-lazylang
npm install
npm run compile
```

To test the extension:

1. Open this directory in VS Code
2. Press `F5` to launch a new VS Code window with the extension loaded
3. Open a `.lazy` file to test the extension

## Building and Installing

To package the extension:

```bash
npm install -g @vscode/vsce
vsce package
```

This creates a `.vsix` file that can be installed in VS Code:

```bash
code --install-extension lazylang-0.1.0.vsix
```

## Release Notes

### 0.1.0

Initial release with:
- Syntax highlighting via LSP semantic tokens
- Basic language configuration (brackets, comments)
- TextMate grammar for fallback highlighting
- LSP server integration

## License

[Add your license here]

## Contributing

[Add contribution guidelines here]
