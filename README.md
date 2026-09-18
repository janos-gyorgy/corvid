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

## Model tiers

An agent names a **tier**, never a model:

```bash
CORVID_TIER=standard     # light | standard | top
```

`lib/models.sh` is the only file that names models, and it names family
**aliases** (`haiku`, `sonnet`, `best`), never full model IDs. An alias resolves
to the newest model in its family at run time, so a release moves the fleet
forward without anyone editing anything. A pinned ID does not: this fleet once
stopped mid-run on a spend limit with a premium pin, and later sat a whole model
generation behind on a pin nobody re-checked.

Aliases survive new versions, not renames. If a family is renamed or retired,
you edit `lib/models.sh` and nothing else. Meanwhile every call carries
`--fallback-model`, so runs keep going, and a run that lands on a different
family than it asked for warns on stderr and pings `CORVID_NTFY_URL` if set. A
silent fallback would just be the pinned-ID problem again, harder to see.

When `CORVID_NTFY_URL` (an ntfy topic URL from `lib/corvid-site.sh`) is set, the
end of every bird run also pushes a notification with the title `"<bird>:
<status>"` and a plain-text body carrying the run detail, the finds count, the
cost in USD and the last commit line. Because the POST goes to the full topic
URL, ntfy takes the body as the message text and reads the title, priority and
tags from HTTP headers; the body is sent as plain text (never as JSON) so it is
displayed verbatim. A failed run (a status outside the OK set) arrives as
priority `high` with a `warning` tag; a run that changed nothing is priority
`low`; a run with finds gets default priority. An optional `CORVID_NTFY_TOKEN`
is sent as an `Authorization: Bearer ...` header for a token-protected topic and
is never echoed into the log. Unset or empty URL = nothing is sent. Like the n8n
post, the request is best-effort: 10-second timeout, errors ignored, so it can
never slow or fail a run.

Without a tier an agent inherits the CLI default, which is whatever the operator
set for their own interactive sessions. That default silently moving every agent
is why tiers exist. The usage ledger records the model a run actually used next
to the one it asked for.

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

## Prior art, and where this actually fits

**What this is, stated plainly: a git working-tree integrity guard for unattended,
repo-only agents.** Not "the missing verification half of agent security" — that
would be a much bigger claim than 250 lines of bash earns. Everything below is
about which neighbouring problem each tool solves, because the boundaries matter
more than the category.

