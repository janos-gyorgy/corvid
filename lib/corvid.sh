# corvid.sh — the shared chassis every bird in the flock runs on.
#
# WHY THIS EXISTS. Each bird used to carry its own copy of the same ~130 lines:
# dedicated checkout, single-flight lock, n8n notify, BLAST-RADIUS GUARD, dedup,
# commit, push-with-rebase-retry. Seven copies of a security boundary is six
# chances for it to drift — and it already had. On 2026-07-02 the `--allowedTools`
# no-op was corrected in five birds; wanderer and garden kept the broken form for
# ten weeks because the fix had to be applied by hand, seven times, correctly.
#
# So the rule this file enforces: THE CONTAINMENT CONTRACT LIVES IN ONE PLACE.
# A bird declares WHAT it forages and WHICH tools it may hold. It does not get to
# re-implement the guard, and it cannot silently disagree with it.
#
# Usage (see rook-run.sh for the reference implementation):
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/corvid.sh"
#
#   CORVID_TOOLS=(Read Glob Grep Write)     # the ONLY tools this bird may hold
#   CORVID_DENY=(Bash)
#   CORVID_COUNT_KEY="items"                # notify payload field name (optional)
#   CORVID_COUNT_VAR="NITEMS"               # which var holds it
#
#   corvid_init rook "$@"                   # config, logging, lock, trap
#   corvid_sync                             # pristine checkout, sets $QFILE
#   ...bird-specific FETCH here (wrapper-owned, no model in the loop)...
#   corvid_think "$PROMPT_FILE"             # the sandboxed claude call
#   corvid_guard                            # blast radius: only $QFILE may change
#   corvid_ship "rook: $DAY — %d find(s) quarantined"
#
# Every function below is wrapper-owned and runs OUTSIDE the model's reach.

# ── site configuration ────────────────────────────────────────────────────────
# Everything instance-specific lives in corvid-site.sh, sourced here if present,
# so this file is identical in every deployment and can be shared verbatim. Copy
# corvid-site.sh.example to corvid-site.sh and fill it in.
if [ -f "${BASH_SOURCE[0]%/*}/corvid-site.sh" ]; then
  # shellcheck disable=SC1091
  . "${BASH_SOURCE[0]%/*}/corvid-site.sh"
fi

CORVID_PROJECT="${CORVID_PROJECT:-corvid}"        # prefixes the per-bird checkout + state dirs
CORVID_REMOTE="${CORVID_REMOTE:?set CORVID_REMOTE in corvid-site.sh — the git remote the birds push to}"
CORVID_EMAIL_DOMAIN="${CORVID_EMAIL_DOMAIN:-localhost}"
CORVID_QDIR_BASE="${CORVID_QDIR_BASE:-quarantine}"
CORVID_DEDUP_CMD="${CORVID_DEDUP_CMD:-}"          # optional: <cmd> <qdir> <qfile>, run before staging
CORVID_DENY=()              # default: deny nothing extra; --tools is the real restriction

# ── WRITE SCOPE — the declared blast radius, asserted by corvid_guard ──────────
# The fleet has three classes and they are NOT the same shape, so the scope is
# data rather than hardcoded:
#   quarantine birds : mode=exact,   scope=(one file)                    magpie/bluejay/jackdaw/rook/kestrel
#   spark bird       : mode=exact,   scope=(one file) + extra allowlist  wander
#   editor bird      : mode=subtree, scope=(a subtree) + a file cap
CORVID_WRITE_SCOPE=()       # paths the run may change (defaults to $QFILE)
CORVID_GUARD_MODE=exact     # exact = these paths only | subtree = under these prefixes
CORVID_SCOPE_ALLOW=('^index/')   # regexes for wrapper/tooling-owned ignored artifacts
CORVID_MAX_FILES=0          # subtree mode: refuse a run that changed more than N (0 = uncapped)
CORVID_DEDUP=1              # run desk-dedup.py against $QFILE before staging
CORVID_MAKE_QDIR=1          # create quarantine/<bird>/ during sync (0 for vault-writing birds)
CORVID_CLEAN_IGNORED=1      # sync with `git clean -fdxq` (0 keeps gitignored index/ — garden)
CORVID_OK_STATUS=finds      # notify status on a successful run that changed something
CORVID_NOTHING_STATUS=nothing  # notify status when the run changed nothing (also a success)
CORVID_AUTHOR=              # git author slug; defaults to the bird name
CORVID_METER=               # name this bird books usage under in the cost ledger.
                            # Defaults to the bird name, BUT garden and wander have
                            # always metered as "gardener"/"wanderer" — keep those or
                            # exo-usage.sh reports one bird as two agents and the
                            # spend history silently splits in half.
