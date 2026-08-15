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

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** How long a viewer's request waits for a new frame before returning empty. */
const LONG_POLL_MS = 10_000;

/** Refuses anything that is not plausibly one frame. */
const MAX_FRAME_BYTES = 4 * 1024 * 1024;

type Frame = {
  bytes: Uint8Array;
  sequence: number;
  /** When the sender drew it, on the server's timeline. */
  capturedAt: number;
  receivedAt: number;
};

type Relay = {
  frame: Frame | null;
  sequence: number;
  waiters: Array<(frame: Frame) => void>;
};

// On globalThis so a hot reload in dev does not silently start a second relay
// and leave the viewer waiting on the empty one.
const globalRelay = globalThis as typeof globalThis & { __uioMirrorRelay?: Relay };
const relay: Relay = (globalRelay.__uioMirrorRelay ??= { frame: null, sequence: 0, waiters: [] });

export async function POST(request: Request): Promise<Response> {
  const auth = authenticate(request);
  if (!auth.ok) return json(auth.status, { error: auth.message });

  const body = await request.arrayBuffer();
  if (body.byteLength === 0) return json(400, { error: "Empty frame." });
  if (body.byteLength > MAX_FRAME_BYTES) return json(413, { error: "Frame too large." });

  const capturedAt = Number(request.headers.get("x-captured-at"));
  const now = Date.now();

  relay.sequence += 1;
  relay.frame = {
    bytes: new Uint8Array(body),
    sequence: relay.sequence,
    capturedAt: Number.isFinite(capturedAt) ? capturedAt : now,
    receivedAt: now,
  };

  // Everyone waiting gets this frame, and nobody is left holding a request that
  // outlives the frame it was waiting for.
  const waiting = relay.waiters.splice(0);
  for (const resolve of waiting) resolve(relay.frame);

  return json(200, { sequence: relay.frame.sequence, received_at: now });
}

export async function GET(request: Request): Promise<Response> {
  const auth = authenticate(request);
  if (!auth.ok) return json(auth.status, { error: auth.message });

  const after = Number(new URL(request.url).searchParams.get("after") ?? "0");
  const known = Number.isFinite(after) ? after : 0;

  // Held open rather than answered empty, so the viewer gets the next frame the
  // instant it lands instead of on its own polling rhythm. Polling would put a
  // delay into the measurement that belongs to the instrument, not the path.
  const frame = relay.frame && relay.frame.sequence > known
    ? relay.frame
    : await waitForFrame(known);

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

function waitForFrame(after: number): Promise<Frame | null> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      const index = relay.waiters.indexOf(deliver);
      if (index >= 0) relay.waiters.splice(index, 1);
      resolve(null);
    }, LONG_POLL_MS);

    function deliver(frame: Frame) {
      clearTimeout(timer);
      resolve(frame.sequence > after ? frame : null);
    }

    relay.waiters.push(deliver);
  });
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
