import * as path from 'path';
import * as fs from 'fs';
import { workspace, ExtensionContext, window, languages, TextDocument, Range, TextEdit, CancellationToken, FormattingOptions, commands, TextEditor } from 'vscode';
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

    // Register custom commands
    registerCommands(context);

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
 * Find the Lazylang formatter executable (lazy CLI).
 * Priority order:
 * 1. In workspace bin/lazy
 * 2. In workspace ../bin/lazy (for worktrees)
 * 3. In PATH
 */
function findFormatter(context: ExtensionContext): string | null {
    // Check workspace directory
    const workspaceFolders = workspace.workspaceFolders;
    if (workspaceFolders && workspaceFolders.length > 0) {
        const workspaceRoot = workspaceFolders[0].uri.fsPath;

        // Check bin/ in workspace
        const workspaceFormatterPath = path.join(workspaceRoot, 'bin', 'lazy');
        if (fs.existsSync(workspaceFormatterPath)) {
            return workspaceFormatterPath;
        }

        // Check parent directory (for git worktrees)
        const parentFormatterPath = path.join(workspaceRoot, '..', 'bin', 'lazy');
        if (fs.existsSync(parentFormatterPath)) {
            return path.resolve(parentFormatterPath);
        }
    }

    // Try to find in PATH
    const pathDirs = (process.env.PATH || '').split(path.delimiter);
    for (const dir of pathDirs) {
        const formatterPath = path.join(dir, 'lazy');
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
 * 2. In workspace bin/lazy-lsp
 * 3. In workspace ../bin/lazy-lsp (for worktrees)
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

        // Check bin/ in workspace
        const workspaceLspPath = path.join(workspaceRoot, 'bin', 'lazy-lsp');
        if (fs.existsSync(workspaceLspPath)) {
            return workspaceLspPath;
        }

        // Check parent directory (for git worktrees)
        const parentLspPath = path.join(workspaceRoot, '..', 'bin', 'lazy-lsp');
        if (fs.existsSync(parentLspPath)) {
            return path.resolve(parentLspPath);
        }
    }

    // Try to find in PATH
    const pathDirs = (process.env.PATH || '').split(path.delimiter);
    for (const dir of pathDirs) {
        const lspPath = path.join(dir, 'lazy-lsp');
        if (fs.existsSync(lspPath)) {
            return lspPath;
        }
    }

    return null;
}

/**
 * Register custom Lazylang commands
 */
function registerCommands(context: ExtensionContext) {
    // Command: Lazylang: Eval File
    const evalCommand = commands.registerTextEditorCommand('lazylang.evalFile', async (editor: TextEditor) => {
        const document = editor.document;
        if (document.languageId !== 'lazylang') {
            window.showErrorMessage('This command only works with Lazylang files');
            return;
        }

        const lazyLangPath = findLazyLangExecutable();
        if (!lazyLangPath) {
            window.showErrorMessage('Lazylang executable not found. Please build the project.');
            return;
        }

        const filePath = document.uri.fsPath;
        const workspaceFolder = workspace.workspaceFolders?.[0]?.uri.fsPath;

        const terminal = window.createTerminal({
            name: 'Lazylang Eval',
            cwd: workspaceFolder || path.dirname(filePath)
        });
        terminal.show();
        terminal.sendText(`"${lazyLangPath}" eval "${filePath}"`);
    });

    // Command: Lazylang: Run File
    const runCommand = commands.registerTextEditorCommand('lazylang.runFile', async (editor: TextEditor) => {
        const document = editor.document;
        if (document.languageId !== 'lazylang') {
            window.showErrorMessage('This command only works with Lazylang files');
            return;
        }

        const lazyLangPath = findLazyLangExecutable();
        if (!lazyLangPath) {
            window.showErrorMessage('Lazylang executable not found. Please build the project.');
            return;
        }

        const filePath = document.uri.fsPath;
        const workspaceFolder = workspace.workspaceFolders?.[0]?.uri.fsPath;

        const terminal = window.createTerminal({
            name: 'Lazylang Run',
            cwd: workspaceFolder || path.dirname(filePath)
        });
        terminal.show();
        terminal.sendText(`"${lazyLangPath}" run "${filePath}"`);
    });

    // Command: Lazylang: Run Spec
    const testCommand = commands.registerTextEditorCommand('lazylang.runTests', async (editor: TextEditor) => {
        const document = editor.document;
        if (document.languageId !== 'lazylang') {
            window.showErrorMessage('This command only works with Lazylang files');
            return;
        }

        const lazyLangPath = findLazyLangExecutable();
        if (!lazyLangPath) {
            window.showErrorMessage('Lazylang executable not found. Please build the project.');
            return;
        }

        const filePath = document.uri.fsPath;
        const workspaceFolder = workspace.workspaceFolders?.[0]?.uri.fsPath;

        const terminal = window.createTerminal({
            name: 'Lazylang Spec',
            cwd: workspaceFolder || path.dirname(filePath)
        });
        terminal.show();
        terminal.sendText(`"${lazyLangPath}" spec "${filePath}"`);
    });

    context.subscriptions.push(evalCommand, runCommand, testCommand);
}

/**
 * Find the Lazylang executable (lazylang CLI).
 */
function findLazyLangExecutable(): string | null {
    const workspaceFolders = workspace.workspaceFolders;
    if (workspaceFolders && workspaceFolders.length > 0) {
        const workspaceRoot = workspaceFolders[0].uri.fsPath;

        // Check zig-out/bin in workspace
        const workspacePath = path.join(workspaceRoot, 'zig-out', 'bin', 'lazylang');
        if (fs.existsSync(workspacePath)) {
            return workspacePath;
        }

        // Check parent directory (for git worktrees)
        const parentPath = path.join(workspaceRoot, '..', 'zig-out', 'bin', 'lazylang');
        if (fs.existsSync(parentPath)) {
            return path.resolve(parentPath);
        }
    }

    // Try to find in PATH
    const pathDirs = (process.env.PATH || '').split(path.delimiter);
    for (const dir of pathDirs) {
        const execPath = path.join(dir, 'lazylang');
        if (fs.existsSync(execPath)) {
            return execPath;
        }
    }

    return null;
}