CORVID_DETAIL=              # notify detail; defaults to "<n> find(s)"

# Optional per-bird hooks — the chassis calls them if the bird defines them:
#   corvid_hook_precommit    run just before the commit (e.g. `exo index`)
#   corvid_hook_commit_msg   echo the commit message (overrides the format string)
#   corvid_hook_on_exit      runs on EXIT instead of the default n8n notify (kestrel)
CORVID_BRANCH="${CORVID_BRANCH:-main}"

# ── corvid_profile <untrusted_reader|vault_editor> ────────────────────────────
# The fleet has exactly TWO threat models, and picking one should be a single
# legible act rather than five flags a new bird has to get right together:
#
#   untrusted_reader  diet is STRANGER TEXT (RSS, GitHub, job descriptions).
#                     No Bash, no Edit. Writes ONE file, in a quarantine path kept
#                     out of whatever consumes your repo, so output can never be
#                     ingested automatically. Promotion is a human act.
#
#   vault_editor      diet is your OWN repo. Holds Edit and Bash (for
#                     `exo search`) because nothing adversarial is in context —
#                     but the write scope is still declared and still asserted.
#
# A bird may override any single value after calling this; the profile is a
# starting posture, not a cage. What it prevents is a bird silently ending up
# with a grant nobody chose.
corvid_profile() {
  case "$1" in
    untrusted_reader)
      CORVID_TOOLS=(Read Glob Grep Write); CORVID_DENY=(Bash)
      CORVID_GUARD_MODE=exact; CORVID_MAKE_QDIR=1; CORVID_DEDUP=1
      ;;
    vault_editor)
      CORVID_TOOLS=(Read Edit Write Bash Glob Grep); CORVID_DENY=()
      CORVID_GUARD_MODE=exact; CORVID_MAKE_QDIR=0; CORVID_DEDUP=0
      CORVID_SCOPE_ALLOW=('^index/' '__pycache__/')
      ;;
    *) echo "corvid_profile: unknown profile '$1'" >&2; return 1 ;;
  esac
  CORVID_PROFILE="$1"
}

# ── corvid_init <name> [args...] ───────────────────────────────────────────────
# Derives every per-bird path from the one name, opens the log, takes the lock,
# and installs the EXIT trap. Everything after this point is logged.
corvid_init() {
  BIRD="$1"; shift

  export HOME="${HOME:?}"
  export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

  WORK="$HOME/git/$CORVID_PROJECT-$BIRD"          # dedicated checkout, NEVER your working tree
  QDIR="$CORVID_QDIR_BASE/$BIRD"                  # output lands here and nowhere else
  STATE="$HOME/.local/state/$CORVID_PROJECT-$BIRD"
  BRANCH="$CORVID_BRANCH"

  DRY_RUN=0
  [ "${1:-}" = "--dry-run" ] && DRY_RUN=1

  mkdir -p "$STATE"
  DAY="$(date -u +%Y-%m-%d)"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  LOG="$STATE/$BIRD-$DAY.log"
  exec > >(tee -a "$LOG") 2>&1
  echo "==== $BIRD run $TS  (dry_run=$DRY_RUN) ===="

  # end-of-run notification; "nothing" is a success status, not a failure
  local var="${BIRD^^}_N8N_WEBHOOK"
  WEBHOOK="${!var:-}"
  STATUS="started"; DETAIL=""; FINDS=0

  trap 'corvid_on_exit' EXIT

  exec 9>"$STATE/$BIRD.lock"
  if ! flock -n 9; then echo "another $BIRD run is active; exiting"; STATUS=ok; exit 0; fi
}

corvid_on_exit() {
  [ "$STATUS" = started ] && STATUS=failed
  if declare -F corvid_hook_on_exit >/dev/null; then
    corvid_hook_on_exit
  else
    [ "$DRY_RUN" = 1 ] || corvid_notify
  fi
  return 0
}

