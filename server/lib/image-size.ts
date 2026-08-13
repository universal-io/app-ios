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

/** What the file says, before and after any rotation flag — for diagnosis. */
export type ImageFacts = {
  size: ImageSize;
  stored: ImageSize;
  orientation: number | null;
};

export function imageSize(bytes: Uint8Array): ImageSize | null {
  return imageFacts(bytes)?.size ?? null;
}

export function imageFacts(bytes: Uint8Array): ImageFacts | null {
  const png = pngSize(bytes);
  if (png) return { size: png, stored: png, orientation: null };

  const jpeg = jpegFacts(bytes);
  if (jpeg) return jpeg;

  const webp = webpSize(bytes);
  if (webp) return { size: webp, stored: webp, orientation: null };

  return null;
}

function pngSize(b: Uint8Array): ImageSize | null {
  // 8-byte signature, then a 25-byte IHDR chunk whose width/height are at 16..23.
  if (b.length < 24) return null;
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (!signature.every((byte, i) => b[i] === byte)) return null;

  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  return { width: view.getUint32(16), height: view.getUint32(20) };
}

/**
 * A JPEG's frame header describes the pixels as stored; an EXIF orientation tag
 * can then ask the viewer to rotate them. Measured 2026-08-14: the model reads
 * the rotated image, so the size that matters is the rotated one. Reporting the
 * stored size for a rotated photo made it divide the vertical axis by the wrong
 * number, which moved every box up the screen while the wording stayed right.
 *
 * Clients are expected to bake rotation into the pixels before uploading. This
 * covers the ones that do not, so a future client cannot reintroduce a failure
 * whose only symptom is a confident answer pointing at the wrong place.
 */
function jpegFacts(b: Uint8Array): ImageFacts | null {
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) return null;

  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let offset = 2;
  let stored: ImageSize | null = null;
  let orientation: number | null = null;

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

    const length = view.getUint16(offset + 2);
    if (length < 2) break;

    if (marker === 0xe1) {
      orientation = exifOrientation(view, b, offset + 4, length - 2) ?? orientation;
    }

    // Start of frame, in any of its flavors except the two that are not frames.
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      stored = { height: view.getUint16(offset + 5), width: view.getUint16(offset + 7) };
      // EXIF always precedes the frame header, so orientation is known by now.
      break;
    }
    offset += 2 + length;
  }

  if (!stored) return null;
  // 5 through 8 are the quarter-turns; they exchange the two axes.
  const rotated = orientation !== null && orientation >= 5 && orientation <= 8;
  return {
    size: rotated ? { width: stored.height, height: stored.width } : stored,
    stored,
    orientation,
  };
}

/** Reads tag 0x0112 out of IFD0. Returns null when the segment is not EXIF. */
function exifOrientation(
  view: DataView,
  b: Uint8Array,
  start: number,
  length: number,
): number | null {
  const header = "Exif\0\0";
  if (start + header.length > b.length) return null;
  for (let i = 0; i < header.length; i += 1) {
    if (b[start + i] !== header.charCodeAt(i)) return null;
  }

  const tiff = start + header.length;
  if (tiff + 8 > b.length) return null;

  const little = view.getUint16(tiff) === 0x4949;
  const u16 = (at: number) => view.getUint16(at, little);
  const u32 = (at: number) => view.getUint32(at, little);

  if (u16(tiff + 2) !== 0x002a) return null;

  const ifd = tiff + u32(tiff + 4);
  if (ifd + 2 > b.length) return null;

  const count = u16(ifd);
  const end = Math.min(ifd + 2 + count * 12, start + length, b.length - 12);

  for (let entry = ifd + 2; entry <= end; entry += 12) {
    if (u16(entry) === 0x0112) {
      const value = u16(entry + 8);
      return value >= 1 && value <= 8 ? value : null;
    }
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
