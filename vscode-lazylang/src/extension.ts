import * as path from 'path';
import * as fs from 'fs';
import { workspace, ExtensionContext, window, languages, TextDocument, Range, TextEdit, CancellationToken, FormattingOptions } from 'vscode';
import { execFile } from 'child_process';
import { promisify } from 'util';

import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    Executable
} from 'vscode-languageclient/node';

const execFilePromise = promisify(execFile);

let client: LanguageClient;

export function activate(context: ExtensionContext) {
    console.log('Lazylang extension is now active');

    // Find the LSP server executable
    const serverPath = findLspServer(context);

    if (serverPath) {
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
    } else {
        console.log('Lazylang LSP server not found');
        window.showWarningMessage(
            'Lazylang LSP server not found. Language features will be limited. Please set "lazylang.lspPath" in settings or ensure "lazylang-lsp" is in your PATH.'
        );
    }

    // Register document formatter
    const formatterPath = findFormatter(context);
    console.log(`Formatter path: ${formatterPath}`);

    if (formatterPath) {
        console.log(`Registering Lazylang formatter at: ${formatterPath}`);

        const provider = languages.registerDocumentFormattingEditProvider(
            'lazylang',
            {
                provideDocumentFormattingEdits: async (
                    document: TextDocument,
                    options: FormattingOptions,
                    token: CancellationToken
                ): Promise<TextEdit[]> => {
                    console.log(`Format requested for: ${document.fileName}`);
                    console.log(`Using formatter: ${formatterPath}`);

                    try {
                        const { stdout, stderr } = await execFilePromise(formatterPath, ['format', document.fileName]);

                        console.log(`Formatter stdout length: ${stdout.length}`);
                        if (stderr) {
                            console.log(`Formatter stderr: ${stderr}`);
                        }

                        // If there's any stderr output, treat it as an error even if exit code is 0
                        if (stderr && stderr.trim().length > 0) {
                            console.error('Formatter produced error output:', stderr);
                            window.showErrorMessage(`Formatting failed: ${stderr.trim()}`);
                            return [];
                        }

                        // Validate that we got output from the formatter
                        // If stdout is empty, the formatter likely failed internally
                        if (!stdout || stdout.length === 0) {
                            console.error('Formatter returned empty output');
                            window.showErrorMessage('Formatting failed: formatter returned empty output');
                            return [];
                        }

                        // Replace the entire document with the formatted output
                        const fullRange = new Range(
                            document.positionAt(0),
                            document.positionAt(document.getText().length)
                        );

                        return [TextEdit.replace(fullRange, stdout)];
                    } catch (error) {
                        console.error(`Formatting error:`, error);
                        window.showErrorMessage(`Formatting failed: ${error}`);
                        return [];
                    }
                }
            }
        );

        context.subscriptions.push(provider);
        console.log('Formatter registered successfully');
    } else {
        console.log('Lazylang formatter not found - formatting will not be available');
        window.showWarningMessage('Lazylang formatter not found. Please ensure "lazylang" is built and in your workspace zig-out/bin directory.');
    }
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}

/**
 * Find the Lazylang formatter executable (lazylang CLI).
 * Priority order:
 * 1. In workspace zig-out/bin/lazylang
 * 2. In workspace ../zig-out/bin/lazylang (for worktrees)
 * 3. In PATH
 */
function findFormatter(context: ExtensionContext): string | null {
    // Check workspace directory
    const workspaceFolders = workspace.workspaceFolders;
    if (workspaceFolders && workspaceFolders.length > 0) {
        const workspaceRoot = workspaceFolders[0].uri.fsPath;

        // Check zig-out/bin in workspace
        const workspaceFormatterPath = path.join(workspaceRoot, 'zig-out', 'bin', 'lazylang');
        if (fs.existsSync(workspaceFormatterPath)) {
            return workspaceFormatterPath;
        }

        // Check parent directory (for git worktrees)
        const parentFormatterPath = path.join(workspaceRoot, '..', 'zig-out', 'bin', 'lazylang');
        if (fs.existsSync(parentFormatterPath)) {
            return path.resolve(parentFormatterPath);
        }
    }

    // Try to find in PATH
    const pathDirs = (process.env.PATH || '').split(path.delimiter);
    for (const dir of pathDirs) {
        const formatterPath = path.join(dir, 'lazylang');
        if (fs.existsSync(formatterPath)) {
            return formatterPath;
        }
    }

    return null;
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
