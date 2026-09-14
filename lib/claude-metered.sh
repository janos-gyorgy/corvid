# claude-metered.sh — run `claude -p` with per-run usage capture. SOURCE this.
#
#   source "$WORK/scripts/lib/claude-metered.sh"
#   claude_metered <agent> <prompt> [extra claude args...]
#
# Wraps the call in `--output-format json`, appends ONE JSON row per run to the
# node-local ledger ($EXO_USAGE_LEDGER), prints the readable result text to
# stdout (so agent logs look unchanged), and exports for the caller's report:
#   RUN_COST_USD  RUN_TOKENS_IN  RUN_TOKENS_OUT  RUN_TURNS  RUN_MODEL  RUN_MODEL_REQUESTED
#
# Model choice, first match wins:
#   EXO_CLAUDE_MODEL  explicit override for one run (alias or full id; no fallback)
#   CORVID_TIER       light|standard|top -> alias + --fallback-model via models.sh
#   neither           inherit the CLI default (settings.json `model`)
# Every bird sets CORVID_TIER (added 2026-09-14): before that the whole fleet
# inherited the operator's GLOBAL interactive setting, so changing the session
# model silently moved every bird. Tiers map to family aliases, never full IDs.
# When a run lands on a different family than it asked for (fallback fired, or a
# family was renamed) it warns on stderr and, if CORVID_NTFY_URL is set (site
# config), pings it — a silent fallback is the pin rot below again.
#
# History: a premium model was pinned until 2026-07-27, when the fleet hit the monthly spend
# limit and every agent stopped mid-run (double
# rate for weekly foragers whose job is "read some feeds and usually find
# nothing"). Then pinned to an older model on the mistaken belief that no newer
# one existed; that held the fleet a generation back for weeks. Lesson: a hard
# pin needs re-checking every model release, and nobody was re-checking — so the
# pin is gone. Tiers (2026-09-14) keep that property: they map to
# family aliases, which move forward on their own; never write a full ID here.
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
  RUN_COST_USD=""; RUN_TOKENS_IN=""; RUN_TOKENS_OUT=""; RUN_TURNS=""; RUN_MODEL=""

  # shellcheck source=models.sh
  source "$(dirname "${BASH_SOURCE[0]}")/models.sh"
  local model_args=()
  RUN_MODEL_REQUESTED=""
  if [ -n "${EXO_CLAUDE_MODEL:-}" ]; then
    RUN_MODEL_REQUESTED="$EXO_CLAUDE_MODEL"
    model_args=(--model "$EXO_CLAUDE_MODEL")
  elif [ -n "${CORVID_TIER:-}" ]; then
    if RUN_MODEL_REQUESTED="$(corvid_model_for_tier "$CORVID_TIER")"; then
      model_args=(--model "$RUN_MODEL_REQUESTED"
                  --fallback-model "$(corvid_fallback_for_tier "$CORVID_TIER")")
    else
      echo "[claude-metered] WARN unknown CORVID_TIER='$CORVID_TIER'; using CLI default" >&2
      RUN_MODEL_REQUESTED=""
    fi
  fi
  export RUN_MODEL_REQUESTED

  # `--output-format json` prints a single final object on stdout; tools still
  # execute. It MUST sit before any list-consuming flag (e.g. --allowedTools),
  # so inject it right after the prompt. Keep stderr SEPARATE — merging it
  # corrupts the JSON capture.
  claude -p "$prompt" --output-format json \
    "${model_args[@]}" "$@" >"$out" 2>"$err" || rc=$?
  cat "$err" >&2   # surface claude's own stderr into the agent log

  if AGENT="$agent" LEDGER="$EXO_USAGE_LEDGER" METRICS="$metrics" \
     MODEL_REQUESTED="$RUN_MODEL_REQUESTED" \
     python3 "$(dirname "${BASH_SOURCE[0]}")/cc-usage-parse.py" "$out"; then
    # shellcheck disable=SC1090
    [ -s "$metrics" ] && . "$metrics"
    if [ -n "$RUN_MODEL_REQUESTED" ] && [ -n "$RUN_MODEL" ] \
       && ! corvid_model_matches "$RUN_MODEL_REQUESTED" "$RUN_MODEL"; then
      _claude_metered_mismatch "$agent" "$RUN_MODEL_REQUESTED" "$RUN_MODEL"
    fi
  else
    echo "[claude-metered] could not parse usage JSON; raw output follows" >&2
    cat "$out"
  fi

  rm -f "$out" "$err" "$metrics"
  return "$rc"
}

# Best-effort, never fails the run. Straight to ntfy (CORVID_NTFY_URL = full topic
# URL, from corvid-site.sh), not the bird's webhook: this is about the fleet's
# plumbing, not the bird's findings.
_claude_metered_mismatch() {
  local agent="$1" want="$2" got="$3"
  echo "[claude-metered] WARN model mismatch: $agent asked $want${CORVID_TIER:+ (tier $CORVID_TIER)}, ran $got" >&2
  [ -n "${CORVID_NTFY_URL:-}" ] || return 0
  curl -fsS -m 10 -H "Title: model mismatch: $agent" -H "Tags: warning" \
    -d "$agent asked $want${CORVID_TIER:+ (tier $CORVID_TIER)}, ran $got. Fallback fired or a family was renamed — check scripts/lib/models.sh." \
    "$CORVID_NTFY_URL" >/dev/null 2>&1 || true
}
