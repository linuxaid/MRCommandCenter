# MR Command Center Bridge

A VS Code extension that lets MR Command Center (or `curl`) send prompts to your **GitHub Copilot** models. It uses VS Code's official Language Model API (`vscode.lm`) and runs a small HTTP server on `127.0.0.1`. Requests use your existing Copilot sign-in and plan limits.

```
MR Command Center ──HTTP + token──▶ 127.0.0.1:52741 (this extension) ──vscode.lm──▶ Copilot
```

VS Code must be running with Copilot signed in. The extension starts when VS Code finishes loading.

## Install

1. Build the package (needs Node 20 or later):

   ```bash
   npm install
   npm run package        # creates mr-command-center-bridge-0.1.0.vsix
   ```

2. In VS Code, run **Extensions: Install from VSIX…** and pick the `.vsix` file.
3. Run **MR Command Center Bridge: Test Copilot Access**. The first time, VS Code asks whether the extension may use Copilot's language models. Click **Allow**.
4. Run **MR Command Center Bridge: Copy Access Token** and paste the token wherever the client needs it.

The status bar shows **MR Bridge**. Click it to see the server state, the Copilot models you can use (pick one to copy its id), and the commands.

## Settings

| Setting | Default | |
|---|---|---|
| `mrCommandCenterBridge.enabled` | `true` | Run the server. |
| `mrCommandCenterBridge.port` | `52741` | Port on `127.0.0.1`. |
| `mrCommandCenterBridge.defaultModel` | empty | Model id or family used when a request doesn't name one. Empty uses the first model Copilot lists. |
| `mrCommandCenterBridge.maxConcurrentRequests` | `2` | Requests sent to Copilot at once; the rest wait in line. |
| `mrCommandCenterBridge.requestTimeoutSeconds` | `180` | Limit per request, including time in line. |

Changing a setting restarts the server.

## API

Every route except `/v1/health` needs `Authorization: Bearer <token>`. Bodies are JSON. Errors always look like:

```json
{ "error": { "code": "unauthorized", "message": "…" } }
```

### `GET /v1/health`
No token. Tells a client whether the extension is running.

```bash
curl -s http://127.0.0.1:52741/v1/health
# {"status":"ok","apiVersion":1}
```

### `GET /v1/models`
The Copilot chat models you can use.

```bash
TOKEN='paste-token-here'
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:52741/v1/models
# {"models":[{"id":"…","name":"…","vendor":"copilot","family":"…","version":"…","maxInputTokens":…}]}
```

### `POST /v1/chat`
Sends one request and returns the full answer (not streamed).

| Field | | |
|---|---|---|
| `prompt` | string | A single user message. Use this **or** `messages`. |
| `messages` | array | `{ "role": "user" \| "assistant", "content": "…" }`. The last message must be `user`. |
| `instructions` | string, optional | Placed ahead of the first user message, because the API has no system role. |
| `model` | string, optional | A model id or family. Falls back to the `defaultModel` setting. |
| `justification` | string, optional | Shown by VS Code when it asks for permission. |

```bash
curl -s http://127.0.0.1:52741/v1/chat \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"instructions":"You review Swift diffs. Report real bugs only.","prompt":"+ let x = items[0]!"}'
# {"text":"…","model":{…},"inputTokens":…,"outputTokens":…}
```

`inputTokens` and `outputTokens` are Copilot's own counts, and are left out when the count fails.

### `POST /v1/tokens`
Counts tokens for a model: `{ "text": "…", "model": "optional" }` returns `{ "tokens": 123, "model": {…} }`.

### Status codes

| Status | Code | Meaning |
|---|---|---|
| 400 | `invalid_request`, `invalid_json` | The body is wrong; the message says how. |
| 401 | `unauthorized` | Missing or wrong token. |
| 403 | `browser_request`, `bad_host` | Refused for safety (see below). |
| 403 | `no_permission` | VS Code hasn't allowed the extension to use Copilot. Run **Test Copilot Access**. |
| 404 | `model_not_found`, `not_found` | Unknown model (the message lists the available ones) or route. |
| 413 | `too_large` | The body is over 4 MB. |
| 429 | `blocked` | Copilot refused the request, usually a rate or usage limit. |
| 503 | `no_models` | Copilot isn't signed in or has no chat models. |
| 504 | `timeout` | Took longer than `requestTimeoutSeconds`. |
| 502 | `model_error` | Any other failure from Copilot. |

## Security

- The server listens on `127.0.0.1` only, so other machines can't reach it.
- Every model request needs the token. It's 32 random bytes kept in VS Code's secret storage, and **Regenerate Access Token** replaces it.
- Requests that carry an `Origin` header are refused, and so are requests whose `Host` isn't `127.0.0.1` or `localhost`. Together these stop web pages open in a browser from reaching the server, including through DNS rebinding.
- The log records method, path, status and timing only, never prompts or answers.
- Code sent through the bridge goes to Copilot, just as it would if you pasted it into Copilot Chat. Check that your company's Copilot policy allows this use before relying on it.

## Development

```bash
npm install
npm test          # compiles, then runs the server tests against a fake backend (no VS Code needed)
npm run watch     # recompile on save
```

To debug inside VS Code, open this folder and press F5 with an "Extension Development Host" launch configuration.

| File | |
|---|---|
| `src/server.ts` | HTTP server: routing, token and host checks, body limits, concurrency queue, timeouts, client disconnects. |
| `src/protocol.ts` | Request validation; places instructions ahead of the first message. |
| `src/backend.ts` | The `ModelBackend` interface and `BridgeError`. |
| `src/extension.ts` | VS Code glue: Copilot backend via `vscode.lm`, status bar, commands, settings. |
| `src/test/` | Node test runner tests for the server. |