# ── corvid_notify ─────────────────────────────────────────────────────────────
# Posts the run outcome to n8n. The payload shape is preserved per bird via
# CORVID_COUNT_KEY / CORVID_COUNT_VAR so the existing n8n digest keeps working.
corvid_notify() {
  [ -n "${WEBHOOK:-}" ] || return 0
  local commit count_json="" finds_json=""
  commit="$(git -C "$WORK" --no-pager log --oneline -1 2>/dev/null || echo n/a)"
  # DETAIL can contain filenames the MODEL chose (e.g. "stray: <path>"), so this
  # payload is built by a JSON encoder, not by pasting strings together. Stripping
  # double quotes is not escaping — backslashes, newlines and control characters
  # all still break or inject. (Adversarial review, 2026-09-13.)
  python3 - "$STATUS" "$DAY" "$DETAIL" "$commit" \
           "${CORVID_COUNT_KEY:-}" "${CORVID_COUNT_VAR:+${!CORVID_COUNT_VAR:-0}}" \
           "${CORVID_EMIT_FINDS:-1}" "${FINDS:-0}" \
           "${RUN_COST_USD:-0}" "${RUN_TOKENS_IN:-0}" "${RUN_TOKENS_OUT:-0}" \
    > "$STATE/notify.json" <<'PY' || return 0
import json, sys
st, day, detail, commit, ckey, cval, emit, finds, cost, tin, tout = sys.argv[1:12]
def num(v):
    v = str(v).strip()
    try:
        return float(v) if "." in v else int(v)
    except ValueError:
        return 0
p = {"status": st, "day": day}
if ckey:
    p[ckey] = num(cval)
if emit == "1":
    p["finds"] = num(finds)
p.update({"cost_usd": num(cost), "tok_in": num(tin), "tok_out": num(tout),
          "detail": detail, "commit": commit})
json.dump(p, sys.stdout)
PY
  curl -fsS -m 10 -X POST "$WEBHOOK" -H 'Content-Type: application/json' \
    --data-binary "@$STATE/notify.json" >/dev/null 2>&1 || true
}

# ── corvid_sync ───────────────────────────────────────────────────────────────
# Clone once, else hard-reset to remote HEAD. -x also wipes ignored cruft
# (.env / index/*) so the tree the agent sees is genuinely pristine.
corvid_sync() {
  # A previous run tampered with .git. The checkout cannot be trusted and cannot
  # be cleaned in place, so discard it. Deliberately narrow: only a path this
  # function itself derives, only when it is a git checkout, only when flagged.
  if [ -f "$STATE/poisoned" ]; then
    if [ -d "$WORK/.git" ] && [ "$WORK" = "$HOME/git/$CORVID_PROJECT-$BIRD" ]; then
      echo "previous run poisoned .git — discarding $WORK and re-cloning"
      rm -rf "$WORK"
    fi
    rm -f "$STATE/poisoned"
  fi
  if [ ! -d "$WORK/.git" ]; then
    echo "cloning $BIRD checkout -> $WORK"
    git clone --branch "$BRANCH" "$CORVID_REMOTE" "$WORK"
  fi
  cd "$WORK"
  git fetch --quiet origin "$BRANCH"
  git reset --hard "origin/$BRANCH"
  if [ "${CORVID_CLEAN_IGNORED:-1}" = 1 ]; then git clean -fdxq; else git clean -fdq; fi
  [ "${CORVID_MAKE_QDIR:-1}" = 1 ] && mkdir -p "$QDIR"
  QFILE="$QDIR/$DAY.md"
}

# ── corvid_think <prompt-file> [extra claude args...] ─────────────────────────
# The sandboxed model call. THE TOOL GRANT IS NOT WRITTEN HERE BY HAND — it comes
# from CORVID_TOOLS/CORVID_DENY, which the bird declares once. `--tools` is the
# flag that actually restricts the available set; `--allowedTools` is a permission
# allowlist and is a NO-OP under bypassPermissions (the 2026-07-02 correction).
# MCP is emptied for every bird; a bird that needs MCP must say so explicitly.
corvid_think() {
  local prompt_file="$1"; shift
  : "${CORVID_TOOLS:?bird must declare CORVID_TOOLS}"
  CORVID_GIT_SEAL="$(_corvid_git_seal)"   # verified again in corvid_guard
  echo "---- claude ($BIRD): tools=${CORVID_TOOLS[*]} deny=${CORVID_DENY[*]-none} ----"
  source "$WORK/scripts/lib/claude-metered.sh"
  local deny=()
  [ "${#CORVID_DENY[@]}" -gt 0 ] && deny=(--disallowedTools "${CORVID_DENY[@]}")
  claude_metered "${CORVID_METER:-$BIRD}" "$(cat "$prompt_file")" \
    --append-system-prompt "$(cat CLAUDE.md)" \
    --permission-mode bypassPermissions \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --tools "${CORVID_TOOLS[@]}" "${deny[@]}" "$@"
}

