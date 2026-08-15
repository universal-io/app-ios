/**
 * The server's clock, so two machines can describe the same instant.
 *
 * The sender and the viewer are different devices with different clocks, and a
 * one-way latency computed across them is otherwise meaningless — this is the
 * measurement that M4 got wrong twice, in the other direction, by reporting
 * confident numbers for a link that was not carrying anything. Each side maps
 * its own clock onto this one and the difference between the two is a real
 * duration.
 *
 * The estimate assumes the two legs of the round trip take the same time. On a
 * local network the error that leaves is a few milliseconds, against a budget
 * of three hundred.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
  return new Response(JSON.stringify({ now: Date.now() }), {
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
