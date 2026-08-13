/**
 * Beta-period access control. There are no accounts yet: the app ships with a
 * token, the server holds the list of valid ones, and a token can be dropped
 * from the list to cut a build off. Accounts and StoreKit entitlements replace
 * this before launch (docs/architecture.md section 5).
 */

const WINDOW_MS = 60_000;
const MAX_REQUESTS_PER_WINDOW = 20;

type Bucket = { count: number; resetAt: number };

// Process-local, so it does not hold across serverless instances. That is
// acceptable while the beta is a handful of testers: it bounds a runaway client
// rather than enforcing a quota. Move to a shared store before wider release.
const buckets = new Map<string, Bucket>();

export type AuthResult =
  | { ok: true; token: string }
  | { ok: false; status: number; code: string; message: string };

export function authenticate(request: Request): AuthResult {
  const configured = (process.env.BETA_TOKENS ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);

  if (configured.length === 0) {
    return {
      ok: false,
      status: 500,
      code: "SERVER_MISCONFIGURED",
      message: "BETA_TOKENS is not set on the server.",
    };
  }

  const header = request.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";

  if (!token || !configured.includes(token)) {
    return {
      ok: false,
      status: 401,
      code: "UNAUTHENTICATED",
      message: "Missing or unrecognized beta token.",
    };
  }

  return { ok: true, token };
}

export function checkRateLimit(key: string): AuthResult {
  const now = Date.now();
  const bucket = buckets.get(key);

  if (!bucket || now >= bucket.resetAt) {
    buckets.set(key, { count: 1, resetAt: now + WINDOW_MS });
    return { ok: true, token: key };
  }

  if (bucket.count >= MAX_REQUESTS_PER_WINDOW) {
    return {
      ok: false,
      status: 429,
      code: "RATE_LIMITED",
      message: `More than ${MAX_REQUESTS_PER_WINDOW} analyses in a minute. Wait a moment and try again.`,
    };
  }

  bucket.count += 1;
  return { ok: true, token: key };
}
