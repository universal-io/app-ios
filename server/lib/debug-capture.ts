/**
 * Writes the exact bytes the model saw, next to the coordinates it returned.
 *
 * Coordinate faults on this path never raise. They produce a correct-sounding
 * answer pointing at the wrong place, which cannot be judged from a log line —
 * only by looking at the box drawn on the image the model was actually given.
 * Two fixes were shipped against this symptom before anyone had done that, and
 * both missed, so the artifacts exist to make the judgement possible at all.
 *
 * Off unless `UIO_DEBUG_CAPTURE_DIR` is set, and it never interrupts a request:
 * a diagnostic that can fail the thing it is diagnosing is worse than none.
 */

import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

const DIR = process.env.UIO_DEBUG_CAPTURE_DIR?.trim() || null;

export const debugCaptureEnabled = DIR !== null;

async function write(requestId: string, name: string, data: Uint8Array | string) {
  if (!DIR) return;
  try {
    const folder = join(DIR, requestId);
    await mkdir(folder, { recursive: true });
    await writeFile(join(folder, name), data);
  } catch (error) {
    console.log(`[debug-capture] could not write ${name}: ${String(error)}`);
  }
}

/** The upload as received — the same bytes handed to the model. */
export async function saveUpload(
  requestId: string,
  bytes: Uint8Array,
  mediaType: string,
): Promise<void> {
  const extension = mediaType === "image/png" ? "png" : mediaType === "image/webp" ? "webp" : "jpg";
  await write(requestId, `upload.${extension}`, bytes);
}

/** What was measured on the way in and what came back, in one readable file. */
export async function saveResult(requestId: string, payload: unknown): Promise<void> {
  await write(requestId, "result.json", JSON.stringify(payload, null, 2));
}
