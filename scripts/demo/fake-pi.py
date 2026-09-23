#!/usr/bin/env python3
"""Deterministic Pi JSON stream for the recorded Psst demo."""

import json
import sys
import time

# Consume the request just like a harness would; output stays stable between runs.
sys.stdin.read()

chunks = [
    "The function finds the smallest uncovered number.\n\n",
    "It sorts a copy, then advances `candidate` only when the next value\n",
    "is exactly the one it needs. Duplicates and smaller values are skipped.\n\n",
    "The original input is unchanged because `table.sort` receives a copy.\n",
]

for chunk in chunks:
    event = {
        "type": "message_update",
        "assistantMessageEvent": {"type": "text_delta", "delta": chunk},
    }
    print(json.dumps(event), flush=True)
    time.sleep(0.35)
