/**
 * Context packs are the product's differentiator: organization-specific
 * knowledge injected into the prompt so guidance reflects that organization's
 * correct answer rather than a generic one (see README).
 *
 * A pack is data. It never touches control flow, so a request that names no
 * pack — or names one that no longer exists — runs the generic path unchanged.
 *
 * v1 keeps packs as files checked into the repo. Upload and per-organization
 * management arrive once B2B validation starts (docs/roadmap.md M3).
 */

import { readFile, readdir } from "node:fs/promises";
import path from "node:path";

const PACK_DIR = path.join(process.cwd(), "context-packs");
const MAX_PACK_CHARS = 20_000;

export type ContextPack = { id: string; body: string };

export async function listContextPackIds(): Promise<string[]> {
  try {
    const entries = await readdir(PACK_DIR);
    return entries
      .filter((entry) => entry.endsWith(".md"))
      .map((entry) => entry.replace(/\.md$/, ""))
      .sort();
  } catch {
    return [];
  }
}

export async function loadContextPack(id: string | undefined): Promise<ContextPack | null> {
  if (!id) return null;

  // The id becomes a filename, so anything that could escape the pack
  // directory is rejected rather than sanitized.
  if (!/^[a-zA-Z0-9._-]+$/.test(id) || id.startsWith(".")) return null;

  try {
    const body = await readFile(path.join(PACK_DIR, `${id}.md`), "utf8");
    return { id, body: body.slice(0, MAX_PACK_CHARS) };
  } catch {
    return null;
  }
}
