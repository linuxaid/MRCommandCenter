import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import * as http from 'node:http';
import { BridgeError, ChatRequest, ChatResult, ModelBackend, ModelInfo } from '../backend';
import { parseChatRequest, withInstructions } from '../protocol';
import { BridgeServer, ServerOptions } from '../server';

const TOKEN = 'test-token';
const MODEL: ModelInfo = { id: 'fake-1', name: 'Fake', vendor: 'copilot', family: 'fake', version: '1', maxInputTokens: 1000 };

/** Echoes the last message unless told otherwise. Records requests and live concurrency. */
class FakeBackend implements ModelBackend {
  requests: ChatRequest[] = [];
  running = 0;
  maxRunning = 0;
  lastSignal?: AbortSignal;
  behavior: (request: ChatRequest, signal: AbortSignal) => Promise<string> = async (request) =>
    request.messages[request.messages.length - 1].content;

  async listModels(): Promise<ModelInfo[]> {
    return [MODEL];
  }

  async chat(request: ChatRequest, signal: AbortSignal): Promise<ChatResult> {
    this.requests.push(request);
    this.lastSignal = signal;
    this.running += 1;
    this.maxRunning = Math.max(this.maxRunning, this.running);
    try {
      return { text: await this.behavior(request, signal), model: MODEL, inputTokens: 3, outputTokens: 1 };
    } finally {
      this.running -= 1;
    }
  }

  async countTokens(request: { text: string }) {
    return { tokens: request.text.length, model: MODEL };
  }
}

async function withServer(
  run: (url: string, backend: FakeBackend, server: BridgeServer) => Promise<void>,
  options: Partial<ServerOptions> = {},
): Promise<void> {
  const backend = new FakeBackend();
  const server = new BridgeServer({ port: 0, token: TOKEN, backend, maxConcurrent: 2, requestTimeoutMs: 5000, ...options });
  const port = await server.start();
  try {
    await run(`http://127.0.0.1:${port}`, backend, server);
  } finally {
    await server.stop();
  }
}

function post(url: string, body: unknown, token = TOKEN, signal?: AbortSignal): Promise<Response> {
  return fetch(url, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal,
  });
}

function waitFor(condition: () => boolean): Promise<void> {
  return new Promise((resolve) => {
    const check = () => (condition() ? resolve() : setTimeout(check, 5));
    check();
  });
}

test('health needs no token; everything else does', async () => {
  await withServer(async (url) => {
    const health = await fetch(`${url}/v1/health`);
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { status: 'ok', apiVersion: 1 });

    assert.equal((await fetch(`${url}/v1/models`)).status, 401);
    assert.equal((await fetch(`${url}/v1/models`, { headers: { Authorization: 'Bearer wrong' } })).status, 401);
    const models = await fetch(`${url}/v1/models`, { headers: { Authorization: `Bearer ${TOKEN}` } });
    assert.equal(models.status, 200);
    assert.deepEqual(await models.json(), { models: [MODEL] });
  });
});

test('chat passes the request through and returns the model answer', async () => {
  await withServer(async (url, backend) => {
    const response = await post(`${url}/v1/chat`, { prompt: 'Review this', instructions: 'Be brief', model: 'fake' });
    assert.equal(response.status, 200);
    const body = (await response.json()) as ChatResult;
    assert.equal(body.text, 'Review this');
    assert.equal(body.model.id, 'fake-1');
    assert.equal(body.inputTokens, 3);
    assert.deepEqual(backend.requests[0], {
      model: 'fake',
      instructions: 'Be brief',
      messages: [{ role: 'user', content: 'Review this' }],
      justification: undefined,
    });
  });
});

test('token counting', async () => {
  await withServer(async (url) => {
    const response = await post(`${url}/v1/tokens`, { text: 'abcd' });
    assert.equal(response.status, 200);
    assert.equal(((await response.json()) as { tokens: number }).tokens, 4);
  });
});

test('refuses browser requests and unexpected Host headers', async () => {
  await withServer(async (url, _backend, server) => {
    const fromPage = await fetch(`${url}/v1/health`, { headers: { Origin: 'https://evil.example' } });
    assert.equal(fromPage.status, 403);

    const status = await new Promise<number>((resolve, reject) => {
      const request = http.request(
        { host: '127.0.0.1', port: server.port, path: '/v1/health', headers: { Host: 'evil.example' } },
        (response) => {
          response.resume();
          resolve(response.statusCode ?? 0);
        },
      );
      request.on('error', reject);
      request.end();
    });
    assert.equal(status, 403);
  });
});

