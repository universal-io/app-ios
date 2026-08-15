/**
 * A relay for the "nothing installed on the Mac" experiment.
 *
 * The Mac companion needs an install and the accessibility permissions that go
 * with it, which is the wrong price for someone who wants to try this once. A
 * browser can share a screen with no install at all — the question is whether
 * what arrives is still fast enough and legible enough to explain, measured
 * against the same bar M4 set for the native path: 300ms one way, text readable.
 *
 * This is a measurement scaffold, not the shipping transport. It moves whole
 * JPEGs through an HTTP hop, where the real thing would negotiate WebRTC and
 * send H.264 between the two machines directly. A number produced here is an
 * upper bound on what the browser path costs: if it already passes, the question
 * is answered; if it does not, what has been ruled out is this scaffold, and not
 * browser sending.
 */

import { authenticate } from "@/lib/auth";
import { acceptFrame, freshFrame, waitForFrame } from "@/lib/mirror-relay";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Refuses anything that is not plausibly one frame. */
const MAX_FRAME_BYTES = 4 * 1024 * 1024;

export async function POST(request: Request): Promise<Response> {
  const auth = authenticate(request);
  if (!auth.ok) return json(auth.status, { error: auth.message });

  const body = await request.arrayBuffer();
  if (body.byteLength === 0) return json(400, { error: "Empty frame." });
  if (body.byteLength > MAX_FRAME_BYTES) return json(413, { error: "Frame too large." });

  const stamped = Number(request.headers.get("x-captured-at"));
  const frame = acceptFrame(new Uint8Array(body), Number.isFinite(stamped) ? stamped : null);

  return json(200, { sequence: frame.sequence, received_at: frame.receivedAt });
}

export async function GET(request: Request): Promise<Response> {
  const auth = authenticate(request);
  if (!auth.ok) return json(auth.status, { error: auth.message });

  const after = Number(new URL(request.url).searchParams.get("after") ?? "0");
  const known = Number.isFinite(after) ? after : 0;

  const frame = freshFrame(known) ?? (await waitForFrame(known));
  if (!frame) return new Response(null, { status: 204 });

  return new Response(frame.bytes as unknown as BodyInit, {
    status: 200,
    headers: {
      "Content-Type": "image/jpeg",
      "Cache-Control": "no-store",
      "x-sequence": String(frame.sequence),
      "x-captured-at": String(frame.capturedAt),
      "x-received-at": String(frame.receivedAt),
      "x-served-at": String(Date.now()),
    },
  });
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
