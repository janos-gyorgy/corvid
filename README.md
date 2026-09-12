# corvid

**A containment harness for scheduled LLM agents that read untrusted input.**

An agent declares what it may touch. After it stops, `corvid` checks what
actually changed — and if anything moved outside the declaration, the run is
discarded whole. Nothing is committed, nothing is published, the tree is reset.

It is about 250 lines of bash, has no dependencies beyond git and the Claude Code
CLI, and comes with a test suite that proves the containment holds.

---

## Why this exists

It was extracted from a fleet of seven scheduled agents that forage RSS, GitHub
and job boards — all of it text written by strangers — and write results into a
git repo. Three things happened while running them, and each one shaped this code.

**1. A containment control that wasn't.** The agents ran with
`--permission-mode bypassPermissions` and `--allowedTools Read Edit Write Bash Glob Grep`,
which reads exactly like a restriction and is not one: under bypassPermissions,
a *permission* allowlist restricts nothing. The flag that limits the available
tool set is `--tools`. Bash was live for three weeks on agents that were never
supposed to have it, and it was found by testing the boundary rather than by
reading the config — because the config looked right.

**2. Six copies of one guard.** Each agent carried its own hand-maintained copy
of the same blast-radius check. When the flag above was corrected, the fix was
applied by hand to five agents of seven. Two kept the broken form for ten more
weeks. Nobody noticed, because nothing ever *displayed* what an agent could reach.

**3. An injection battery that tested the wrong reader.** Six prompt-injection
payloads scored 0/6 against the agents — but all six were human-readable, and the
design ends with *a person* reading the quarantined output and promoting it by
hand. The boundary that was never tested is the one made of eyes.

So the design rules here are: **the containment contract lives in exactly one
place, it is data rather than a flag you retype, something renders it by default,
and there is a test that proves it.**

---

## The idea: assert the outcome, not the intent

Most agent sandboxing constrains *how* an agent can act — a container, a
permission prompt, a tool allowlist. Those are worth having, and they share a
weakness: you are trusting a configuration to mean what it appears to mean. See
incident 1.

`corvid` adds a different check, after the fact:

```
git status --porcelain --untracked-files=all --ignored=matching
```

Whatever the agent did, however it did it, this says what changed on disk. If
anything is outside the declared scope, the run is tainted and **nothing ships** —
not even the in-scope output, because the same breach that crossed the boundary
may have shaped the rest.

Three properties fall out of using git as the tamper-evidence layer:

- **`--ignored` catches what staging misses.** An agent writing `.env` is invisible
  to `git add -A`. It is not invisible here. That is one of the test cases.
- **Rollback is free.** A violation resets the tree; the checkout is disposable.
- **Nothing to trust.** The check reads the filesystem, not the agent's report of
  itself.

---

## Quick start

```bash
git clone https://github.com/janos-gyorgy/corvid && cd corvid
cp lib/corvid-site.sh.example lib/corvid-site.sh   # set CORVID_REMOTE
./corvid verify                                     # prove the guard holds
./examples/askhn-run.sh --dry-run                   # a real bird, commits nothing
```

A new agent:

```bash
./corvid new watcher --profile untrusted_reader
```

which writes a skeleton with the containment posture already correct and TODOs
only where judgement is required — the fetch step and the prompt.

---

## Anatomy of an agent

```bash
source "$SCRIPT_DIR/lib/corvid.sh"

corvid_profile untrusted_reader        # the threat model, in one line
corvid_init watcher "$@"               # paths, logging, single-flight lock, trap
corvid_sync                            # pristine checkout, hard-reset to remote
CORVID_WRITE_SCOPE=("$QFILE")          # the ONLY path this run may change

# ...your fetch here. WRAPPER-OWNED — the model is not in this phase...

corvid_think "$PROMPT_FILE"            # the sandboxed model call
corvid_guard                           # assert the blast radius
corvid_ship "watcher: %d find(s)"      # dedup, commit, push with rebase retry
```