test('rejects bad bodies with clear status codes', async () => {
  await withServer(async (url) => {
    const notJSON = await fetch(`${url}/v1/chat`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'text/plain' },
      body: 'hi',
    });
    assert.equal(notJSON.status, 415);

    const broken = await fetch(`${url}/v1/chat`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
      body: '{',
    });
    assert.equal(broken.status, 400);
    assert.equal(((await broken.json()) as { error: { code: string } }).error.code, 'invalid_json');

    assert.equal((await post(`${url}/v1/chat`, { messages: [] })).status, 400);
    assert.equal((await post(`${url}/v1/chat`, { prompt: 'x'.repeat(200) })).status, 413);
  }, { maxBodyBytes: 100 });
});

test('unknown routes and wrong methods', async () => {
  await withServer(async (url) => {
    assert.equal((await fetch(`${url}/v2/chat`, { headers: { Authorization: `Bearer ${TOKEN}` } })).status, 404);
    assert.equal((await fetch(`${url}/v1/chat`, { headers: { Authorization: `Bearer ${TOKEN}` } })).status, 405);
  });
});

test('backend errors keep their status; unknown errors become 502', async () => {
  await withServer(async (url, backend) => {
    backend.behavior = async () => {
      throw new BridgeError(429, 'blocked', 'Slow down');
    };
    const blocked = await post(`${url}/v1/chat`, { prompt: 'x' });
    assert.equal(blocked.status, 429);
    assert.deepEqual(await blocked.json(), { error: { code: 'blocked', message: 'Slow down' } });

    backend.behavior = async () => {
      throw new Error('kaboom');
    };
    const failed = await post(`${url}/v1/chat`, { prompt: 'x' });
    assert.equal(failed.status, 502);
    assert.equal(((await failed.json()) as { error: { message: string } }).error.message, 'kaboom');
  });
});

test('slow requests time out and the backend is told to stop', async () => {
  await withServer(async (url, backend) => {
    backend.behavior = (_request, signal) =>
      new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(new Error('cancelled'))));
    const response = await post(`${url}/v1/chat`, { prompt: 'x' });
    assert.equal(response.status, 504);
    assert.equal(((await response.json()) as { error: { code: string } }).error.code, 'timeout');
    assert.equal(backend.lastSignal?.aborted, true);
  }, { requestTimeoutMs: 100 });
});

test('a client that disconnects cancels the model request', async () => {
  await withServer(async (url, backend) => {
    backend.behavior = (_request, signal) =>
      new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(new Error('cancelled'))));
    const client = new AbortController();
    const pending = post(`${url}/v1/chat`, { prompt: 'x' }, TOKEN, client.signal).catch(() => undefined);
    await waitFor(() => backend.lastSignal !== undefined);
    client.abort();
    await pending;
    await waitFor(() => backend.lastSignal?.aborted === true);
  });
});

test('limits concurrent model calls and queues the rest', async () => {
  await withServer(async (url, backend, server) => {
    const gates: Array<() => void> = [];
    backend.behavior = (request) => new Promise((resolve) => gates.push(() => resolve(request.messages[0].content)));
    const responses = ['a', 'b', 'c'].map((prompt) => post(`${url}/v1/chat`, { prompt }));

    await waitFor(() => backend.running === 1 && server.stats.queued === 2);
    for (let finished = 0; finished < 3; finished += 1) {
      await waitFor(() => gates.length > 0);
      gates.shift()?.();
    }
    const texts = await Promise.all(responses.map(async (response) => ((await (await response).json()) as ChatResult).text));

    assert.deepEqual(texts.sort(), ['a', 'b', 'c']);
    assert.equal(backend.maxRunning, 1);
    assert.deepEqual(server.stats, { active: 0, queued: 0, served: 3, failed: 0 });
  }, { maxConcurrent: 1 });
});

test('request parsing', () => {
  assert.deepEqual(parseChatRequest({ prompt: 'hi', model: '  ' }).model, undefined, 'Blank model means default');
  assert.throws(() => parseChatRequest({ prompt: 'hi', messages: [] }), /not both/);
  assert.throws(() => parseChatRequest({ messages: [{ role: 'system', content: 'x' }] }), /role/);
  assert.throws(() => parseChatRequest({ messages: [{ role: 'user', content: 'q' }, { role: 'assistant', content: 'a' }] }), /last message/);
  assert.throws(() => parseChatRequest({ prompt: '   ' }), /empty/);
  assert.throws(() => parseChatRequest([]), /JSON object/);
});

test('instructions go ahead of the first user message', () => {
  assert.deepEqual(withInstructions({ instructions: 'Rules', messages: [{ role: 'user', content: 'Diff' }] }), [
    { role: 'user', content: 'Rules\n\n---\n\nDiff' },
  ]);
  assert.deepEqual(
    withInstructions({ instructions: 'Rules', messages: [{ role: 'assistant', content: 'A' }, { role: 'user', content: 'Q' }] }),
    [{ role: 'user', content: 'Rules' }, { role: 'assistant', content: 'A' }, { role: 'user', content: 'Q' }],
  );
  const untouched = [{ role: 'user' as const, content: 'Diff' }];
  assert.equal(withInstructions({ messages: untouched }), untouched);
});
