import { HttpError, json, sseResponse } from "./http";
import { encodeSse } from "./sse";
import type { Deps, Env } from "./types";

export interface AnthropicMessageRequest {
  model: string;
  messages: AnthropicMessage[];
  max_tokens?: number;
  temperature?: number;
  top_p?: number;
  stream?: boolean;
  system?: string | AnthropicTextBlock[];
  tools?: AnthropicTool[];
  tool_choice?: AnthropicToolChoice;
  metadata?: Record<string, unknown>;
}

export interface AnthropicMessage {
  role: "user" | "assistant";
  content: string | AnthropicContentBlock[];
}

export type AnthropicContentBlock =
  | AnthropicTextBlock
  | AnthropicImageBlock
  | AnthropicToolUseBlock
  | AnthropicToolResultBlock;

export interface AnthropicTextBlock {
  type: "text";
  text: string;
}

export interface AnthropicImageBlock {
  type: "image";
  source: {
    type: "base64";
    media_type: string;
    data: string;
  };
}

export interface AnthropicToolUseBlock {
  type: "tool_use";
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export interface AnthropicToolResultBlock {
  type: "tool_result";
  tool_use_id: string;
  content?: string | AnthropicTextBlock[];
  is_error?: boolean;
}

export interface AnthropicTool {
  name: string;
  description?: string;
  input_schema: Record<string, unknown>;
}

export interface AnthropicToolChoice {
  type: "auto" | "any" | "tool";
  name?: string;
}

export interface AnthropicMessageResponse {
  id: string;
  type: "message";
  role: "assistant";
  content: AnthropicContentBlock[];
  model: string;
  stop_reason: "end_turn" | "max_tokens" | "stop_sequence" | "tool_use" | null;
  stop_sequence: string | null;
  usage: {
    input_tokens: number;
    output_tokens: number;
  };
}

export interface AnthropicStreamEvent {
  type: string;
  [key: string]: unknown;
}

const ANTHROPIC_VERSION = "2023-06-01";

export function isAnthropicRequest(pathname: string): boolean {
  return pathname === "/v1/messages" || pathname === "/messages";
}

export function matchAnthropicRoute(pathname: string): { kind: "messages" | "models" } | null {
  if (pathname === "/v1/messages" || pathname === "/messages") return { kind: "messages" };
  if (pathname === "/v1/models" || pathname === "/models") return { kind: "models" };
  return null;
}

export function anthropicModelList(): Record<string, unknown> {
  return {
    object: "list",
    data: [
      { type: "model", id: "claude-opus-4-20250514", display_name: "Claude Opus 4", created_at: "2025-05-14T00:00:00Z" },
      { type: "model", id: "claude-sonnet-4-20250514", display_name: "Claude Sonnet 4", created_at: "2025-05-14T00:00:00Z" },
      { type: "model", id: "claude-3-7-sonnet-20250219", display_name: "Claude 3.7 Sonnet", created_at: "2025-02-19T00:00:00Z" },
      { type: "model", id: "claude-3-5-sonnet-20241022", display_name: "Claude 3.5 Sonnet", created_at: "2024-10-22T00:00:00Z" },
      { type: "model", id: "claude-3-5-haiku-20241022", display_name: "Claude 3.5 Haiku", created_at: "2024-10-22T00:00:00Z" },
      { type: "model", id: "claude-3-opus-20240229", display_name: "Claude 3 Opus", created_at: "2024-02-29T00:00:00Z" },
      { type: "model", id: "claude-3-haiku-20240307", display_name: "Claude 3 Haiku", created_at: "2024-03-07T00:00:00Z" }
    ]
  };
}

export function convertAnthropicToOpenAI(request: AnthropicMessageRequest): Record<string, unknown> {
  const messages: Array<Record<string, unknown>> = [];

  if (request.system) {
    const systemText = typeof request.system === "string"
      ? request.system
      : request.system.map(b => b.text).join("\n");
    messages.push({ role: "system", content: systemText });
  }

  for (const msg of request.messages) {
    if (typeof msg.content === "string") {
      messages.push({ role: msg.role, content: msg.content });
      continue;
    }

    const textParts: string[] = [];
    const toolCalls: Array<Record<string, unknown>> = [];
    const toolResults: Array<Record<string, unknown>> = [];

    for (const block of msg.content) {
      switch (block.type) {
        case "text":
          textParts.push(block.text);
          break;
        case "image":
          textParts.push(`[Image: ${block.source.media_type}]`);
          break;
        case "tool_use":
          toolCalls.push({
            id: block.id,
            type: "function",
            function: {
              name: block.name,
              arguments: JSON.stringify(block.input)
            }
          });
          break;
        case "tool_result": {
          const resultContent = typeof block.content === "string"
            ? block.content
            : Array.isArray(block.content)
              ? block.content.map(b => b.text).join("\n")
              : "";
          toolResults.push({
            role: "tool",
            tool_call_id: block.tool_use_id,
            content: block.is_error ? `Error: ${resultContent}` : resultContent
          });
          break;
        }
      }
    }

    if (textParts.length > 0) {
      messages.push({ role: msg.role, content: textParts.join("\n") });
    }

    if (toolCalls.length > 0) {
      messages.push({ role: "assistant", tool_calls: toolCalls });
    }

    if (toolResults.length > 0) {
      messages.push(...toolResults);
    }
  }

  const openaiRequest: Record<string, unknown> = {
    model: request.model,
    messages,
    stream: request.stream ?? false
  };

  if (request.max_tokens) {
    openaiRequest.max_tokens = request.max_tokens;
  }
  if (request.temperature !== undefined) {
    openaiRequest.temperature = request.temperature;
  }
  if (request.top_p !== undefined) {
    openaiRequest.top_p = request.top_p;
  }

  if (request.tools && request.tools.length > 0) {
    openaiRequest.tools = request.tools.map(tool => ({
      type: "function",
      function: {
        name: tool.name,
        description: tool.description,
        parameters: tool.input_schema
      }
    }));

    if (request.tool_choice) {
      switch (request.tool_choice.type) {
        case "auto":
          openaiRequest.tool_choice = "auto";
          break;
        case "any":
          openaiRequest.tool_choice = "required";
          break;
        case "tool":
          openaiRequest.tool_choice = { type: "function", function: { name: request.tool_choice.name } };
          break;
      }
    }
  }

  return openaiRequest;
}

export function convertOpenAIToAnthropicResponse(
  openaiResponse: Record<string, unknown>,
  requestId: string
): AnthropicMessageResponse {
  const choices = openaiResponse.choices as Array<{ message: Record<string, unknown>; finish_reason: string }> | undefined;
  const choice = choices?.[0];
  const message = choice?.message ?? {};

  const content: AnthropicContentBlock[] = [];

  if (typeof message.content === "string" && message.content) {
    content.push({ type: "text", text: message.content });
  }

  if (Array.isArray(message.tool_calls)) {
    for (const tc of message.tool_calls) {
      const fn = tc.function;
      content.push({
        type: "tool_use",
        id: tc.id,
        name: fn.name,
        input: JSON.parse(fn.arguments)
      });
    }
  }

  let stopReason: AnthropicMessageResponse["stop_reason"] = "end_turn";
  if (choice?.finish_reason === "length") stopReason = "max_tokens";
  else if (choice?.finish_reason === "tool_calls") stopReason = "tool_use";
  else if (choice?.finish_reason === "stop") stopReason = "end_turn";

  const usage = openaiResponse.usage as { prompt_tokens?: number; completion_tokens?: number } | undefined;

  return {
    id: requestId || `msg_${Date.now()}`,
    type: "message",
    role: "assistant",
    content,
    model: (openaiResponse.model as string) || "claude-sonnet-4-20250514",
    stop_reason: stopReason,
    stop_sequence: null,
    usage: {
      input_tokens: usage?.prompt_tokens ?? 0,
      output_tokens: usage?.completion_tokens ?? 0
    }
  };
}

export function streamAnthropicResponse(
  openaiStream: ReadableStream<Uint8Array>,
  requestId: string,
  model: string
): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  let buffer = "";
  let messageStarted = false;
  let currentToolUseId = "";
  let currentToolName = "";
  let inputTokens = 0;
  let outputTokens = 0;

