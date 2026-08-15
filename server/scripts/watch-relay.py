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


# A frame older than this means the sender is not running at all, rather than
# running slowly.
STALE_MS = 5_000

previous = sample()
start = time.time()
print(f"{'t':>4}  {'fps':>5}  {'KB':>6}  {'age':>7}  state")

idle = 0
measured = 0

while time.time() - start < seconds:
    time.sleep(1)
    current = sample()
    elapsed = (current["now"] - previous["now"]) / 1000
    frames = current["sequence"] - previous["sequence"]
    rate = frames / elapsed if elapsed > 0 else 0
    age = current["age_ms"]

    # Said outright, because a column of zeroes reads like a broken path and is
    # usually a sender nobody started. That misreading cost an afternoon on the
    # native side, where "100% loss" turned out to be a sleeping phone.
    if age is None or age > STALE_MS:
        state = "NOT SENDING — nothing to measure"
        idle += 1
    else:
        state = "sending"
        measured += 1

    age_text = "—" if age is None else f"{age / 1000:.1f}s"
    print(
        f"{time.time() - start:4.0f}  {rate:5.1f}  {current['bytes'] / 1024:6.0f}  "
        f"{age_text:>7}  {state}",
        flush=True,
    )
    previous = current

print()
if measured == 0:
    print("NO DATA: the sender was never running. This says nothing about the path.")
else:
    print(f"{measured} seconds of real sending, {idle} seconds idle.")
