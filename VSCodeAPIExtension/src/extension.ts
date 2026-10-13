// VS Code glue: runs the bridge server, implements the backend with the Language Model
// API (Copilot's models), and adds a status bar item and commands.

import * as vscode from 'vscode';
import { randomBytes } from 'node:crypto';
import {
  BridgeError,
  ChatRequest,
  ChatResult,
  ModelBackend,
  ModelInfo,
  TokenCountRequest,
  TokenCountResult,
} from './backend';
import { withInstructions } from './protocol';
import { BridgeServer, ServerStats } from './server';

const SECTION = 'mrCommandCenterBridge';
const TOKEN_KEY = `${SECTION}.token`;
const DEFAULT_JUSTIFICATION = 'MR Command Center sends merge request changes to Copilot for code review.';

interface Settings {
  enabled: boolean;
  port: number;
  defaultModel: string;
  maxConcurrentRequests: number;
  requestTimeoutSeconds: number;
}

function settings(): Settings {
  const config = vscode.workspace.getConfiguration(SECTION);
  return {
    enabled: config.get('enabled', true),
    port: config.get('port', 52741),
    defaultModel: config.get('defaultModel', '').trim(),
    maxConcurrentRequests: config.get('maxConcurrentRequests', 2),
    requestTimeoutSeconds: config.get('requestTimeoutSeconds', 180),
  };
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const log = vscode.window.createOutputChannel('MR Command Center Bridge', { log: true });
  const bridge = new Bridge(context, log);
  const command = (name: string, run: () => unknown) => vscode.commands.registerCommand(`${SECTION}.${name}`, run);

  context.subscriptions.push(
    log,
    bridge,
    command('showStatus', () => bridge.showStatus()),
    command('testCopilotAccess', () => bridge.testCopilotAccess()),
    command('copyToken', () => bridge.copyToken()),
    command('regenerateToken', () => bridge.regenerateToken()),
    command('restart', () => bridge.restart()),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration(SECTION)) void bridge.restart();
    }),
  );
  await bridge.start();
}

export function deactivate(): void {
  // The bridge is disposed through context.subscriptions.
}

