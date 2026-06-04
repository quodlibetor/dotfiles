---
name: bwm-review
description: Deep error-search review of the current jj working-copy change (or a specified jj revision) using two mandatory fresh-context sub-agents — a correctness agent that traces blast radius for logic bugs and far-reaching effects, and a maintainability agent that biases toward the future (comment accuracy, unexplained intentional-wrongness, duplication, readability). Auto-fixes high-confidence findings and reports the rest. Use when the user says "/bwm-review", "bwm review", "review my change(s)", "review this commit", "blast-radius review", or asks for a deep correctness + maintainability pass on a change before committing/pushing.
---

# bwm-review

A pre-merge review that takes the long view. A PR is read once; misleading, verbose, or
duplicated code is debugged over and over for years. So this skill is not a polite
nitpick pass — it digs for real defects and real future-cost, and it **fixes what it
finds** rather than logging it for later.

Two sub-agents are **mandatory** and always run, in parallel, each with **fresh context**
(no conversation history) so they judge the code independently:

- **correctness** — blast-radius and logic-bug hunter, *guided* by a brief from the
  implementing Claude about what's likely to matter.
- **maintainability** — biases toward the future: comment accuracy, unexplained
  intentional wrongness, duplication, and readability.

You may add task-specific agents on top of these two (e.g. a concurrency agent for a lock
change), but never fewer.

## Step 0 — Preflight

1. **Require jj.** This skill drives Jujutsu. If `.jj/` is absent, stop and tell the user
   it's jj-only. Read the `jujutsu` skill's safety rules before mutating anything — never
   touch a change the user didn't initiate without confirmation.
2. **Resolve the target revision.** The skill argument is a jj revset; default to `@`
   (the current working copy) when none is given.
   - `TARGET=<arg or @>`
3. **Make a unique per-review run directory.** Several reviews may run at once — multiple
   agents, multiple repos, even multiple revisions of the same repo — so never use a fixed
   global path that another review would clobber. Create one isolated dir per invocation
   and put every scratch file (diff, brief, agent notes) inside it:
   - `RUNDIR="$(mkdir -p /tmp/bwm-review && mktemp -d /tmp/bwm-review/rev-CHANGEID-XXXXXX)"`
   `mktemp -d` guarantees a fresh, collision-free directory. Use `$RUNDIR/...` for all
   paths below and in the agent prompts; do not write anything to a bare `/tmp/bwm-*`.
4. **Pull the diff and changed files** for the target, saved into the run dir:
   - `jj diff -r "$TARGET" --git > "$RUNDIR/diff.patch"` — the full patch the agents review.
   - `jj diff -r "$TARGET" --stat > "$RUNDIR/diff.stat"` — the file list / shape.
   - `jj log -r "$TARGET" --no-graph -T 'description'` — the change's own description, if any.
   If the diff is empty (e.g. `@` has no changes and no revision was named), stop and say so.
