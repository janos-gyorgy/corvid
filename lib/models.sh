# models.sh — the ONE place model names live. SOURCE this.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/models.sh"
#   corvid_model_for_tier standard      # -> sonnet
#   corvid_fallback_for_tier standard   # -> best
#
# Birds name a TIER (light / standard / top), never a model. Tiers map to family
# ALIASES, never full model IDs: an alias resolves to the newest model of that
# family at run time, so a release carries the fleet forward on its own. Full-ID
# pins rotted twice (history in claude-metered.sh).
#
# Aliases are stable across versions but NOT across renames — a family can be
# retired or renamed. When that happens: edit THIS file, nothing else. The
# fallback keeps runs alive meanwhile, and claude-metered.sh pings ntfy when a
# run lands on a different family than it asked for, so a fallback is never
# silent. `best` = Fable if the account has it, else Opus.
#
# Emergency brake for a bad release (incidents only — it is a pin):
#   ANTHROPIC_DEFAULT_{FABLE,OPUS,SONNET,HAIKU}_MODEL=<full id> in the unit env.

MODEL_LIGHT=haiku
MODEL_STANDARD=sonnet
MODEL_TOP=best

MODEL_FALLBACK_LIGHT=sonnet
MODEL_FALLBACK_STANDARD=best
MODEL_FALLBACK_TOP=sonnet

corvid_model_for_tier() {
  case "${1:-}" in
    light)    echo "$MODEL_LIGHT" ;;
    standard) echo "$MODEL_STANDARD" ;;
    top)      echo "$MODEL_TOP" ;;
    *) return 1 ;;
  esac
}

corvid_fallback_for_tier() {
  case "${1:-}" in
    light)    echo "$MODEL_FALLBACK_LIGHT" ;;
    standard) echo "$MODEL_FALLBACK_STANDARD" ;;
    top)      echo "$MODEL_FALLBACK_TOP" ;;
    *) return 1 ;;
  esac
}

# corvid_model_matches <alias> <actual model id> — 0 if the run landed in the
# family it asked for. Unknown aliases (or a full ID passed as override) match
# only themselves.
corvid_model_matches() {
  local want="${1%%\[*}" got="$2"   # drop a context suffix like [1m]
  case "$want" in
    best) [[ "$got" == *fable* || "$got" == *opus* ]] ;;
    haiku|sonnet|opus|fable) [[ "$got" == *"$want"* ]] ;;
    *) [[ "$got" == "$want"* ]] ;;
  esac
}
