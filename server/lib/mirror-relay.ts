/**
 * The newest frame the browser sender produced, and whoever is waiting for it.
 *
 * Held here rather than in the route because two routes need it — one to serve
 * the picture, one to report the rate without copying the picture out — and a
 * Next route module may only export handlers.
 *
 * One frame, not a queue. M4's clearest finding was that sending faster than the
 * far end accepts does not lose frames, it queues them, and the delay grows
 * without bound while every counter still looks healthy. A mirror only ever
 * wants the newest frame, so the older one is replaced rather than stored.
 */

export type Frame = {
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

/**
 * How old the newest frame may be before the relay treats it as no frame.
 *
 * A sender running at any rate replaces this several times a second, even on a
 * screen that is not changing, so a frame this old means the sender stopped.
 * Handing it over anyway shows a picture of the past as though it were the
 * present, which is the fault M4 ruled out on the native path.
 */
export const STALE_MS = 5_000;

/** How long a viewer's request waits for a new frame before returning empty. */
const LONG_POLL_MS = 10_000;

export function acceptFrame(bytes: Uint8Array, capturedAt: number | null): Frame {
  const now = Date.now();
  relay.sequence += 1;
  relay.frame = {
    bytes,
    sequence: relay.sequence,
    capturedAt: capturedAt ?? now,
    receivedAt: now,
  };

  // Everyone waiting gets this frame, and nobody is left holding a request that
  // outlives the frame it was waiting for.
  const waiting = relay.waiters.splice(0);
  for (const resolve of waiting) resolve(relay.frame);

  return relay.frame;
}

/** The newest frame if it is both new to the caller and still current. */
export function freshFrame(after: number): Frame | null {
  const held = relay.frame;
  if (!held) return null;
  if (held.sequence <= after) return null;
  if (Date.now() - held.receivedAt >= STALE_MS) return null;
  return held;
}

/**
 * Held open rather than answered empty, so the viewer gets the next frame the
 * instant it lands instead of on its own polling rhythm. Polling would put a
 * delay into the measurement that belongs to the instrument, not the path.
 */
export function waitForFrame(after: number): Promise<Frame | null> {
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

/** What is here, without copying the frame out. */
export function peekRelay(): { sequence: number; receivedAt: number | null; bytes: number } {
  return {
    sequence: relay.sequence,
    receivedAt: relay.frame?.receivedAt ?? null,
    bytes: relay.frame?.bytes.byteLength ?? 0,
  };
}