5. **Note the project's rules** so the agents judge against them, not against generic
   taste. Collect paths (don't inline contents into prompts unless small): the root
   `CLAUDE.md`, any `CLAUDE.md` in touched directories, and any `docs/style-*.md` /
   `<crate>/docs/style.md` the repo defines. Pass these paths to the agents.

## Step 1 — Write the implementer's brief

The correctness agent is only as good as what it's told to worry about. You — the Claude
that just implemented this change (or, if reviewing cold, the Claude that just read it) —
know things the diff doesn't show. Distil them into a short brief. **This is mandatory
input to the correctness agent** and useful context for the maintainability agent.

Mine the session and the diff for:

- **Intent** — what this change is *supposed* to do, in one or two sentences.
- **Blast-radius hot-spots** — which changed symbols are widely called, which shared
  types/defaults/error paths moved, which invariants must hold, what you were unsure
  about while writing it. Name files and functions.
- **Known tradeoffs** — anything done deliberately that looks wrong at a glance, and the
  real reason (the maintainability agent will demand this reason exists in a comment).
- **Out of scope** — areas the agents should not chase (pre-existing subsystems the
  change merely calls).

If there is no implementation context in the session (reviewing an arbitrary commit
cold), reconstruct the brief from the diff + commit description and **say so in the
brief** — a reconstructed brief is weaker and the agent should weight its own exploration
more heavily.

Keep it to ~10–20 lines. Write it to `$RUNDIR/brief.md` (the run dir from Step 0) so both
agent prompts can reference the path instead of re-inlining it.

## Step 2 — Spawn the two mandatory agents (parallel, fresh context)

Launch both `Agent` calls (`subagent_type: general-purpose`) in a single message so they
run concurrently. Each gets: the target revision, the diff path (`$RUNDIR/diff.patch`, or
the diff inline if small), the brief path (`$RUNDIR/brief.md`), and the project-rules
paths. Pass the absolute, expanded `$RUNDIR` paths into the prompts — a subagent has its
own shell and won't share your `$RUNDIR` variable. Each must return findings in the exact
schema in Step 3.

Tell **both** agents, verbatim, what is *not* a finding:

- Anything a compiler / linter / formatter / type-checker would catch (CI runs those).
- Pure nitpicks a senior engineer wouldn't raise.
- Pre-existing issues on lines this change didn't touch **and** doesn't make worse —
  *except* where this skill explicitly puts them in scope (the maintainability agent's
  duplication/adjacent-comment checks below).
- Behavior changes that are clearly the intended point of the diff.

### Correctness agent

> You are a correctness reviewer with fresh eyes on a single jj change. Your job is to
> find logic bugs and **far-reaching, undesired effects** — not surface nits. Read the
> brief at `<brief path>` first: it tells you what the implementer thinks matters. Treat
> it as leads, not as boundaries.
>
> Do **not** stop at the diff. For every symbol the change touches, trace its blast
> radius through the real repo: who calls it, what depends on its previous behavior,
> contract/shape/default/error-path changes, callers that won't be recompiled or that
> live in other crates/services, serialized formats, concurrency and ordering, partial
> failure and retries, and any invariant the brief named. Read the surrounding code and
> the callers — that exploration is the point of this agent.
>
> **Mine the history of the touched code for risk.** For the changed files and the
> hottest changed functions, read the VCS history and blame, and let it sharpen where you
> look:
> - jj: `jj log -r 'latest(::@, 20)' <path>` (revisions touching a path), descriptions
>   via `-T 'change_id.shortest() ++ " " ++ description.first_line() ++ "\n"'`, and
>   `jj file annotate <path>` for line-level blame.
> - git fallback (jj repos are git-compatible): `git log --follow -p -- <path>`,
>   `git log -S '<symbol>' -- <path>` (pickaxe), `git blame -L <start>,<end> -- <path>`.
> Treat these as elevated-risk signals: lines/functions that have been fixed or reverted
> repeatedly (bug magnets), commit/PR messages mentioning prior incidents or regressions
> in this code, behavior the current change reintroduces that a past commit deliberately
> removed, and code last touched very recently by someone else (merge/assumption risk).
> When a finding lands on code with this kind of history, say so and cite the change id /
> sha — "this branch was added in <id> to fix X; the new code drops that guard" is far
> stronger than a cold read.
>
> For each issue return: a stable id; a one-line title; the file:line — **a line number
> from the actual source file, which you must open to confirm; never cite the patch's own
> line numbers**; **severity** (blocker / important / minor) = how bad if real;
> **confidence** 0–100 = how sure you are it's real *and* that your suggested fix is
> correct; the concrete failure (what input/sequence triggers it, what goes wrong); and a
> specific suggested fix. Separately list anything you suspect but couldn't confirm, as
> low-confidence leads. If you find nothing real, say so plainly — do not pad.

### Maintainability agent

> You are a maintainability reviewer with fresh eyes on a single jj change, and your
> client is the engineer who has to debug this code three years from now, not the person
> approving the PR today. A PR is reviewed once; bad code is read and mis-read for years.
> Bias every judgment toward that future reader.
>
> Check, in priority order:
>
> 1. **Comment accuracy.** Every comment touched or added by this change must match what
>    the code actually does. Stale, misleading, or aspirational comments are findings —
>    a wrong comment is worse than none.
> 2. **Unexplained intentional wrongness.** Flag *any* comment that admits a deliberately
>    incorrect, suboptimal, hacky, or temporary approach — "HACK", "this is wrong but",
>    "should be X but we do Y", "for now", "temporarily", "TODO: do properly", and the
>    like — **unless** it is accompanied by an explanation of *why there is no other
>    option*. "We do this incorrect thing intentionally" with no justification is always
>    a finding. The remedy is to either (a) supply the real reason no alternative exists,
>    or (b) better, fix the underlying thing so the comment is unnecessary. A specific,
>    always-flag instance of this: a **lint suppression** (`#[allow(...)]`,
>    `#![allow(...)]`, `// clippy::allow`, `# noqa`, `// eslint-disable`, `#[allow(dead_code)]`,
>    etc.) with **no adjacent comment explaining why the lint is wrong here**. Silencing a
>    lint is asserting "the tool is wrong about this code" — that assertion must be
>    justified in a comment, or the suppression is a finding. The remedy is to add the
>    justification or remove the suppression and fix what the lint caught.
> 3. **Duplication.** Code this change duplicates, *and* pre-existing duplication that
>    this change sits next to and could consolidate. Adjacent pre-existing duplication is
>    explicitly in scope.
> 4. **Readability refactors.** Verbose, convoluted, or poorly-named code; misplaced
>    helpers; logic that a future debugger will have to re-derive. Propose the refactor.
>
> Hard rules for your judgment:
> - **Churn is never a reason to leave a problem.** Do not discount a finding because the
>   diff is small, because fixing it "touches unrelated lines," or because it's
>   pre-existing. If the proper fix is larger than this change, recommend it as a
>   *predecessor* commit (clean first, then build on it) or a *follow-up* commit — but
>   recommend it.
> - **Never trade a real improvement away to minimize the diff.** Laziness about cleanup
>   is the exact failure mode you exist to catch.
>
> For each issue return: a stable id; a one-line title; the file:line — **a line number
> from the actual source file, which you must open to confirm; never cite the patch's own
> line numbers**; **severity** (blocker / important / minor); **confidence** 0–100 (real
> issue *and* correct fix); the future cost (concretely, what will go wrong when someone
> reads/changes this later); a specific suggested fix; and **whether the fix belongs in
> this change, a predecessor commit, or a follow-up** (introduced-by-this-change → this
> change; pre-existing → predecessor or follow-up). If you find nothing, say so.

## Step 3 — Triage

Collect both agents' findings into one list with fields:
`id · agent · title · file:line · severity · confidence · failure/cost · suggested fix · placement`.

**Dedupe across agents first.** The same defect frequently surfaces in both agents'
output — often as a confirmed finding from one and a low-confidence lead from the other
(e.g. a panic-in-a-`Result` flagged by maintainability *and* listed as a correctness
lead). Merge any two entries that point at the same file:line / same underlying issue
into **one** finding: keep the higher severity and the higher confidence, union the
reasoning, and note that both agents flagged it (independent agreement is itself signal —
weight it up). Don't report the same problem twice under two ids.

Then split by the auto-fix gate (see Step 4 for what's eligible):

- **Auto-fix set** — high-confidence findings with a clear, low-risk fix.
- **Confirm set** — everything else: lower confidence, judgment-call fixes, or fixes that
  reshape behavior or history enough that the user should sign off.

Before auto-applying anything, **verify each auto-fix candidate yourself**: open the cited
code and confirm the finding is real and the fix is correct. Fresh-context agents
occasionally assert confidently and wrongly; a wrong auto-fix is worse than a reported
one. Demote anything that doesn't survive this check into the confirm set.

## Step 4 — Apply fixes

### Authorship gate — who wrote the change decides whether auto-fix is on the table

**Auto-fix is only permitted when this session implemented the change under review.** That
is the same signal Step 1 uses: if you have real implementation context (you wrote this
code in this conversation), auto-fix is on. If the brief was *reconstructed* — a
pre-existing or user-authored working copy, or any revision you're seeing cold — then the
jj rule from Step 0 governs: **never mutate a change the user didn't initiate without
confirmation.** In that case there is **no auto-fix set**: every finding goes to the
confirm set and you report, recommend placement, and wait. Say explicitly in the report
that nothing was auto-applied because the change wasn't authored this session.

When auto-fix *is* on the table (Claude-authored this session), a finding is auto-fixed
only if **all** hold:

- confidence is high (≈ ≥ 85) and you verified it in Step 3;
- the fix is unambiguous and self-contained — e.g. correcting a wrong/misleading comment,
  supplying a known "why" for an intentional-wrongness comment (only when you actually
  know the why from the session/brief — otherwise it goes to the confirm set), a clear
  local de-duplication, a safe mechanical readability fix;
- you have everything needed to make it correct without guessing.

A high-confidence fix that **changes runtime behavior** may still be auto-applied, but
call it out prominently in the report — the user is most likely to want to eyeball those.

### Where fixes land (decide per finding)

- **Introduced by this change** → fold into the target change. If `TARGET` is `@`, just
  edit the files (the working copy *is* the change). If `TARGET` is another revision,
  `jj edit "$TARGET"`, make the edits, then return with `jj edit @` (jj auto-rebases
  descendants).
- **Pre-existing, and fixing it first makes this change cleaner** → recommend a
  **predecessor**: `jj new --before "$TARGET"`, fix, describe, so the target rebases onto
  the cleaned-up code.
- **Pre-existing, independent** → recommend a **follow-up**: `jj new --after "$TARGET"`
  (or plain `jj new` when `TARGET` is `@`), fix, describe.

For the **auto-fix set** (only non-empty when the authorship gate above is open), apply
using the placement rule above (introduced-by-change fixes default to folding into the
target). For the **confirm set**, present each finding with its recommended placement and
apply only what the user approves — this is the "let me decide per-finding" contract:
recommend, then wait.

When you do fix, **fix it properly**. Do not half-fix to keep the diff small — that just
manufactures the next finding. If a proper fix is too large for this session, say so and
leave it as an explicit recommendation rather than a botched partial.

Run `jj st` after any history mutation to confirm it did what you intended.

## Step 5 — Report

Present, in chat (local only — no PR/GitHub posting):

1. **What was reviewed** — target revision + one line on the diff shape.
2. **Auto-fixed** — each fix, its placement, and a one-line diff summary; flag any that
   changed behavior. Show `jj diff` of what you applied so the user can veto.
3. **Needs your call** — the confirm set, grouped by severity, each with file:line, the
   concrete failure/future-cost, the suggested fix, and recommended placement.
4. **Low-confidence leads** — the correctness agent's unconfirmed suspicions, briefly, so
   nothing is silently dropped.

If both agents came back clean, say that plainly and stop — no manufactured findings.

## Anti-patterns this skill exists to stop

1. **Shallow review.** Reading only the diff and missing the caller three files over that
   the change just broke. The correctness agent must trace blast radius.
2. **Logging instead of fixing.** "Consider refactoring this later." Later never comes;
   fix it now, as a predecessor/follow-up if it doesn't belong in this change.
3. **Churn-phobia.** Leaving a wrong comment or duplicated block because touching it
   "grows the diff." The future debugging cost dwarfs the diff cost.
4. **Half-fixes.** Patching the symptom to keep the change small and seeding the next bug.
5. **Manufactured findings.** Padding a clean change with nits to look thorough. Clean is
   a valid result; report it and stop.