# ── _corvid_in_scope <path> ──────────────────────────────────────────────────
# THE single place a path is tested against the declared scope, so corvid_guard
# and corvid_ship cannot drift into disagreeing about what "in scope" means.
# Returns 0 in scope, 2 allowlisted, 1 out of scope.
#
# Subtree matching is by PATH BOUNDARY, not string prefix: a scope of `sub` must
# not silently accept `sub-evil/`. (Found 2026-09-13 in an adversarial review.)
_corvid_in_scope() {
  local path="$1" sc allow_re=""
  [ "${#CORVID_SCOPE_ALLOW[@]}" -gt 0 ] && allow_re="$(IFS='|'; echo "${CORVID_SCOPE_ALLOW[*]}")"
  if [ -n "$allow_re" ] && [[ "$path" =~ $allow_re ]]; then return 2; fi
  for sc in "${CORVID_WRITE_SCOPE[@]}"; do
    if [ "${CORVID_GUARD_MODE:-exact}" = subtree ]; then
      sc="${sc%/}"
      case "$path" in "$sc"|"$sc"/*) return 0 ;; esac
    else
      [ "$path" = "$sc" ] && return 0
    fi
  done
  return 1
}

# ── .git INTEGRITY ────────────────────────────────────────────────────────────
# `git status` DOES NOT REPORT CHANGES INSIDE .git — so an agent holding only a
# Write tool can drop .git/hooks/post-commit, the guard reports clean, and then
# corvid_ship runs `git commit`, EXECUTING the hook with the wrapper's network
# access and push credentials. Found 2026-09-13 by an adversarial review of the
# README that asked what happens if git itself is the thing you tampered with.
#
# Between corvid_sync and corvid_guard nothing legitimate touches .git: the model
# has no git and no shell. So the window can be sealed strictly. Scoped to the
# CODE-EXECUTION and behaviour-altering surfaces — hooks, config, info — rather
# than all of .git, because objects and refs are content-addressed and git
# validates them itself, and hashing a large object store every run is a cost
# with no matching risk.
_corvid_git_seal() {
  {
    # hooks/info/config execute or alter behaviour; refs/HEAD/packed-refs decide
    # WHAT gets committed and pushed; modules/ carries submodule hooks.
    find .git/hooks .git/info .git/refs .git/modules -type f -printf '%m %p\n' \
         -exec sha256sum {} \; 2>/dev/null || true
    # `|| true`: a missing path (no .git/modules, no packed-refs in a fresh repo)
    # must not fail the seal under `set -euo pipefail` — it silently killed the run.
    sha256sum .git/config .git/HEAD .git/packed-refs 2>/dev/null || true
  } | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}

# ── _corvid_guard_one <path> ─────────────────────────────────────────────────
# Classify ONE changed path for corvid_guard. Updates the caller's `inscope` and
# `stray` (bash dynamic scope), so a directory expansion and a plain path go
# through exactly the same test.
_corvid_guard_one() {
  local path="$1" ok
  # A symlink among the CHANGED paths can redirect a write out of the tree even
  # when the path itself looks in scope — checking only declared paths missed this.
  if [ -L "${path%/}" ]; then stray+=("$path (symlink)"); return 0; fi
  # NOT `cmd; ok=$?` — under `set -e` a return of 2 (allowlisted) or 1 kills the
  # run before the guard can report. That silently failed the gardener 2026-09-14.
  ok=0; _corvid_in_scope "$path" || ok=$?
  case "$ok" in
    0) inscope=$((inscope+1)) ;;
    2) : ;;
    *) stray+=("$path") ;;
  esac
}

# ── corvid_guard ──────────────────────────────────────────────────────────────
# BLAST RADIUS ENFORCEMENT — the security boundary of the whole fleet, and the
# reason this file exists. ONLY $QFILE may change: tracked, untracked OR ignored.
# A run that wrote anywhere else is TAINTED — commit/push NOTHING and exit
# nonzero, because the same injection that breached the boundary may have shaped
# the in-bounds output too. `--ignored` catches .env / secrets that `git add -A`
# silently skips. EXCEPTION: index/ is the derived retrieval DB, re-created
# deterministically when claude starts in this tree — not agent output.
corvid_guard() {
  local mode="${CORVID_GUARD_MODE:-exact}" p path ok inscope=0

  # FIRST: did anything touch git's own machinery? Checked before the working
  # tree, because a poisoned hook would execute during the commit that follows.
  if [ -n "${CORVID_GIT_SEAL:-}" ] && [ "$(_corvid_git_seal)" != "$CORVID_GIT_SEAL" ]; then
    echo "BLAST RADIUS VIOLATION — .git was modified (hooks/config/info); committing nothing"
    # `git clean` and `reset --hard` do NOT remove files under .git, so a planted
    # hook would survive into the next run and fire on ITS commit. Mark the
    # checkout poisoned; corvid_sync re-clones from scratch before the next run.
    # The destructive step lives there, next to the clone that replaces it.
    : > "$STATE/poisoned"
    git clean -fdxq 2>/dev/null || true
    STATUS=violation; DETAIL=".git tampered — hooks or config changed during the run"
    exit 1
  fi
  local -a stray=()
  [ "${#CORVID_WRITE_SCOPE[@]}" -gt 0 ] || CORVID_WRITE_SCOPE=("$QFILE")

  # a declared path that is a symlink can redirect the write out of scope entirely
  if [ "$mode" = exact ]; then
    for p in "${CORVID_WRITE_SCOPE[@]}"; do
      if [ -L "$p" ]; then
        echo "BLAST RADIUS VIOLATION — $p is a symlink; committing nothing"
        git clean -fdxq; STATUS=violation; DETAIL="declared path is a symlink: $p"; exit 1
      fi
    done
  fi

  # NOTE: process substitution, not a pipe — a pipe would subshell $stray away.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # Porcelain renders rename/copy as "old -> new". Treat it as out of scope
    # unless BOTH sides are, rather than parsing a form a quoted filename can
    # also produce. Conservative on purpose.
    if [[ "$path" == *" -> "* ]]; then
      if _corvid_in_scope "${path%% -> *}" && _corvid_in_scope "${path##* -> }"; then
        inscope=$((inscope+1))
      else
        stray+=("$path")
      fi
      continue
    fi
    # `--ignored=matching` collapses a wholly-ignored directory to "dir/". Judge
    # every file inside it, not the directory name: otherwise an allowlist written
    # for files (`__pycache__/*.pyc`) refuses the directory, and a directory-level
    # allowlist would wave through anything hidden in it. (Gardener, 2026-09-14.)
    if [[ "$path" == */ ]] && [ -d "${path%/}" ] && [ ! -L "${path%/}" ]; then
      local f n=0
      while IFS= read -r -d '' f; do
        n=$((n+1)); _corvid_guard_one "$f"
      done < <(find "${path%/}" -mindepth 1 ! -type d -print0)
      [ "$n" -gt 0 ] || _corvid_guard_one "$path"   # empty dir: judge the name
      continue
    fi
    _corvid_guard_one "$path"
  done < <(git status --porcelain --untracked-files=all --ignored=matching | cut -c4-)

  if [ "${#stray[@]}" -gt 0 ]; then
    echo "BLAST RADIUS VIOLATION — run tainted; committing/pushing NOTHING. Out-of-bounds paths:"
    printf '%s\n' "${stray[@]}"
    git reset -q 2>/dev/null || true; git checkout -- . 2>/dev/null || true; git clean -fdxq
    STATUS=violation; DETAIL="stray: $(IFS=,; echo "${stray[*]}")"
    exit 1
  fi

  if [ "${CORVID_MAX_FILES:-0}" -gt 0 ] && [ "$inscope" -gt "${CORVID_MAX_FILES}" ]; then
    echo "BLAST RADIUS VIOLATION — $inscope files changed, declared cap is ${CORVID_MAX_FILES}"
    git reset -q 2>/dev/null || true; git checkout -- . 2>/dev/null || true; git clean -fdxq
    STATUS=violation; DETAIL="over cap: $inscope > ${CORVID_MAX_FILES}"
    exit 1
  fi
  echo "guard: clean ($inscope path(s) in declared scope, mode=$mode)"
}

