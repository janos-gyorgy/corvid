# claude-metered.sh — run `claude -p` with per-run usage capture. SOURCE this.
#
#   source "$WORK/scripts/lib/claude-metered.sh"
#   claude_metered <agent> <prompt> [extra claude args...]
#
# Wraps the call in `--output-format json`, appends ONE JSON row per run to the
# node-local ledger ($EXO_USAGE_LEDGER), prints the readable result text to
# stdout (so agent logs look unchanged), and exports for the caller's report:
#   RUN_COST_USD  RUN_TOKENS_IN  RUN_TOKENS_OUT  RUN_TURNS
#
# No model is pinned: agents follow whatever the CLI default resolves to
# (settings.json `model`, currently the `opus` alias -> claude-opus-5). Set
# EXO_CLAUDE_MODEL to force a specific model for one run or one bird.
#
# History: a premium model was pinned until 2026-07-27, when the fleet hit the monthly spend
# limit and every agent stopped mid-run (double
# rate for weekly foragers whose job is "read some feeds and usually find
# nothing"). Then pinned to an older model on the mistaken belief that no newer
# one existed; that held the fleet a generation back for weeks. Lesson: a hard
# pin needs re-checking every model release, and nobody was re-checking — so the
# pin is gone and the default carries the fleet forward on its own.
#
# Best-effort by contract: a metering/parse failure NEVER fails the agent run —
# on bad JSON it falls back to printing raw output and leaves the vars empty.
# The ledger lives OUTSIDE the vault (operational telemetry, never indexed).

# Resolves to <project>-usage, so an existing ledger keeps its path.
: "${EXO_USAGE_DIR:=$HOME/.local/state/${CORVID_PROJECT:-corvid}-usage}"
: "${EXO_USAGE_LEDGER:=$EXO_USAGE_DIR/ledger.jsonl}"

claude_metered() {
  local agent="$1"; shift
  local prompt="$1"; shift
  mkdir -p "$EXO_USAGE_DIR"
  local out err metrics rc=0
  out="$(mktemp)"; err="$(mktemp)"; metrics="$(mktemp)"
  RUN_COST_USD=""; RUN_TOKENS_IN=""; RUN_TOKENS_OUT=""; RUN_TURNS=""

  # `--output-format json` prints a single final object on stdout; tools still
  # execute. It MUST sit before any list-consuming flag (e.g. --allowedTools),
  # so inject it right after the prompt. Keep stderr SEPARATE — merging it
  # corrupts the JSON capture.
  claude -p "$prompt" --output-format json \
    ${EXO_CLAUDE_MODEL:+--model "$EXO_CLAUDE_MODEL"} "$@" >"$out" 2>"$err" || rc=$?
  cat "$err" >&2   # surface claude's own stderr into the agent log

  if AGENT="$agent" LEDGER="$EXO_USAGE_LEDGER" METRICS="$metrics" \
     python3 "$(dirname "${BASH_SOURCE[0]}")/cc-usage-parse.py" "$out"; then
    # shellcheck disable=SC1090
    [ -s "$metrics" ] && . "$metrics"
  else
    echo "[claude-metered] could not parse usage JSON; raw output follows" >&2
    cat "$out"
  fi

  rm -f "$out" "$err" "$metrics"
  return "$rc"
}
