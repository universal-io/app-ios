import Anthropic from "@anthropic-ai/sdk";

import { authenticate, checkRateLimit } from "@/lib/auth";
import { loadContextPack } from "@/lib/context-packs";
import { buildCandidateBlock, buildSystemPrompt, buildUserContent } from "@/lib/prompt";
import {
  ANALYZE_JSON_SCHEMA,
  clampResult,
  isAnalyzeResult,
  type AnalyzeRequest,
} from "@/lib/schema";
import { SummaryFieldStream } from "@/lib/summary-stream";

export const runtime = "nodejs";
export const maxDuration = 120;

const MODEL = "claude-opus-5";
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_TURNS = 20;

const ALLOWED_MEDIA_TYPES = ["image/jpeg", "image/png", "image/webp"] as const;
type AllowedMediaType = (typeof ALLOWED_MEDIA_TYPES)[number];

export async function POST(request: Request): Promise<Response> {
  const auth = authenticate(request);
  if (!auth.ok) return errorResponse(auth.status, auth.code, auth.message);

  const limit = checkRateLimit(auth.token);
  if (!limit.ok) return errorResponse(limit.status, limit.code, limit.message);

  let body: AnalyzeRequest;
  try {
    body = (await request.json()) as AnalyzeRequest;
  } catch {
    return errorResponse(400, "BAD_REQUEST", "Body is not valid JSON.");
  }

  const invalid = validate(body);
  if (invalid) return errorResponse(400, "BAD_REQUEST", invalid);

  const pack = await loadContextPack(body.context_pack_id);
  const candidateBlock = buildCandidateBlock(body);

  const content: Anthropic.Beta.BetaContentBlockParam[] = [
    {
      type: "image",
      source: {
        type: "base64",
        media_type: mediaType(body),
        data: body.image,
      },
    },
    { type: "text", text: buildUserContent(body, candidateBlock !== null) },
  ];
  if (candidateBlock) content.push({ type: "text", text: candidateBlock });

  const history = (body.turns ?? []).slice(-MAX_TURNS).map((turn) => ({
    role: turn.role,
    content: turn.text,
  }));

  const client = new Anthropic();

  const params = {
    model: MODEL,
    max_tokens: 16000,
    system: buildSystemPrompt(pack),
    messages: [...history, { role: "user", content }],
    output_config: {
      // Guidance quality is what makes or breaks this product, so start high and
      // sweep down against real screens rather than guessing (docs/roadmap.md M1).
      effort: "high",
      format: { type: "json_schema", schema: ANALYZE_JSON_SCHEMA },
    },
    // Claude Opus 5's safety classifiers can decline a request; without this a
    // refusal just stops. "default" re-serves it on Anthropic's recommended
    // fallback, routed by refusal category.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
  };

  const encoder = new TextEncoder();

  const sse = new ReadableStream<Uint8Array>({
    async start(controller) {
      const send = (event: string, data: unknown) => {
        controller.enqueue(
          encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
        );
      };

      try {
        // The SDK's published types trail the current API surface for
        // `fallbacks` and `output_config.format`; the wire shape above is the
        // contract we target.
        const stream = client.beta.messages.stream(
          params as unknown as Anthropic.Beta.MessageCreateParamsStreaming,
        );

        const summary = new SummaryFieldStream("summary");

        for await (const event of stream) {
          if (
            event.type === "content_block_delta" &&
            event.delta.type === "text_delta"
          ) {
            const text = summary.push(event.delta.text);
            if (text) send("delta", { text });
          }
        }

        const message = await stream.finalMessage();

        if (message.stop_reason === "refusal") {
          send("error", {
            request_id: body.request_id,
            error: {
              code: "REFUSED",
              message:
                "The model declined to analyze this screen. Try a different screen or rephrase the question.",
            },
          });
          controller.close();
          return;
        }

        const raw = message.content
          .filter((block): block is Anthropic.Beta.BetaTextBlock => block.type === "text")
          .map((block) => block.text)
          .join("");

        let parsed: unknown;
        try {
          parsed = JSON.parse(raw);
        } catch {
          send("error", {
            request_id: body.request_id,
            error: { code: "INVALID_RESULT", message: "The model returned unparseable output." },
          });
          controller.close();
          return;
        }

        if (!isAnalyzeResult(parsed)) {
          send("error", {
            request_id: body.request_id,
            error: { code: "INVALID_RESULT", message: "The model's output did not match the schema." },
          });
          controller.close();
          return;
        }

        send("result", {
          request_id: body.request_id,
          ...clampResult(parsed),
          applied_context_pack: pack?.id ?? null,
          meta: { model_fallback_used: usedFallback(message) },
        });
      } catch (error) {
        send("error", {
          request_id: body.request_id,
          error: { code: "PROVIDER_ERROR", message: describe(error) },
        });
      } finally {
        controller.close();
      }
    },
  });

  return new Response(sse, {
    headers: {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache, no-transform",
      connection: "keep-alive",
    },
  });
}

function validate(body: AnalyzeRequest): string | null {
  if (typeof body?.request_id !== "string" || body.request_id.length === 0) {
    return "request_id is required.";
  }
  if (typeof body.image !== "string" || body.image.length === 0) {
    return "image is required and must be base64.";
  }
  // base64 encodes 3 bytes per 4 characters.
  if ((body.image.length * 3) / 4 > MAX_IMAGE_BYTES) {
    return `image exceeds ${MAX_IMAGE_BYTES} bytes; downscale before sending.`;
  }
  if (body.image_media_type && !isAllowedMediaType(body.image_media_type)) {
    return `image_media_type must be one of ${ALLOWED_MEDIA_TYPES.join(", ")}.`;
  }
  if (body.tap_point) {
    const { x, y } = body.tap_point;
    if (typeof x !== "number" || typeof y !== "number") {
      return "tap_point must have numeric x and y.";
    }
  }
  return null;
}

function isAllowedMediaType(value: string): value is AllowedMediaType {
  return (ALLOWED_MEDIA_TYPES as readonly string[]).includes(value);
}

function mediaType(body: AnalyzeRequest): AllowedMediaType {
  return body.image_media_type && isAllowedMediaType(body.image_media_type)
    ? body.image_media_type
    : "image/jpeg";
}

function usedFallback(message: Anthropic.Beta.BetaMessage): boolean {
  return message.content.some((block) => (block as { type: string }).type === "fallback");
}

function describe(error: unknown): string {
  if (error instanceof Anthropic.APIError) return `${error.status ?? ""} ${error.message}`.trim();
  if (error instanceof Error) return error.message;
  return "Unknown error while contacting the model.";
}

function errorResponse(status: number, code: string, message: string): Response {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status,
    headers: { "content-type": "application/json" },
  });
}
