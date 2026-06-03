import { HttpError, withCors } from "./http";
import { encodeSse, parseSse } from "./sse";
import type { Deps, Env } from "./types";

const DEEPSEEK_MODEL_PREFIXES = ["deepseek-"];

export function isDeepSeekModel(model: string): boolean {
  return DEEPSEEK_MODEL_PREFIXES.some((prefix) => model.startsWith(prefix));
}

function deepSeekBaseUrl(env: Env): string {
  return env.DEEPSEEK_API_BASE || "https://api.deepseek.com";
}

function deepSeekChatModel(model: string): string {
  switch (model) {
    case "deepseek-v4-pro":
    case "deepseek-v3":
    case "deepseek-v4-flash":
      return "deepseek-chat";
    case "deepseek-r1":
    case "deepseek-reasoner":
      return "deepseek-reasoner";
    default:
      return model;
  }
}

export async function proxyDeepSeekCompletion(
  env: Env,
  deps: Deps,
  body: unknown,
  apiKey: string,
): Promise<Response> {
  const baseUrl = deepSeekBaseUrl(env);
  const record = (body && typeof body === "object") ? body as Record<string, unknown> : {};
  const isStream = record.stream === true;

  const chatBody = { ...record, model: deepSeekChatModel(typeof record.model === "string" ? record.model : "deepseek-chat") };

  const response = await deps.fetch(`${baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
      "Accept": isStream ? "text/event-stream" : "application/json"
    },
    body: JSON.stringify(chatBody)
  });

  if (!response.ok) {
    const errorBody = await response.json().catch(() => ({})) as Record<string, unknown>;
    const error = (errorBody?.error as Record<string, unknown> | undefined);
    throw new HttpError(
      typeof error?.message === "string" ? error.message : `DeepSeek API error (${response.status})`,
      response.status,
      "deepseek_error"
    );
  }

  if (isStream) {
    return withCors(new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        "connection": "keep-alive"
      }
    }));
  }

  const data = await response.json();
  return withCors(new Response(JSON.stringify(data), {
    status: response.status,
    statusText: response.statusText,
    headers: { "content-type": "application/json; charset=utf-8" }
  }));
}

/**
 * DeepSeek does not implement OpenAI's `/v1/responses` endpoint, so we translate
 * the Responses request into a Chat Completions request, forward it to DeepSeek,
 * and translate the response (or SSE stream) back into the Responses shape that
 * Codex (and other Responses-API clients) expect.
 */
export async function proxyDeepSeekResponses(
  env: Env,
  deps: Deps,
  body: unknown,
  apiKey: string,
): Promise<Response> {
  const baseUrl = deepSeekBaseUrl(env);
  const record = (body && typeof body === "object") ? body as Record<string, unknown> : {};
  const requestedModel = typeof record.model === "string" ? record.model : "deepseek-chat";
  const model = deepSeekChatModel(requestedModel);
  const stream = record.stream === true;

  const { messages, promptChars } = responsesToChatMessages(body);
  const chatBody: Record<string, unknown> = { model, messages, stream };
  if (record.temperature !== undefined) chatBody.temperature = record.temperature;
  if (record.top_p !== undefined) chatBody.top_p = record.top_p;
  if (record.max_output_tokens !== undefined) chatBody.max_tokens = record.max_output_tokens;
  if (record.max_tokens !== undefined) chatBody.max_tokens = record.max_tokens;
  if (record.stop !== undefined) chatBody.stop = record.stop;

  const response = await deps.fetch(`${baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
      "Accept": stream ? "text/event-stream" : "application/json"
    },
    body: JSON.stringify(chatBody)
  });

  if (!response.ok) {
    const errorBody = await response.json().catch(() => ({})) as Record<string, unknown>;
    const error = (errorBody?.error as Record<string, unknown> | undefined);
    throw new HttpError(
      typeof error?.message === "string" ? error.message : `DeepSeek API error (${response.status})`,
      response.status,
      "deepseek_error"
    );
  }

  if (stream) {
    return withCors(new Response(streamChatCompletionsAsResponses(response, model, promptChars), {
      status: 200,
      headers: {
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "no-cache, no-transform",
        "connection": "keep-alive"
      }
    }));
  }

  const data = await response.json() as Record<string, unknown>;
  return withCors(new Response(JSON.stringify(chatCompletionToResponses(data, model, promptChars)), {
    status: 200,
    headers: { "content-type": "application/json; charset=utf-8" }
  }));
}

interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | ChatContentPart[];
  tool_call_id?: string;
  tool_calls?: ChatToolCall[];
  name?: string;
}

interface ChatContentPart {
  type: "text" | "image_url";
  text?: string;
  image_url?: { url: string };
}