  const sendEvent = (event: AnthropicStreamEvent): Uint8Array => {
    return encoder.encode(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
  };

  const startEvent: AnthropicStreamEvent = {
    type: "message_start",
    message: {
      id: requestId || `msg_${Date.now()}`,
      type: "message",
      role: "assistant",
      content: [],
      model,
      stop_reason: null,
      stop_sequence: null,
      usage: { input_tokens: inputTokens, output_tokens: 0 }
    }
  };

  return new ReadableStream({
    start(controller) {
      controller.enqueue(sendEvent(startEvent));
    },
    async pull(controller) {
      const { done, value } = await openaiStream.getReader().read();
      if (done) {
        controller.enqueue(sendEvent({
          type: "message_delta",
          delta: { stop_reason: "end_turn", stop_sequence: null },
          usage: { output_tokens: outputTokens }
        }));
        controller.enqueue(sendEvent({ type: "message_stop" }));
        controller.close();
        return;
      }

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        if (!line.startsWith("data: ")) continue;
        const data = line.slice(6).trim();
        if (data === "[DONE]") continue;

        try {
          const chunk = JSON.parse(data);
          const choice = chunk.choices?.[0];
          if (!choice) continue;

          const delta = choice.delta;
          if (!delta) continue;

          if (delta.content) {
            if (!messageStarted) {
              messageStarted = true;
            }
            controller.enqueue(sendEvent({
              type: "content_block_start",
              index: 0,
              content_block: { type: "text", text: "" }
            }));
            controller.enqueue(sendEvent({
              type: "content_block_delta",
              index: 0,
              delta: { type: "text_delta", text: delta.content }
            }));
            controller.enqueue(sendEvent({ type: "content_block_stop", index: 0 }));
          }

          if (delta.tool_calls) {
            for (const tc of delta.tool_calls) {
              if (tc.id) {
                currentToolUseId = tc.id;
                currentToolName = tc.function?.name ?? "";
                controller.enqueue(sendEvent({
                  type: "content_block_start",
                  index: 1,
                  content_block: {
                    type: "tool_use",
                    id: currentToolUseId,
                    name: currentToolName,
                    input: {}
                  }
                }));
              }
              if (tc.function?.arguments) {
                controller.enqueue(sendEvent({
                  type: "content_block_delta",
                  index: 1,
                  delta: { type: "input_json_delta", partial_json: tc.function.arguments }
                }));
              }
            }
          }

          if (choice.finish_reason === "tool_calls" && currentToolUseId) {
            controller.enqueue(sendEvent({ type: "content_block_stop", index: 1 }));
          }

          if (chunk.usage) {
            inputTokens = chunk.usage.prompt_tokens ?? inputTokens;
            outputTokens = chunk.usage.completion_tokens ?? outputTokens;
          }
        } catch {
          // Skip malformed chunks
        }
      }
    }
  });
}

