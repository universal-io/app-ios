import { authenticate } from "@/lib/auth";
import { listContextPackIds } from "@/lib/context-packs";

export const runtime = "nodejs";

/** Lets the app populate its context-pack picker without shipping a hardcoded list. */
export async function GET(request: Request): Promise<Response> {
  const auth = authenticate(request);
  if (!auth.ok) {
    return new Response(
      JSON.stringify({ error: { code: auth.code, message: auth.message } }),
      { status: auth.status, headers: { "content-type": "application/json" } },
    );
  }

  return Response.json({ packs: await listContextPackIds() });
}
