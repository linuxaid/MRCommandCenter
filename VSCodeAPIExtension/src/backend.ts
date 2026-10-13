// The model seam between the HTTP server and VS Code. The server only knows this
// interface, so it can be tested in plain Node with a fake backend.

export interface ModelInfo {
  id: string;
  name: string;
  vendor: string;
  family: string;
  version: string;
  maxInputTokens: number;
}

export type ChatRole = 'user' | 'assistant';

export interface ChatMessage {
  role: ChatRole;
  content: string;
}

export interface ChatRequest {
  /** A model id or family. Empty uses the configured default. */
  model?: string;
  /** Sent ahead of the first user message; the VS Code API has no system role. */
  instructions?: string;
  messages: ChatMessage[];
  /** Shown by VS Code when it asks the user to allow access. */
  justification?: string;
}

export interface ChatResult {
  text: string;
  model: ModelInfo;
  inputTokens?: number;
  outputTokens?: number;
}

export interface TokenCountRequest {
  model?: string;
  text: string;
}

export interface TokenCountResult {
  tokens: number;
  model: ModelInfo;
}

export interface ModelBackend {
  listModels(signal: AbortSignal): Promise<ModelInfo[]>;
  chat(request: ChatRequest, signal: AbortSignal): Promise<ChatResult>;
  countTokens(request: TokenCountRequest, signal: AbortSignal): Promise<TokenCountResult>;
}

/** An error with the HTTP status and stable code the client sees. */
export class BridgeError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'BridgeError';
  }
}