| Approach | Examples | The question it answers |
|---|---|---|
| **Isolation** | [E2B](https://e2b.dev) (Firecracker), Modal, Daytona, Vercel Sandbox, [microsandbox](https://github.com/microsandbox/microsandbox) (libkrun), gVisor | *Where does the agent run?* |
| **OS primitives** | Landlock, Seatbelt, bubblewrap; [Nono](https://www.helpnetsecurity.com/2026/07/27/nono-open-source-ai-agent-sandboxing/). Codex CLI and Anthropic's own runtime use these | *What may it touch, enforced by the kernel?* |
| **Capability monitors** | [PORTICO](https://arxiv.org/abs/2606.22504) — revocable, epoch-bound capabilities behind a reference monitor | *Which authority is still live, and when is it revoked?* |
| **Injection detection** | [promptfoo](https://promptfoo.dev), [garak](https://github.com/NVIDIA/garak), model-level guardrails | *Is this input trying something?* |
| **Diff review in CI** | blast-radius and impact-analysis tooling on agent-authored PRs | *Should this change be allowed to merge?* |
| **corvid** | this | *What actually changed, and does it match the declaration?* |

Isolation, OS primitives and capability monitors all **prevent**. Injection
detection **classifies the input**. Diff-review tooling **reviews an outcome with
a human waiting**. This one **verifies an outcome unattended, and discards**.
PORTICO names the prevent/verify distinction in its
own evaluation — "preventive enforcement rather than post-hoc auditing" — and
lands on the opposite side of it, which for most systems is the better side.

The case for also checking outcomes is narrow and specific: **prevention is what
failed here.** The agents ran behind a `--allowedTools` allowlist that reads as a
restriction and enforces nothing under `bypassPermissions`. Every preventive
control is a configuration you are trusting to mean what it appears to mean, and
that one was wrong for three weeks while looking correct in review.

It is tempting to conclude "prevention is unfalsifiable", and that would be
wrong. Prevention is perfectly testable — with denied-write probes, denied-network
probes, negative policy tests, sandbox denial logs. The honest lesson from that
incident is narrower and less flattering: **the preventive control here was never
tested, and an untested control is indistinguishable from a working one.**

So the actual claim is modest. This treats prevention as fallible configuration
and adds an independently implemented post-condition: after the run, the working
tree must contain only declared changes, including ignored files. It does not
make execution safe. It makes unauthorised repo mutations detectable and
discardable — and it ships `corvid verify` so the check itself is tested, which
is the same discipline the failed control lacked.

PORTICO's "lingering authority" is a good name for the same class of failure —
authority outliving the reason for it — reached from theory rather than by
losing three weeks to it.

### Where it overlaps

- **With diff-review tooling**, on mechanism. Both read a diff and assert against
  a policy. The difference is setting: those tools gate a pull request a human
  will review, this gates an unattended 04:00 run with nobody watching, and
  discards rather than flags.
- **With OS primitives**, on intent. `CORVID_WRITE_SCOPE` and a Landlock write
  allowlist express the same wish. Landlock enforces it properly; this only
  notices afterwards. They should be the same declaration — see below.
- **With isolation platforms**, only indirectly. Different layer, but overlapping
  concerns — filesystem mutation scope, rollback, egress, credential exposure.
  This is not a substitute for one. Run it inside one.

**The conclusion is "both", not "instead".** Nothing here argues against
prevention — the incident that produced this project argues that prevention alone
is unfalsifiable in practice, because a control that is not enforcing anything
looks identical to one that is. Prevent with the kernel, verify the outcome,
and let the second one tell you when the first stopped working.

### Where it is weaker — read this before adopting it

- **It cannot stop anything.** The write has already happened; the guard only
  ensures nothing ships. For an agent whose output is files in a repo that is
  sufficient. It is not "the agent was prevented from acting".
- **It only sees the working tree.** An agent that writes *outside* the repo is
  invisible to `git status`. The blast radius asserted here is the repo's, not
  the machine's — pair it with a real sandbox if that gap matters, which for
  most people it does.
- **Effects that are not files escape entirely.** If an agent can send an email,
  call an API, or post to a webhook, asserting the tree afterwards tells you
  nothing. The pipeline here keeps the model away from the network precisely
  because the guard cannot cover it. That is a design constraint, not a feature.
- **No egress control.** Network isolation is table stakes elsewhere and absent
  here. The model call itself needs the network, so the honest version needs an
  allowlisting proxy, and that is its own project.
- **Single machine, git required.** No orchestration, no multi-node story.
- **Whole classes of effect are out of scope**, and a 2026 reader should assume
  they are unhandled here: MCP and other tool servers, delegated CLIs running with
  their own privileges, ambient credentials (SSH agent, cloud config, kubeconfig,
  Docker socket, registry tokens), and supply-chain paths like install scripts or
  generated CI changes. "The working tree matches the declaration" says nothing
  about any of them. The pipeline compensates by giving the model no shell, no
  network and no MCP — a narrow diet, not a general answer.
- **Inside `.git`, only hooks, config and info are sealed.** Objects, refs and the
  index are not hashed: they are content-addressed and git validates them itself,
  and hashing an object store every run costs more than the risk warrants. Nested
  repos, submodules and worktrees are not specifically handled.

### What this wrapper specifically enforces

- **`--ignored=matching`.** An agent writing a gitignored `.env` is invisible to
  `git add -A`. Staging-based checks miss it; this does not, and it is a test case.
- **`.git` is sealed across the model call.** `git status` reports nothing inside
  `.git`, so an agent holding only a Write tool could plant `.git/hooks/post-commit`
  and have it execute during the commit the wrapper runs next — with the wrapper's
  push credentials. Hooks, config and info are hashed before the model runs and
  re-checked after; a mismatch discards the run and marks the checkout poisoned,
  so it is re-cloned rather than reused (`git clean` does not remove files under
  `.git`). Two test cases. **This bug was found by an adversarial review of this
  README, not by the tests — which is the honest argument for having both.**
- **All-or-nothing taint.** A breach discards the in-scope output too, on the
  assumption that whatever crossed the boundary may have shaped the rest.
- **Unattended, all-or-nothing.** Headless agents are common enough by now that
  this is not a differentiator on its own; the operational choice is that there
  is no human to escalate to at 03:00, so the only options are ship or discard.
- **The contract is rendered by default.** `rookery` shows every agent's grant on
  screen, because the ten-week drift happened in a config nobody ever looked at.

### The obvious next step

Generate a Landlock write allowlist from the same `CORVID_WRITE_SCOPE` the guard
asserts. One declaration, enforced by the kernel *and* verified afterwards. That
would narrow the out-of-repo **filesystem write** hole on Linux — it would not
touch network effects, credential exposure, delegated tools with their own
privileges, or macOS. Not built yet.

---

## What this is not

- **Not a sandbox.** It does not stop an agent acting; it stops the result of a
  boundary breach from shipping. Pair it with real isolation.
- **Not injection detection.** It never asks whether the input was malicious, only
  what changed on disk. That makes it indifferent to *how* a repo mutation was
  achieved — but only to repo mutations. Effects that are not files in the working
  tree are outside the claim entirely.
- **Not an agent framework.** No orchestration, no memory, no planner. One model
  call between two wrapper-owned steps, and a check on the damage.

## Requirements

git, bash 4+, python3 (stdlib only), and the
[Claude Code](https://claude.com/claude-code) CLI. Linux or macOS.

MIT.
