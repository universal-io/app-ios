/**
 * Reads pixel dimensions out of the image bytes.
 *
 * The model must be told the exact size or it normalizes coordinates against a
 * canvas it assumes instead of the one it was given — measured 2026-08-13, that
 * put every box in the right column and the wrong row while the explanation
 * text stayed correct. A wrong answer that reads as a right one is the worst
 * kind, so the size is derived here rather than taken on trust from the client:
 * a caller cannot forget it, and cannot send one that disagrees with the image.
 */

export type ImageSize = { width: number; height: number };

export function imageSize(bytes: Uint8Array): ImageSize | null {
  return pngSize(bytes) ?? jpegSize(bytes) ?? webpSize(bytes);
}

function pngSize(b: Uint8Array): ImageSize | null {
  // 8-byte signature, then a 25-byte IHDR chunk whose width/height are at 16..23.
  if (b.length < 24) return null;
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (!signature.every((byte, i) => b[i] === byte)) return null;

  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  return { width: view.getUint32(16), height: view.getUint32(20) };
}

function jpegSize(b: Uint8Array): ImageSize | null {
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) return null;

  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let offset = 2;

  while (offset + 9 < b.length) {
    if (b[offset] !== 0xff) {
      offset += 1;
      continue;
    }
    const marker = b[offset + 1];

    // Standalone markers carry no length field.
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      offset += 2;
      continue;
    }
    // Start of frame, in any of its flavors except the two that are not frames.
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      return { height: view.getUint16(offset + 5), width: view.getUint16(offset + 7) };
    }
    const length = view.getUint16(offset + 2);
    if (length < 2) return null;
    offset += 2 + length;
  }
  return null;
}

function webpSize(b: Uint8Array): ImageSize | null {
  if (b.length < 30) return null;
  const tag = (start: number, text: string) =>
    text.split("").every((char, i) => b[start + i] === char.charCodeAt(0));
  if (!tag(0, "RIFF") || !tag(8, "WEBP")) return null;

  // Lossy: VP8 keyframe header holds 14-bit dimensions at bytes 26 and 28.
  if (tag(12, "VP8 ")) {
    const width = ((b[27] << 8) | b[26]) & 0x3fff;
    const height = ((b[29] << 8) | b[28]) & 0x3fff;
    return width && height ? { width, height } : null;
  }
  // Lossless: 14-bit dimensions minus one, packed from byte 21.
  if (tag(12, "VP8L")) {
    const bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
    return { width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1 };
  }
  // Extended: canvas size minus one at byte 24.
  if (tag(12, "VP8X")) {
    const width = (b[24] | (b[25] << 8) | (b[26] << 16)) + 1;
    const height = (b[27] | (b[28] << 8) | (b[29] << 16)) + 1;
    return { width, height };
  }
  return null;
}