class Bridge implements vscode.Disposable {
  private server?: BridgeServer;
  private problem?: string;
  private stats: ServerStats = { active: 0, queued: 0, served: 0, failed: 0 };
  private readonly backend = new CopilotBackend(() => settings().defaultModel);
  private readonly statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);

  constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly log: vscode.LogOutputChannel,
  ) {
    this.statusItem.name = 'MR Command Center Bridge';
    this.statusItem.command = `${SECTION}.showStatus`;
    this.statusItem.show();
  }

  async start(): Promise<void> {
    const config = settings();
    if (!config.enabled) {
      this.problem = 'Turned off in settings';
      this.render();
      return;
    }
    const server = new BridgeServer({
      port: config.port,
      token: await this.token(),
      backend: this.backend,
      maxConcurrent: config.maxConcurrentRequests,
      requestTimeoutMs: config.requestTimeoutSeconds * 1000,
      log: (message) => this.log.info(message),
      onStatsChange: (stats) => {
        this.stats = stats;
        this.render();
      },
    });
    try {
      await server.start();
      this.server = server;
      this.problem = undefined;
      this.log.info(`Listening on http://127.0.0.1:${server.port}`);
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      this.problem = code === 'EADDRINUSE' ? `Port ${config.port} is already in use` : String(error);
      this.log.error(`Couldn't start: ${this.problem}`);
      void vscode.window
        .showWarningMessage(`MR Command Center Bridge couldn't start: ${this.problem}.`, 'Open Settings')
        .then((choice) => {
          if (choice) void vscode.commands.executeCommand('workbench.action.openSettings', SECTION);
        });
    }
    this.render();
  }

  async stop(): Promise<void> {
    await this.server?.stop();
    this.server = undefined;
  }

  async restart(): Promise<void> {
    await this.stop();
    await this.start();
  }

  dispose(): void {
    void this.stop();
    this.statusItem.dispose();
  }

  // MARK: Commands

  async copyToken(): Promise<void> {
    await vscode.env.clipboard.writeText(await this.token());
    void vscode.window.showInformationMessage('Access token copied. Paste it into MR Command Center.');
  }

  async regenerateToken(): Promise<void> {
    const choice = await vscode.window.showWarningMessage(
      'Make a new access token? MR Command Center stops working until you paste the new one.',
      { modal: true },
      'Regenerate',
    );
    if (choice !== 'Regenerate') return;
    await this.context.secrets.store(TOKEN_KEY, newToken());
    await this.restart();
    await this.copyToken();
  }

  /** Sends a tiny request from a user action, so VS Code can ask for permission up front. */
  async testCopilotAccess(): Promise<void> {
    const source = new AbortController();
    try {
      const started = Date.now();
      const result = await vscode.window.withProgress(
        { location: vscode.ProgressLocation.Notification, title: 'Asking Copilot…', cancellable: true },
        (_, token) => {
          token.onCancellationRequested(() => source.abort());
          return this.backend.chat(
            { messages: [{ role: 'user', content: 'Reply with the single word OK.' }] },
            source.signal,
          );
        },
      );
      const seconds = ((Date.now() - started) / 1000).toFixed(1);
      void vscode.window.showInformationMessage(
        `Copilot works. ${result.model.name} answered "${result.text.trim().slice(0, 40)}" in ${seconds} s.`,
      );
    } catch (error) {
      if (source.signal.aborted) return;
      void vscode.window.showErrorMessage(`Copilot request failed: ${(error as Error).message}`);
    }
  }

  async showStatus(): Promise<void> {
    type Item = vscode.QuickPickItem & { run?: () => unknown };
    const items: Item[] = [{ label: 'Server', kind: vscode.QuickPickItemKind.Separator }];
    items.push(
      this.server
        ? {
            label: `$(pass) Listening on http://127.0.0.1:${this.server.port}`,
            detail: `${this.stats.served} served · ${this.stats.failed} failed · ${this.stats.active} running · ${this.stats.queued} waiting`,
          }
        : { label: `$(error) Not running`, detail: this.problem },
    );

    items.push({ label: 'Copilot models', kind: vscode.QuickPickItemKind.Separator });
    try {
      const models = await this.backend.listModels();
      const preferred = settings().defaultModel;
      if (models.length === 0) items.push({ label: '$(warning) No models. Sign in to GitHub Copilot.' });
      models.forEach((model, index) => {
        const isDefault = preferred ? model.id === preferred || model.family === preferred : index === 0;
        items.push({
          label: `${isDefault ? '$(star-full) ' : ''}${model.name}`,
          description: `id ${model.id} · family ${model.family}`,
          detail: `${model.maxInputTokens.toLocaleString()} input tokens${isDefault ? ' · default' : ''}`,
          run: async () => {
            await vscode.env.clipboard.writeText(model.id);
            void vscode.window.showInformationMessage(`Copied model id ${model.id}.`);
          },
        });
      });
    } catch (error) {
      items.push({ label: `$(error) ${(error as Error).message}` });
    }

    items.push(
      { label: 'Actions', kind: vscode.QuickPickItemKind.Separator },
      { label: '$(key) Copy Access Token', run: () => this.copyToken() },
      { label: '$(beaker) Test Copilot Access', run: () => this.testCopilotAccess() },
      { label: '$(output) Show Log', run: () => this.log.show() },
      {
        label: '$(gear) Open Settings',
        run: () => vscode.commands.executeCommand('workbench.action.openSettings', SECTION),
      },
      { label: '$(debug-restart) Restart Server', run: () => this.restart() },
    );

    const picked = await vscode.window.showQuickPick(items, {
      title: 'MR Command Center Bridge',
      placeHolder: 'Pick a model to copy its id, or an action',
    });
    await picked?.run?.();
  }

  // MARK: Helpers

  private async token(): Promise<string> {
    let token = await this.context.secrets.get(TOKEN_KEY);
    if (!token) {
      token = newToken();
      await this.context.secrets.store(TOKEN_KEY, token);
    }
    return token;
  }

  private render(): void {
    const item = this.statusItem;
    if (!this.server) {
      item.text = '$(debug-disconnect) MR Bridge';
      item.tooltip = `MR Command Center Bridge isn't running: ${this.problem ?? 'stopped'}`;
      item.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
      return;
    }
    const busy = this.stats.active + this.stats.queued;
    item.text = busy > 0 ? `$(sync~spin) MR Bridge ${busy}` : '$(plug) MR Bridge';
    item.tooltip = `MR Command Center Bridge on 127.0.0.1:${this.server.port}\n${this.stats.served} requests served, ${this.stats.failed} failed`;
    item.backgroundColor = undefined;
  }
}

