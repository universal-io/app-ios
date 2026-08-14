#!/usr/bin/env python3
"""Draws the model's boxes onto the image the model was given.

Measurement A from docs/investigation-highlight-offset.md: this path never
touches the iOS app, so whatever it shows is the model's own accuracy. If the
boxes land on target here, the coordinates are right and the fault is in the
app's drawing. If they do not, no amount of work on the app will move them.

Usage:
    python3 scripts/draw-boxes.py <capture-dir> [<capture-dir> ...]

Each directory is one request, as written by lib/debug-capture.ts. Writes
annotated.png beside the upload and prints where each box landed.
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw


def draw(folder: Path) -> int:
    result_path = folder / "result.json"
    uploads = [p for p in folder.iterdir() if p.stem == "upload"]
    if not result_path.exists() or not uploads:
        print(f"{folder.name}: incomplete capture, skipping")
        return 1

    result = json.loads(result_path.read_text())
    image = Image.open(uploads[0]).convert("RGB")
    width, height = image.size

    # The decoded size must match what the server told the model, or the boxes
    # were normalized against a canvas nobody drew on.
    reported = result.get("reported_to_model", {})
    if (reported.get("width"), reported.get("height")) != (width, height):
        print(f"  MISMATCH: model was told {reported}, file decodes to {width}x{height}")

    canvas = ImageDraw.Draw(image)
    stroke = max(3, width // 300)

    for annotation in result.get("annotations", []):
        box = annotation["box"]
        left, top = box["x"] * width, box["y"] * height
        right, bottom = left + box["w"] * width, top + box["h"] * height
        canvas.rectangle([left, top, right, bottom], outline=(255, 0, 0), width=stroke)
        canvas.text((left + stroke, top + stroke), annotation.get("label", ""), fill=(255, 0, 0))
        print(
            f"  {annotation.get('label', '?')}: "
            f"x={box['x']:.3f} y={box['y']:.3f} w={box['w']:.3f} h={box['h']:.3f} "
            f"-> pixels ({left:.0f}, {top:.0f}) to ({right:.0f}, {bottom:.0f})"
        )

    out = folder / "annotated.png"
    image.save(out)
    print(f"  wrote {out}")
    return 0


def main() -> int:
    folders = [Path(arg) for arg in sys.argv[1:]]
    if not folders:
        print(__doc__)
        return 2
    for folder in folders:
        print(f"{folder.name}: {folder}")
        draw(folder)
    return 0


if __name__ == "__main__":
    sys.exit(main())
