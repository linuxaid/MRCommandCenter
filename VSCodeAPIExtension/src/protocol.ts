// Request validation and message shaping. Pure functions, no VS Code or HTTP.

import { BridgeError, ChatMessage, ChatRequest, TokenCountRequest } from './backend';

export function parseChatRequest(value: unknown): ChatRequest {
  const body = asObject(value, 'The body');
  const model = optionalString(body, 'model');
  const instructions = optionalString(body, 'instructions');
  const justification = optionalString(body, 'justification');

  if (body.prompt !== undefined && body.messages !== undefined) {
    throw invalid('Send prompt or messages, not both.');
  }
  let messages: ChatMessage[];
  if (body.messages !== undefined) {
    if (!Array.isArray(body.messages)) throw invalid('messages must be an array.');
    messages = body.messages.map((item, index) => {
      const message = asObject(item, `messages[${index}]`);
      if (message.role !== 'user' && message.role !== 'assistant') {
        throw invalid(`messages[${index}].role must be "user" or "assistant".`);
      }
      if (typeof message.content !== 'string') throw invalid(`messages[${index}].content must be a string.`);
      return { role: message.role, content: message.content };
    });
  } else if (typeof body.prompt === 'string') {
    messages = [{ role: 'user', content: body.prompt }];
  } else {
    throw invalid('Send prompt (a string) or messages (an array).');
  }

  if (messages.length === 0) throw invalid('messages is empty.');
  if (messages.every((message) => message.content.trim() === '')) throw invalid('The prompt is empty.');
  if (messages[messages.length - 1].role !== 'user') throw invalid('The last message must have the user role.');
  return { model, instructions, messages, justification };
}

export function parseTokenCountRequest(value: unknown): TokenCountRequest {
  const body = asObject(value, 'The body');
  if (typeof body.text !== 'string') throw invalid('text must be a string.');
  return { model: optionalString(body, 'model'), text: body.text };
}

/** Puts the instructions ahead of the first user message, since the API has no system role. */
export function withInstructions(request: ChatRequest): ChatMessage[] {
  const instructions = request.instructions?.trim();
  if (!instructions) return request.messages;
  const [first, ...rest] = request.messages;
  if (first.role === 'user') {
    return [{ role: 'user', content: `${instructions}\n\n---\n\n${first.content}` }, ...rest];
  }
  return [{ role: 'user', content: instructions }, ...request.messages];
}

function asObject(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw invalid(`${label} must be a JSON object.`);
  }
  return value as Record<string, unknown>;
}

function optionalString(body: Record<string, unknown>, key: string): string | undefined {
  const value = body[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'string') throw invalid(`${key} must be a string.`);
  return value.trim() === '' ? undefined : value;
}

function invalid(message: string): BridgeError {
  return new BridgeError(400, 'invalid_request', message);
}
