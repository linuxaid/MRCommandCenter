// The localhost HTTP API. Listens on 127.0.0.1 only, requires the bearer token on
// every route except /v1/health, and refuses browser requests (any Origin header) and
// unexpected Host headers so web pages can't reach it.

import * as http from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';
import { BridgeError, ModelBackend } from './backend';
import { parseChatRequest, parseTokenCountRequest } from './protocol';

export const API_VERSION = 1;
const HOST = '127.0.0.1';

export interface ServerOptions {
  /** 0 picks a free port. */
  port: number;
  token: string;
  backend: ModelBackend;
  maxConcurrent: number;
  /** Covers the whole request, including time waiting for a free slot. */
  requestTimeoutMs: number;
  maxBodyBytes?: number;
  log?: (message: string) => void;
  onStatsChange?: (stats: ServerStats) => void;
}

export interface ServerStats {
  active: number;
  queued: number;
  served: number;
  failed: number;
}

const ROUTES: Record<string, string> = {
  '/v1/health': 'GET',
  '/v1/models': 'GET',
  '/v1/chat': 'POST',
  '/v1/tokens': 'POST',
};

export class BridgeServer {
  private server?: http.Server;
  private readonly limiter: Limiter;
  private served = 0;
  private failed = 0;

  constructor(private readonly options: ServerOptions) {
    this.limiter = new Limiter(Math.max(1, options.maxConcurrent));
  }

  get port(): number | undefined {
    const address = this.server?.address();
    return address && typeof address === 'object' ? address.port : undefined;
  }

  get stats(): ServerStats {
    return { active: this.limiter.active, queued: this.limiter.queued, served: this.served, failed: this.failed };
  }

  start(): Promise<number> {
    return new Promise((resolve, reject) => {
      const server = http.createServer((request, response) => void this.handle(request, response));
      server.once('error', reject);
      server.listen(this.options.port, HOST, () => {
        server.off('error', reject);
        this.server = server;
        resolve(this.port ?? this.options.port);
      });
    });
  }

  stop(): Promise<void> {
    const server = this.server;
    this.server = undefined;
    if (!server) return Promise.resolve();
    return new Promise((resolve) => {
      server.close(() => resolve());
      server.closeAllConnections();
    });
  }

  private async handle(request: http.IncomingMessage, response: http.ServerResponse): Promise<void> {
    const started = Date.now();
    const controller = new AbortController();
    const timer = setTimeout(
      () => controller.abort(new BridgeError(504, 'timeout', `The request took longer than ${Math.round(this.options.requestTimeoutMs / 1000)} seconds.`)),
      this.options.requestTimeoutMs,
    );
    response.on('close', () => {
      if (!response.writableEnded) controller.abort(new BridgeError(499, 'client_closed', 'The client disconnected.'));
    });

    const path = new URL(request.url ?? '/', `http://${HOST}`).pathname;
    let status = 500;
    try {
      this.checkTransport(request);
      const method = ROUTES[path];
      if (!method) throw new BridgeError(404, 'not_found', `No route ${path}.`);
      if (request.method !== method) throw new BridgeError(405, 'method_not_allowed', `Use ${method} for ${path}.`);
      if (path !== '/v1/health') this.checkToken(request);

      const signal = controller.signal;
      const backend = this.options.backend;
      let body: unknown;
      switch (path) {
        case '/v1/health':
          body = { status: 'ok', apiVersion: API_VERSION };
          break;
        case '/v1/models':
          body = { models: await this.withSlot(signal, () => backend.listModels(signal)) };
          break;
        case '/v1/chat': {
          const chat = parseChatRequest(await readJSON(request, this.options.maxBodyBytes ?? 4 * 1024 * 1024));
          body = await this.withSlot(signal, () => backend.chat(chat, signal));
          break;
        }
        case '/v1/tokens': {
          const count = parseTokenCountRequest(await readJSON(request, this.options.maxBodyBytes ?? 4 * 1024 * 1024));
          body = await this.withSlot(signal, () => backend.countTokens(count, signal));
          break;
        }
      }
      status = 200;
      send(response, status, body);
    } catch (error) {
      const failure = toBridgeError(error, controller.signal);
      status = failure.status;
      send(response, status, { error: { code: failure.code, message: failure.message } });
    } finally {
      clearTimeout(timer);
      this.options.log?.(`${request.method} ${path} → ${status} in ${Date.now() - started} ms`);
    }
  }

