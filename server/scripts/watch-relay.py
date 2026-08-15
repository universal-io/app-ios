#!/usr/bin/env python3
"""Prints, once a second, how many frames the relay actually received.

The browser sender runs its capture loop on a JavaScript timer, and browsers
slow those down hard in a tab that is not in front. That matters here more than
anywhere: the whole point of this product is explaining some *other* app, so the
sender tab is in the background exactly when it is being used for real.

This measures the sender alone. Counting by fetching frames would measure the
reader too — a slow observer looks like a slow sender.

Usage:
    python3 scripts/watch-relay.py [seconds] [base-url]
"""

import json
import sys
import time
import urllib.request

seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 40
base = sys.argv[2] if len(sys.argv) > 2 else "http://localhost:3000"


def sample() -> dict:
    with urllib.request.urlopen(f"{base}/api/mirror/status", timeout=5) as response:
        return json.loads(response.read())


previous = sample()
start = time.time()
print(f"{'t':>4}  {'fps':>5}  {'KB':>6}  frame age")

while time.time() - start < seconds:
    time.sleep(1)
    current = sample()
    elapsed = (current["now"] - previous["now"]) / 1000
    frames = current["sequence"] - previous["sequence"]
    rate = frames / elapsed if elapsed > 0 else 0
    age = current["age_ms"]
    age_text = "—" if age is None else f"{age / 1000:.1f}s"
    print(
        f"{time.time() - start:4.0f}  {rate:5.1f}  {current['bytes'] / 1024:6.0f}  {age_text}",
        flush=True,
    )
    previous = current