class CopilotBackend implements ModelBackend {
  constructor(private readonly defaultModel: () => string) {}

  async listModels(): Promise<ModelInfo[]> {
    return (await copilotModels()).map(info);
  }

  async chat(request: ChatRequest, signal: AbortSignal): Promise<ChatResult> {
    const model = await this.pick(request.model);
    const messages = withInstructions(request).map((message) =>
      message.role === 'user'
        ? vscode.LanguageModelChatMessage.User(message.content)
        : vscode.LanguageModelChatMessage.Assistant(message.content),
    );
    return withCancellation(signal, async (token) => {
      const response = await model.sendRequest(
        messages,
        { justification: request.justification ?? DEFAULT_JUSTIFICATION },
        token,
      );
      let text = '';
      for await (const part of response.text) text += part;
      const inputTokens = await sum(messages.map((message) => countOrUndefined(model, message, token)));
      const outputTokens = await countOrUndefined(model, text, token);
      return { text, model: info(model), inputTokens, outputTokens };
    });
  }

  async countTokens(request: TokenCountRequest, signal: AbortSignal): Promise<TokenCountResult> {
    const model = await this.pick(request.model);
    return withCancellation(signal, async (token) => ({
      tokens: await model.countTokens(request.text, token),
      model: info(model),
    }));
  }

  /** Matches a model id first, then a family; falls back to the setting, then the first model. */
  private async pick(requested?: string): Promise<vscode.LanguageModelChat> {
    const models = await copilotModels();
    if (models.length === 0) {
      throw new BridgeError(503, 'no_models', 'No Copilot chat models are available. Sign in to GitHub Copilot in VS Code.');
    }
    const wanted = requested || this.defaultModel();
    if (!wanted) return models[0];
    const found = models.find((model) => model.id === wanted) ?? models.find((model) => model.family === wanted);
    if (!found) {
      const available = models.map((model) => model.id).join(', ');
      throw new BridgeError(404, 'model_not_found', `No Copilot model with id or family "${wanted}". Available: ${available}.`);
    }
    return found;
  }
}

function copilotModels(): Thenable<vscode.LanguageModelChat[]> {
  return vscode.lm.selectChatModels({ vendor: 'copilot' });
}

function info(model: vscode.LanguageModelChat): ModelInfo {
  return {
    id: model.id,
    name: model.name,
    vendor: model.vendor,
    family: model.family,
    version: model.version,
    maxInputTokens: model.maxInputTokens,
  };
}

/** Bridges the server's AbortSignal to a VS Code cancellation token, and maps API errors. */
async function withCancellation<T>(signal: AbortSignal, body: (token: vscode.CancellationToken) => Promise<T>): Promise<T> {
  const source = new vscode.CancellationTokenSource();
  const cancel = () => source.cancel();
  signal.addEventListener('abort', cancel, { once: true });
  try {
    return await body(source.token);
  } catch (error) {
    throw mapError(error);
  } finally {
    signal.removeEventListener('abort', cancel);
    source.dispose();
  }
}

function mapError(error: unknown): unknown {
  if (!(error instanceof vscode.LanguageModelError)) return error;
  switch (error.code) {
    case vscode.LanguageModelError.NoPermissions().code:
      return new BridgeError(403, 'no_permission',
        'VS Code hasn\'t allowed this extension to use Copilot. Run "MR Command Center Bridge: Test Copilot Access" and click Allow.');
    case vscode.LanguageModelError.Blocked().code:
      return new BridgeError(429, 'blocked', `Copilot blocked the request, often because of a rate or usage limit: ${error.message}`);
    case vscode.LanguageModelError.NotFound().code:
      return new BridgeError(404, 'model_not_found', error.message);
    default:
      return new BridgeError(502, 'model_error', error.message);
  }
}

async function countOrUndefined(
  model: vscode.LanguageModelChat,
  content: string | vscode.LanguageModelChatMessage,
  token: vscode.CancellationToken,
): Promise<number | undefined> {
  try {
    return await model.countTokens(content, token);
  } catch {
    return undefined;
  }
}

async function sum(counts: Promise<number | undefined>[]): Promise<number | undefined> {
  const values = await Promise.all(counts);
  return values.some((value) => value === undefined) ? undefined : values.reduce<number>((total, value) => total + (value ?? 0), 0);
}

function newToken(): string {
  return randomBytes(32).toString('base64url');
}
