#!/usr/bin/env python3
"""cc-usage-parse.py — parse a `claude -p --output-format json` result.

Reads the JSON file at argv[1]. On success:
  - appends one row to $LEDGER (JSON-lines),
  - writes shell assignments to $METRICS (RUN_COST_USD / RUN_TOKENS_IN / ...),
  - prints the human-readable .result text to stdout,
  - prints a one-line usage summary to stderr,
  - exits 0.
On non-JSON / unreadable input, exits 1 so the caller falls back to raw output.
Ledger/metrics writes are best-effort and never raise.
"""
import json, os, sys, datetime

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        raise ValueError("not an object")
except Exception:
    sys.exit(1)

u = d.get("usage") or {}
cost = d.get("total_cost_usd")
model = next(iter((d.get("modelUsage") or {}).keys()), None)
row = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "day": datetime.date.today().isoformat(),
    "agent": os.environ.get("AGENT", "unknown"),
    "cost_usd": cost,
    "input": u.get("input_tokens"),
    "output": u.get("output_tokens"),
    "cache_creation": u.get("cache_creation_input_tokens"),
    "cache_read": u.get("cache_read_input_tokens"),
    "turns": d.get("num_turns"),
    "duration_ms": d.get("duration_ms"),
    "model": model,
    "session_id": d.get("session_id"),
    "is_error": d.get("is_error"),
}

ledger = os.environ.get("LEDGER")
if ledger:
    try:
        with open(ledger, "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    except Exception:
        pass

metrics = os.environ.get("METRICS")
if metrics:
    try:
        with open(metrics, "w", encoding="utf-8") as f:
            f.write(f"RUN_COST_USD={cost if cost is not None else ''}\n")
            f.write(f"RUN_TOKENS_IN={u.get('input_tokens') or ''}\n")
            f.write(f"RUN_TOKENS_OUT={u.get('output_tokens') or ''}\n")
            f.write(f"RUN_TURNS={d.get('num_turns') or ''}\n")
    except Exception:
        pass

print(d.get("result", "") or "")
sys.stderr.write(
    "usage: $%.4f  in=%s out=%s cache_r=%s turns=%s  [%s]\n"
    % (cost or 0, u.get("input_tokens"), u.get("output_tokens"),
       u.get("cache_read_input_tokens"), d.get("num_turns"),
       os.environ.get("AGENT", "?"))
)