export async function proxyAnthropicMessages(
  env: Env,
  deps: Deps,
  request: AnthropicMessageRequest,
  upstreamKey: string
): Promise<Response> {
  const openaiRequest = convertAnthropicToOpenAI(request);
  const apiBase = env.DEEPSEEK_API_BASE || "https://api.deepseek.com";

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${upstreamKey}`
  };

  const response = await deps.fetch(`${apiBase}/chat/completions`, {
    method: "POST",
    headers,
    body: JSON.stringify(openaiRequest)
  });

  if (!response.ok) {
    const errorBody = await response.text();
    throw new HttpError(
      `Upstream API error: ${response.status}`,
      response.status,
      "upstream_error"
    );
  }

  if (request.stream) {
    const anthropicStream = streamAnthropicResponse(
      response.body!,
      `msg_${deps.randomUUID()}`,
      request.model
    );
    return sseResponse(anthropicStream);
  }

  const openaiResponse = await response.json() as Record<string, unknown>;
  const anthropicResponse = convertOpenAIToAnthropicResponse(
    openaiResponse,
    `msg_${deps.randomUUID()}`
  );
  return json(anthropicResponse, {
    headers: {
      "anthropic-version": ANTHROPIC_VERSION,
      "x-request-id": anthropicResponse.id
    }
  });
}