# ── corvid_ship <commit-msg-fmt> [nothing-msg] ────────────────────────────────
# Trusted wrapper steps only, all AFTER corvid_guard: dedup against prior runs and
# the hand-muted desk list, stage, show the diff, stop on --dry-run, commit, push
# with one rebase retry.
corvid_ship() {
  local msg_fmt="$1" nothing_msg="${2:-no finds — successful run}"

  # Optional dedup against earlier runs / a hand-muted list. Site-configured
  # because what counts as a duplicate is specific to what the birds produce.
  if [ "${CORVID_DEDUP:-1}" = 1 ] && [ -n "$CORVID_DEDUP_CMD" ] && [ -f "$QFILE" ]; then
    # shellcheck disable=SC2086
    $CORVID_DEDUP_CMD "$QDIR" "$QFILE" || true
  fi

  if [ "${CORVID_GUARD_MODE:-exact}" = subtree ]; then
    git add -A -- "${CORVID_WRITE_SCOPE[@]}" 2>/dev/null || true
  else
    git add -- "${CORVID_WRITE_SCOPE[@]}" 2>/dev/null || true
  fi
  if git diff --cached --quiet; then
    STATUS="${CORVID_NOTHING_STATUS:-nothing}"; echo "$nothing_msg"; exit 0
  fi

  if [ -f "$QFILE" ]; then
    FINDS="$(grep -c '^## ' "$QFILE" 2>/dev/null || echo 0)"
  else
    FINDS="$(git diff --cached --name-only | grep -c . || echo 0)"
  fi
  echo "---- proposed changes ($FINDS) ----"
  git --no-pager diff --cached -- "${CORVID_WRITE_SCOPE[@]}"

  if [ "$DRY_RUN" = "1" ]; then
    echo "---- DRY RUN: NOT committing/pushing ----"
    git reset -q
    exit 0
  fi

  local who="${CORVID_AUTHOR:-$BIRD}" msg
  if declare -F corvid_hook_commit_msg >/dev/null; then
    msg="$(corvid_hook_commit_msg)"
  else
    msg="${msg_fmt//%d/$FINDS}"   # substitution, not printf: a format string is code
  fi
  declare -F corvid_hook_precommit >/dev/null && corvid_hook_precommit

  # TOCTOU. corvid_guard proved the tree was in scope at one instant — then dedup,
  # corvid_hook_commit_msg and corvid_hook_precommit all ran, and subtree mode
  # staged with `git add -A`. Re-assert on what is ACTUALLY STAGED here, after
  # every mutating step and immediately before the commit: this is the last
  # moment anything can still be stopped.
  #
  # Placement is the whole point. This check was first written above the hooks,
  # where a precommit hook could still stage a file after it ran — the exact
  # TOCTOU it exists to close. Caught by testing it with a hook that does that.
  local bad=() spath
  while IFS= read -r -d '' spath; do
    _corvid_in_scope "$spath" || bad+=("$spath")
  done < <(git diff --cached --name-only -z)
  if [ "${#bad[@]}" -gt 0 ]; then
    echo "BLAST RADIUS VIOLATION — out-of-scope paths STAGED after the guard ran:"
    printf '%s\n' "${bad[@]}"
    git reset -q 2>/dev/null || true; git checkout -- . 2>/dev/null || true; git clean -fdxq
    STATUS=violation; DETAIL="staged out of scope: $(IFS=,; echo "${bad[*]}")"
    exit 1
  fi

  git -c user.email="$who@$CORVID_EMAIL_DOMAIN" -c user.name="$CORVID_PROJECT $who" \
      commit -q -m "$msg"
  git push origin "$BRANCH" || {
    echo "push rejected (remote moved mid-run); rebasing this run's commit and retrying once"
    git fetch -q origin "$BRANCH"
    if git rebase origin/"$BRANCH"; then
      git push origin "$BRANCH"
    else
      git rebase --abort 2>/dev/null || true
      STATUS=pushfail; DETAIL="push rebase conflict — left for human"; echo "$DETAIL"; exit 1
    fi
  }
  [ "$STATUS" = violation ] || STATUS="${CORVID_OK_STATUS:-finds}"
  DETAIL="${CORVID_DETAIL:-$FINDS find(s)}"
  echo "pushed: $(git --no-pager log --oneline -1)"
}
