/**
 * What the relay is holding, without the frame itself.
 *
 * Counting arrivals by fetching frames measures the observer as much as the
 * sender — a slow reader looks like a slow writer. This is the cheap sample:
 * take it twice and the difference in sequence is frames per second, whoever is
 * watching.
 */

import { peekRelay } from "@/lib/mirror-relay";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
  const relay = peekRelay();
  const now = Date.now();

  return new Response(
    JSON.stringify({
      sequence: relay.sequence,
      age_ms: relay.receivedAt === null ? null : now - relay.receivedAt,
      bytes: relay.bytes,
      now,
    }),
    { headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } },
  );
}
