/**
 * The only place that knows which model runs and how to talk to it.
 *
 * Everything above this file deals in the app's own contract, so swapping the
 * provider is a change here and nowhere else. The wire shape follows the one
 * already proven in production for this model (app-mac's Gateway vision
 * engine), rather than an SDK whose released types may not yet cover it.
 */

import { ANALYZE_JSON_SCHEMA } from "./schema";

export const MODEL_ID = "gpt-5.6-luna";

const ENDPOINT = "https://api.openai.com/v1/responses";
const MAX_OUTPUT_TOKENS = 25_000;

/**
 * Vision guidance is latency-sensitive and this model answers well without a
 * reasoning pass, which is the reason it was chosen. Raise this if accuracy
 * measurements on real screens call for it (docs/roadmap.md M1).
 */
const REASONING_EFFORT = "none";

/** Send the frame as captured; downscaling is what makes a model misread digits. */
const IMAGE_DETAIL = "original";

export type VisionModelInput = {
  systemText: string;
  userText: string;
  extraText?: string | null;
  imageDataURL: string;
  history: Array<{ role: "user" | "assistant"; text: string }>;
};

export type VisionModelEvent =
  | { type: "delta"; text: string }
  | { type: "raw"; text: string };

export class ProviderError extends Error {
  readonly code: string;

  constructor(message: string, code = "PROVIDER_ERROR") {
    super(message);
    this.code = code;
  }
}

function requestBody(input: VisionModelInput, stream: boolean): Record<string, unknown> {
  const messages: Array<Record<string, unknown>> = [
    {
      role: "developer",
      content: [{ type: "input_text", text: input.systemText }],
    },
  ];

  for (const turn of input.history) {
    messages.push({
      role: turn.role,
      content: [
        {
          type: turn.role === "assistant" ? "output_text" : "input_text",
          text: turn.text,
        },
      ],
    });
  }

  const userContent: Array<Record<string, unknown>> = [
    { type: "input_text", text: input.userText },
  ];
  if (input.extraText) {
    userContent.push({ type: "input_text", text: input.extraText });
  }
  userContent.push({
    type: "input_image",
    image_url: input.imageDataURL,
    detail: IMAGE_DETAIL,
  });
  messages.push({ role: "user", content: userContent });

  return {
    model: MODEL_ID,
    // Screens carry other people's data. Opting out of retention is part of
    // what the product promises, so it is not a tunable.
    store: false,
    max_output_tokens: MAX_OUTPUT_TOKENS,
    reasoning: { effort: REASONING_EFFORT },
    text: {
      format: {
        type: "json_schema",
        name: "screen_guidance",
        strict: true,
        schema: ANALYZE_JSON_SCHEMA,
      },
    },
    input: messages,
    ...(stream ? { stream: true } : {}),
  };
}

/**
 * Yields incremental text as the model writes it, then the complete raw JSON.
 * The caller validates that JSON; the deltas are for reading only.
 */
export async function* streamVision(
  input: VisionModelInput,
  signal?: AbortSignal,
): AsyncGenerator<VisionModelEvent> {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new ProviderError("OPENAI_API_KEY is not set on the server.", "SERVER_MISCONFIGURED");
  }

  const response = await fetch(ENDPOINT, {
    method: "POST",
    signal,
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(requestBody(input, true)),
  });

  if (!response.ok || !response.body) {
    const detail = await response.text().catch(() => "");
    throw new ProviderError(
      `${MODEL_ID} failed with HTTP ${response.status}. ${truncate(detail)}`.trim(),
      response.status === 429 ? "RATE_LIMITED" : "PROVIDER_ERROR",
    );
  }

  let completed: ResponsesRoot | null = null;

  for await (const event of sseEvents(response.body)) {
    const type = typeof event.type === "string" ? event.type : "";

    if (type === "response.output_text.delta") {
      const chunk = typeof event.delta === "string" ? event.delta : "";
      if (chunk) yield { type: "delta", text: chunk };
      continue;
    }
    if (type === "response.completed") {
      completed = event.response as ResponsesRoot;
      break;
    }
    if (type === "response.failed" || type === "response.incomplete" || type === "error") {
      throw new ProviderError(`${MODEL_ID} ended the stream as ${type}.`);
    }
  }

  if (!completed) {
    throw new ProviderError(`${MODEL_ID} ended the stream without a completed response.`);
  }
  yield { type: "raw", text: outputText(completed) };
}

type ResponsesRoot = {
  status?: string;
  incomplete_details?: { reason?: string };
  output_text?: string;
  output?: Array<{
    type?: string;
    content?: Array<{ type?: string; text?: string; refusal?: string }>;
  }>;
};

function outputText(root: ResponsesRoot): string {
  if (root.status === "incomplete") {
    throw new ProviderError(
      `${MODEL_ID} returned an incomplete response: ${root.incomplete_details?.reason ?? "unknown"}`,
    );
  }

  if (typeof root.output_text === "string" && root.output_text.trim()) {
    return root.output_text;
  }

  for (const item of root.output ?? []) {
    if (item.type !== "message") continue;
    for (const content of item.content ?? []) {
      if (content.type === "refusal" && content.refusal) {
        throw new ProviderError(
          `The model declined to analyze this screen: ${content.refusal}`,
          "REFUSED",
        );
      }
      if (content.type === "output_text" && content.text?.trim()) {
        return content.text;
      }
    }
  }

  throw new ProviderError(`${MODEL_ID} returned no structured output.`);
}

/** Minimal SSE reader: yields each event's parsed `data` payload. */
async function* sseEvents(
  body: ReadableStream<Uint8Array>,
): AsyncGenerator<Record<string, unknown>> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let boundary = buffer.indexOf("\n\n");
      while (boundary !== -1) {
        const block = buffer.slice(0, boundary);
        buffer = buffer.slice(boundary + 2);
        const payload = dataOf(block);
        if (payload) yield payload;
        boundary = buffer.indexOf("\n\n");
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function dataOf(block: string): Record<string, unknown> | null {
  const lines = block.split("\n");
  const data = lines
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).replace(/^ /, ""))
    .join("\n");

  if (!data || data === "[DONE]") return null;
  try {
    const parsed: unknown = JSON.parse(data);
    return typeof parsed === "object" && parsed !== null
      ? (parsed as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function truncate(value: string): string {
  const trimmed = value.trim();
  return trimmed.length > 400 ? `${trimmed.slice(0, 400)}…` : trimmed;
}
