import * as path from 'path';
import * as fs from 'fs';
import { workspace, ExtensionContext, window } from 'vscode';

import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    Executable
} from 'vscode-languageclient/node';

let client: LanguageClient;

export function activate(context: ExtensionContext) {
    console.log('Lazylang extension is now active');

    // Find the LSP server executable
    const serverPath = findLspServer(context);

    if (!serverPath) {
        window.showErrorMessage(
            'Lazylang LSP server not found. Please set "lazylang.lspPath" in settings or ensure "lazylang-lsp" is in your PATH.'
        );
        return;
    }

    console.log(`Using Lazylang LSP server at: ${serverPath}`);

    // Configure the server executable
    const serverExecutable: Executable = {
        command: serverPath,
        args: [],
        options: {
            env: process.env
        }
    };

    const serverOptions: ServerOptions = {
        run: serverExecutable,
        debug: serverExecutable
    };

    // Configure the language client
    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'lazylang' }],
        synchronize: {
            // Notify the server about file changes to '.lazy' files in the workspace
            fileEvents: workspace.createFileSystemWatcher('**/*.lazy')
        }
    };

    // Create and start the language client
    client = new LanguageClient(
        'lazylangLanguageServer',
        'Lazylang Language Server',
        serverOptions,
        clientOptions
    );

    // Start the client (this will also launch the server)
    client.start();

    console.log('Lazylang Language Server started');
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}

/**
 * Find the Lazylang LSP server executable.
 * Priority order:
 * 1. User-configured path in settings
 * 2. In workspace zig-out/bin/lazylang-lsp
 * 3. In workspace ../zig-out/bin/lazylang-lsp (for worktrees)
 * 4. In PATH
 */
function findLspServer(context: ExtensionContext): string | null {
    // Check user configuration
    const config = workspace.getConfiguration('lazylang');
    const configuredPath = config.get<string>('lspPath');

    if (configuredPath && fs.existsSync(configuredPath)) {
        return configuredPath;
    }

    // Check workspace directory
    const workspaceFolders = workspace.workspaceFolders;
    if (workspaceFolders && workspaceFolders.length > 0) {
        const workspaceRoot = workspaceFolders[0].uri.fsPath;

        // Check zig-out/bin in workspace
        const workspaceLspPath = path.join(workspaceRoot, 'zig-out', 'bin', 'lazylang-lsp');
        if (fs.existsSync(workspaceLspPath)) {
            return workspaceLspPath;
        }

        // Check parent directory (for git worktrees)
        const parentLspPath = path.join(workspaceRoot, '..', 'zig-out', 'bin', 'lazylang-lsp');
        if (fs.existsSync(parentLspPath)) {
            return path.resolve(parentLspPath);
        }
    }

    // Try to find in PATH
    const pathDirs = (process.env.PATH || '').split(path.delimiter);
    for (const dir of pathDirs) {
        const lspPath = path.join(dir, 'lazylang-lsp');
        if (fs.existsSync(lspPath)) {
            return lspPath;
        }
    }

    return null;
}
