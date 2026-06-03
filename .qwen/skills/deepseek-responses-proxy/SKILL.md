---
name: deepseek-responses-proxy
description: Proxy DeepSeek models to DeepSeek API for both chat completions and responses endpoints
source: auto-skill
extracted_at: '2026-06-02T06:31:00.927Z'
---

## DeepSeek Model Proxying for OpenAI-Compatible Endpoints

When implementing OpenAI-compatible API endpoints that support multiple upstream providers (e.g., Cursor API and DeepSeek API), model-specific routing must happen **before** the default handler is invoked.

### The Pattern

1. **Check for DeepSeek models early** in the request handler, before calling `resolveCursorModel()` or similar default routing logic
2. **Proxy directly to DeepSeek API** when a DeepSeek model is detected
3. **Fall through to Cursor API** for non-DeepSeek models

### Implementation

```typescript
// In handleOpenAiRoute or similar handler
const requestedModel = typeof (body as { model?: unknown })?.model === "string" 
  ? (body as { model: string }).model 
  : "composer-2.5";

// Check for DeepSeek models FIRST
if (isDeepSeekModel(requestedModel)) {
  if (route.kind === "chat") {
    return proxyDeepSeekCompletion(env, deps, body, auth.api2agentKey);
  }
  if (route.kind === "responses") {
    return proxyDeepSeekResponses(env, deps, body, auth.api2agentKey);
  }
}

// Then proceed with Cursor API for non-DeepSeek models
const cursorModel = resolveCursorModel(requestedModel);
// ... rest of Cursor API handling
```

### Why This Matters

- **DeepSeek API uses different endpoints**: `/chat/completions` for chat, `/responses` for responses API
- **Cursor API doesn't recognize DeepSeek model names**: Passing `deepseek-v4-flash` to Cursor API will fail
- **Authentication passthrough**: The user's API key should be forwarded directly to DeepSeek, not exchanged through Cursor

### Files Involved

- `worker/deepseek.ts`: Contains `proxyDeepSeekCompletion()` and `proxyDeepSeekResponses()` functions
- `worker/index.ts`: Main request handler that routes to appropriate proxy based on model

### Key Functions

```typescript
// worker/deepseek.ts
export function isDeepSeekModel(model: string): boolean {
  return model.startsWith("deepseek-");
}

export async function proxyDeepSeekResponses(
  env: Env,
  deps: Deps,
  body: unknown,
  apiKey: string
): Promise<Response> {
  const baseUrl = env.DEEPSEEK_API_BASE || "https://api.deepseek.com";
  const isStream = typeof body === "object" && body !== null && 
    (body as Record<string, unknown>).stream === true;

  const response = await deps.fetch(`${baseUrl}/responses`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
      "Accept": isStream ? "text/event-stream" : "application/json"
    },
    body: JSON.stringify(body)
  });

  // Handle streaming vs buffered responses
  if (isStream) {
    return withCors(new Response(response.body, {
      status: response.status,
      headers: { "content-type": "text/event-stream" }
    }));
  }

  const data = await response.json();
  return withCors(new Response(JSON.stringify(data), {
    headers: { "content-type": "application/json; charset=utf-8" }
  }));
}
```
