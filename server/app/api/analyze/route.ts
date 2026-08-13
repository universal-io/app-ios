import { authenticate, checkRateLimit } from "@/lib/auth";
import { loadContextPack } from "@/lib/context-packs";
import { imageSize } from "@/lib/image-size";
import { buildCandidateBlock, buildSystemPrompt, buildUserContent } from "@/lib/prompt";
import { clampResult, isAnalyzeResult, type AnalyzeRequest } from "@/lib/schema";
import { SummaryFieldStream } from "@/lib/summary-stream";
import { MODEL_ID, ProviderError, streamVision } from "@/lib/vision-model";

export const runtime = "nodejs";
export const maxDuration = 120;

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

  // Derived from the bytes rather than trusted from the caller, because the
  // model needs the exact size and getting it wrong fails silently.
  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(Buffer.from(body.image, "base64"));
  } catch {
    return errorResponse(400, "BAD_REQUEST", "image is not valid base64.");
  }
  const size = imageSize(bytes);
  if (!size) {
    return errorResponse(
      400,
      "BAD_REQUEST",
      "The image dimensions could not be read. Send a PNG, JPEG, or WebP.",
    );
  }

  const pack = await loadContextPack(body.context_pack_id);
  const candidateBlock = buildCandidateBlock(body);

  const input = {
    systemText: buildSystemPrompt(pack),
    userText: buildUserContent(body, candidateBlock !== null, size),
    extraText: candidateBlock,
    imageDataURL: `data:${mediaType(body)};base64,${body.image}`,
    history: (body.turns ?? []).slice(-MAX_TURNS).map((turn) => ({
      role: turn.role,
      text: turn.text,
    })),
  };

  const encoder = new TextEncoder();

  const sse = new ReadableStream<Uint8Array>({
    async start(controller) {
      const send = (event: string, data: unknown) => {
        controller.enqueue(
          encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
        );
      };
      const fail = (code: string, message: string) => {
        send("error", { request_id: body.request_id, error: { code, message } });
      };

      try {
        const summary = new SummaryFieldStream("summary");
        let raw = "";

        for await (const event of streamVision(input)) {
          if (event.type === "delta") {
            const text = summary.push(event.text);
            if (text) send("delta", { text });
          } else {
            raw = event.text;
          }
        }

        let parsed: unknown;
        try {
          parsed = JSON.parse(raw);
        } catch {
          fail("INVALID_RESULT", `${MODEL_ID} returned unparseable output.`);
          return;
        }

        if (!isAnalyzeResult(parsed)) {
          fail("INVALID_RESULT", `${MODEL_ID}'s output did not match the schema.`);
          return;
        }

        send("result", {
          request_id: body.request_id,
          ...clampResult(parsed),
          applied_context_pack: pack?.id ?? null,
          meta: { model: MODEL_ID },
        });
      } catch (error) {
        if (error instanceof ProviderError) {
          fail(error.code, error.message);
        } else {
          fail("PROVIDER_ERROR", describe(error));
        }
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

function describe(error: unknown): string {
  return error instanceof Error ? error.message : "Unknown error while contacting the model.";
}

function errorResponse(status: number, code: string, message: string): Response {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status,
    headers: { "content-type": "application/json" },
  });
}