The pipeline is deliberately split so the model sits in the middle and touches
neither end: **fetch is wrapper-owned, publish is wrapper-owned.** Untrusted text
enters the model's context, but the model has no instrument to act on it — no
shell, no network, no git. That separation is what makes a 0/6 injection result
mean something.

---

## The two profiles

| | `untrusted_reader` | `vault_editor` |
|---|---|---|
| diet | text written by strangers | your own repo |
| tools | Read, Glob, Grep, Write | + Edit, Bash |
| writes | one file, in quarantine | a declared subtree, with a file cap |
| promotion | a human act | committed directly |

A profile is a starting posture, not a cage — override any value after calling it.
What it prevents is an agent quietly ending up with a grant nobody chose.

---

## `corvid verify`

The guard is a security claim, so it ships with the test that checks it. Each case
builds a throwaway repo, performs the write an escaped agent would perform, and
asserts the guard refuses the run *and leaves nothing behind*.

```
corvid verify — 8 containment cases

  PASS  in-scope write only                        (expected: allowed)
  PASS  out-of-scope write                         (expected: refused)
  PASS  edit to an existing tracked file           (expected: refused)
  PASS  GITIGNORED file (.env)                     (expected: refused)
  PASS  declared path is a symlink                 (expected: refused)
  PASS  allowlisted path is permitted              (expected: allowed)
  PASS  subtree mode allows inside, refuses outside (expected: refused)
  PASS  subtree file cap                           (expected: refused)

all 8 containment cases hold
```

No model runs, nothing goes over the network, it finishes in about a second — so
it can gate every change to the chassis. Given that this project exists because a
control was decorative for ten weeks, a test that would have caught it is the
point rather than a nicety.

---

## `rookery`

A zero-dependency TUI over the fleet. It reads systemd, the per-agent logs, and
**each agent's script for its declared contract** — so the grant is on screen by
default rather than something you go digging for.

```
rookery  ·  7 birds  ·  2 hold Bash/Edit
  BIRD     SCHEDULE      LAST      NEXT  STATUS   COST    CONTAINMENT
▸ magpie   Sat 06:00     14h ago   6d    pushed   $1.02   quarantine/magpie/ · no Bash
  gardener Sun 03:00     17h ago   6h    pushed   $2.73   repo/ ⊂ · Bash+Edit

↑↓/jk move · r run · d dry-run · l log · e enable/disable · q quit
```

An agent still using the no-op `--allowedTools` form is flagged in red. It also
writes a JSON snapshot each render, so a dashboard can show the same view without
reimplementing the collection.

---

## Scheduling

`systemd/` has a templated unit and an example timer. Two details are load-bearing
and were both learned by losing runs:

- **`Persistent=true`.** cron has no catch-up. A machine powered off on a Saturday
  silently ate three agents with no signal anywhere, which is how they ended up on
  systemd timers.
- **A shared `flock` across agents.** `Persistent=true` means every timer missed
  during an outage fires at once on the next boot, and several concurrent model
  sessions will race each other into a rate limit. The mutex serialises the
  catch-up. Each agent also takes its own lock — that one prevents a second copy
  of the *same* agent; the shared one orders *different* ones.

---

## What this is not

- **Not a sandbox.** It does not stop an agent acting; it stops the result of a
  boundary breach from shipping. Pair it with whatever isolation you want —
  they answer different questions.
- **Not injection detection.** It never asks whether the input was malicious. It
  asks what changed on disk. That is why it holds against attacks nobody has
  thought of yet.
- **Not an agent framework.** There is no orchestration, no memory, no planner.
  It runs one model call between two wrapper-owned steps, and checks the damage.

## Requirements

git, bash 4+, python3 (stdlib only), and the
[Claude Code](https://claude.com/claude-code) CLI. Linux or macOS.

MIT.