interface ChatToolCall {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function extractText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const part of content) {
    if (!isRecord(part)) continue;
    const type = asString(part.type);
    if (type === "text" || type === "output_text" || type === "input_text") {
      if (typeof part.text === "string") parts.push(part.text);
    }
  }
  return parts.join("");
}

function responsesToChatMessages(body: unknown): { messages: ChatMessage[]; promptChars: number } {
  const record = isRecord(body) ? body : {};
  const messages: ChatMessage[] = [];

  const instructions = asString(record.instructions);
  if (instructions) {
    messages.push({ role: "system", content: instructions });
  }

  const input = record.input;
  if (typeof input === "string") {
    if (input) messages.push({ role: "user", content: input });
  } else if (Array.isArray(input)) {
    for (const item of input) {
      if (!isRecord(item)) continue;
      const type = asString(item.type) ?? "message";
      if (type === "message") {
        const role = (asString(item.role) ?? "user") as ChatMessage["role"];
        if (role !== "user" && role !== "system" && role !== "assistant") continue;
        const text = extractText(item.content);
        messages.push({ role, content: text });
      } else if (type === "function_call") {
        const assistant = messages[messages.length - 1];
        if (assistant && assistant.role === "assistant" && typeof assistant.content === "string") {
          assistant.content = assistant.content;
        }
        const call: ChatToolCall = {
          id: asString(item.call_id) ?? asString(item.id) ?? `call_${Math.random().toString(36).slice(2, 10)}`,
          type: "function",
          function: {
            name: asString(item.name) ?? "",
            arguments: asString(item.arguments) ?? "{}"
          }
        };
        if (assistant && assistant.role === "assistant") {
          assistant.tool_calls = [...(assistant.tool_calls ?? []), call];
        } else {
          messages.push({ role: "assistant", content: "", tool_calls: [call] });
        }
      } else if (type === "function_call_output") {
        messages.push({
          role: "tool",
          content: extractText(item.output) || asString(item.output) || "",
          tool_call_id: asString(item.call_id) ?? ""
        });
      }
    }
  }

  if (messages.length === 0) {
    messages.push({ role: "user", content: "" });
  }

  const promptChars = messages.reduce((sum, m) => {
    const c = typeof m.content === "string" ? m.content : m.content.map((p) => p.text ?? "").join("");
    return sum + c.length;
  }, 0);

  return { messages, promptChars };
}

interface UsageLike {
  input_tokens?: number;
  output_tokens?: number;
  total_tokens?: number;
}

function usageFromChatCompletion(data: Record<string, unknown>): UsageLike {
  const usage = isRecord(data.usage) ? data.usage as Record<string, unknown> : {};
  const promptTokens = typeof usage.prompt_tokens === "number" ? usage.prompt_tokens : 0;
  const completionTokens = typeof usage.completion_tokens === "number" ? usage.completion_tokens : 0;
  return {
    input_tokens: promptTokens,
    output_tokens: completionTokens,
    total_tokens: typeof usage.total_tokens === "number" ? usage.total_tokens : promptTokens + completionTokens
  };
}

function shortId(): string {
  return Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
}

function chatCompletionToResponses(
  data: Record<string, unknown>,
  model: string,
  promptChars: number
): Record<string, unknown> {
  const id = `resp_${shortId()}`;
  const messageId = `msg_${id.slice(5)}`;
  const created = Math.floor(Date.now() / 1000);
  const choice = Array.isArray(data.choices) ? data.choices[0] as Record<string, unknown> | undefined : undefined;
  const message = isRecord(choice?.message) ? choice.message as Record<string, unknown> : {};
  const text = extractText(message.content);
  const usage = usageFromChatCompletion(data);
  const outputChars = text.length;

  return {
    id,
    object: "response",
    created_at: created,
    status: "completed",
    completed_at: created,
    error: null,
    incomplete_details: null,
    model,
    output: [
      {
        id: messageId,
        type: "message",
        status: "completed",
        role: "assistant",
        content: [{ type: "output_text", text, annotations: [] }]
      }
    ],
    parallel_tool_calls: true,
    previous_response_id: null,
    reasoning: { effort: null, summary: null },
    store: false,
    tool_choice: "auto",
    tools: [],
    truncation: "disabled",
    usage: {
      input_tokens: usage.input_tokens ?? 0,
      input_tokens_details: { cached_tokens: 0 },
      output_tokens: usage.output_tokens ?? 0,
      output_tokens_details: { reasoning_tokens: 0 },
      total_tokens: usage.total_tokens ?? 0
    },
    user: null,
    metadata: {}
  };
}