  private checkTransport(request: http.IncomingMessage): void {
    if (request.headers.origin !== undefined) {
      throw new BridgeError(403, 'browser_request', 'Requests from web pages are not allowed.');
    }
    const port = this.port;
    const host = request.headers.host;
    if (host !== `${HOST}:${port}` && host !== `localhost:${port}`) {
      throw new BridgeError(403, 'bad_host', 'Unexpected Host header. Connect to 127.0.0.1 directly.');
    }
  }

  private checkToken(request: http.IncomingMessage): void {
    const header = request.headers.authorization ?? '';
    const given = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
    if (!given || !timingSafeEqual(digest(given), digest(this.options.token))) {
      throw new BridgeError(401, 'unauthorized',
        'Missing or wrong access token. In VS Code, run "MR Command Center Bridge: Copy Access Token".');
    }
  }

  /** Runs model work once a slot is free, keeping the counters current. */
  private async withSlot<T>(signal: AbortSignal, work: () => Promise<T>): Promise<T> {
    const waiting = this.limiter.acquire(signal);
    this.report();
    await waiting;
    this.report();
    try {
      const result = await work();
      signal.throwIfAborted();
      this.served += 1;
      return result;
    } catch (error) {
      this.failed += 1;
      throw error;
    } finally {
      this.limiter.release();
      this.report();
    }
  }

  private report(): void {
    this.options.onStatsChange?.(this.stats);
  }
}

/** A first-come, first-served limit on concurrent work. Waiting can be aborted. */
class Limiter {
  active = 0;
  private readonly waiters: Array<() => void> = [];

  constructor(private readonly max: number) {}

  get queued(): number {
    return this.waiters.length;
  }

  async acquire(signal: AbortSignal): Promise<void> {
    signal.throwIfAborted();
    if (this.active < this.max) {
      this.active += 1;
      return;
    }
    await new Promise<void>((resolve, reject) => {
      const onAbort = () => {
        const index = this.waiters.indexOf(grant);
        if (index >= 0) this.waiters.splice(index, 1);
        reject(signal.reason);
      };
      const grant = () => {
        signal.removeEventListener('abort', onAbort);
        resolve();
      };
      this.waiters.push(grant);
      signal.addEventListener('abort', onAbort, { once: true });
    });
  }

  /** Hands the slot straight to the next waiter, if any. */
  release(): void {
    const next = this.waiters.shift();
    if (next) next();
    else this.active -= 1;
  }
}

async function readJSON(request: http.IncomingMessage, maxBytes: number): Promise<unknown> {
  const type = request.headers['content-type'] ?? '';
  if (!type.toLowerCase().startsWith('application/json')) {
    throw new BridgeError(415, 'unsupported_media_type', 'Send the body as application/json.');
  }
  const tooLarge = () => new BridgeError(413, 'too_large', `The body is larger than ${maxBytes} bytes.`);
  if (Number(request.headers['content-length'] ?? 0) > maxBytes) throw tooLarge();
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    size += (chunk as Buffer).length;
    if (size > maxBytes) throw tooLarge();
    chunks.push(chunk as Buffer);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new BridgeError(400, 'invalid_json', 'The body is not valid JSON.');
  }
}

function send(response: http.ServerResponse, status: number, body: unknown): void {
  if (response.headersSent || response.destroyed) return;
  const text = JSON.stringify(body);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(text),
    'Cache-Control': 'no-store',
    // Errors can leave an unread body behind; don't reuse the connection.
    ...(status >= 400 ? { Connection: 'close' } : {}),
  });
  response.end(text);
}

/** An abort (timeout or disconnect) wins over whatever the backend threw as a result. */
function toBridgeError(error: unknown, signal: AbortSignal): BridgeError {
  if (signal.aborted && signal.reason instanceof BridgeError) return signal.reason;
  if (error instanceof BridgeError) return error;
  const message = error instanceof Error ? error.message : String(error);
  return new BridgeError(502, 'model_error', message || 'The model request failed.');
}

function digest(text: string): Buffer {
  return createHash('sha256').update(text).digest();
}