function streamChatCompletionsAsResponses(
  response: Response,
  model: string,
  promptChars: number
): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  const responseId = `resp_${shortId()}`;
  const messageId = `msg_${responseId.slice(5)}`;
  const created = Math.floor(Date.now() / 1000);

  const baseResponse = (status: "in_progress" | "completed", text: string, usage?: UsageLike) => ({
    id: responseId,
    object: "response",
    created_at: created,
    status,
    completed_at: status === "completed" ? Math.floor(Date.now() / 1000) : null,
    error: null,
    incomplete_details: null,
    model,
    output: status === "completed" ? [
      {
        id: messageId,
        type: "message",
        status: "completed",
        role: "assistant",
        content: [{ type: "output_text", text, annotations: [] }]
      }
    ] : [],
    parallel_tool_calls: true,
    previous_response_id: null,
    reasoning: { effort: null, summary: null },
    store: false,
    tool_choice: "auto",
    tools: [],
    truncation: "disabled",
    usage: usage ? {
      input_tokens: usage.input_tokens ?? 0,
      input_tokens_details: { cached_tokens: 0 },
      output_tokens: usage.output_tokens ?? 0,
      output_tokens_details: { reasoning_tokens: 0 },
      total_tokens: usage.total_tokens ?? 0
    } : null,
    user: null,
    metadata: {}
  });

  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  const writer = writable.getWriter();

  (async () => {
    let text = "";
    let textStarted = false;
    let usage: UsageLike | undefined;
    try {
      await writer.write(encoder.encode(formatSse({ type: "response.created", response: baseResponse("in_progress", "") }, "response.created")));
      await writer.write(encoder.encode(formatSse({ type: "response.in_progress", response: baseResponse("in_progress", "") }, "response.in_progress")));

      if (!response.body) {
        throw new HttpError("DeepSeek response had no body", 502, "deepseek_error");
      }
      for await (const event of parseSse(response.body)) {
        if (event.event === "error" || event.data.trim() === "[DONE]") continue;
        let payload: Record<string, unknown>;
        try {
          payload = JSON.parse(event.data) as Record<string, unknown>;
        } catch {
          continue;
        }
        if (isRecord(payload.usage)) {
          usage = usageFromChatCompletion(payload);
        }
        const choice = Array.isArray(payload.choices) ? payload.choices[0] as Record<string, unknown> | undefined : undefined;
        if (!choice) continue;
        const delta = isRecord(choice.delta) ? choice.delta as Record<string, unknown> : {};
        const deltaText = extractText(delta.content);
        if (deltaText) {
          if (!textStarted) {
            textStarted = true;
            await writer.write(encoder.encode(formatSse({
              type: "response.output_item.added",
              output_index: 0,
              item: { id: messageId, type: "message", status: "in_progress", role: "assistant", content: [] }
            }, "response.output_item.added")));
            await writer.write(encoder.encode(formatSse({
              type: "response.content_part.added",
              item_id: messageId,
              output_index: 0,
              content_index: 0,
              part: { type: "output_text", text: "", annotations: [] }
            }, "response.content_part.added")));
          }
          text += deltaText;
          await writer.write(encoder.encode(formatSse({
            type: "response.output_text.delta",
            item_id: messageId,
            output_index: 0,
            content_index: 0,
            delta: deltaText
          }, "response.output_text.delta")));
        }
        const finish = asString(choice.finish_reason);
        if (finish === "stop" || finish === "length" || (event.data.trim() === "[DONE]")) {
          break;
        }
      }

      if (textStarted) {
        await writer.write(encoder.encode(formatSse({
          type: "response.output_text.done",
          item_id: messageId,
          output_index: 0,
          content_index: 0,
          text
        }, "response.output_text.done")));
        await writer.write(encoder.encode(formatSse({
          type: "response.content_part.done",
          item_id: messageId,
          output_index: 0,
          content_index: 0,
          part: { type: "output_text", text, annotations: [] }
        }, "response.content_part.done")));
        await writer.write(encoder.encode(formatSse({
          type: "response.output_item.done",
          output_index: 0,
          item: { id: messageId, type: "message", status: "completed", role: "assistant", content: [{ type: "output_text", text, annotations: [] }] }
        }, "response.output_item.done")));
      }
      if (!usage) usage = { input_tokens: 0, output_tokens: text.length, total_tokens: text.length };
      await writer.write(encoder.encode(formatSse({ type: "response.completed", response: baseResponse("completed", text, usage) }, "response.completed")));
    } catch (err) {
      const message = err instanceof Error ? err.message : "Stream failed";
      await writer.write(encoder.encode(formatSse({ error: { message, type: "deepseek_error", code: "deepseek_stream_error" } }, "error")));
    } finally {
      await writer.close().catch(() => undefined);
    }
  })();

  return readable;
}

function formatSse(data: unknown, event?: string): string {
  const payload = typeof data === "string" ? data : JSON.stringify(data);
  const lines: string[] = [];
  if (event) lines.push(`event: ${event}`);
  for (const line of payload.split("\n")) lines.push(`data: ${line}`);
  lines.push("", "");
  return lines.join("\n");
}
