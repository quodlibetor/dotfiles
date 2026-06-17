---
name: bwm-review
description: Deep error-search review of the current jj working-copy change (or a specified jj revision) using three mandatory fresh-context sub-agents — a correctness agent that traces blast radius for logic bugs and far-reaching effects, a maintainability agent that biases toward the future (comment accuracy, unexplained intentional-wrongness, duplication, readability), and a lightweight reviewability agent that hunts gratuitous churn and tangled concerns so the diff reads cleanly. Auto-fixes high-confidence findings and reports the rest. Use when the user says "/bwm-review", "bwm review", "review my change(s)", "review this commit", "blast-radius review", or asks for a deep correctness + maintainability pass on a change before committing/pushing.
---

# bwm-review

A pre-merge review that takes the long view. A PR is read once; misleading, verbose, or
duplicated code is debugged over and over for years. So this skill is not a polite
nitpick pass — it digs for real defects and real future-cost, and it **fixes what it
finds** rather than logging it for later.

Three sub-agents are **mandatory** and always run, in parallel, each with **fresh context**
(no conversation history) so they judge the code independently:

- **correctness** — blast-radius and logic-bug hunter, *guided* by a brief from the
  implementing Claude about what's likely to matter.
- **maintainability** — biases toward the future: comment accuracy, unexplained
  intentional wrongness, duplication, and readability.
- **reviewability** — lightweight; biases toward the *reviewer reading this diff today*.
  Hunts gratuitous churn (renames, reorderings, moves with no behavioral or readability
  payoff) and tangled concerns (a pure refactor smuggled in with a logic change), so the
  diff is easy to grok. It deliberately pulls *against* the maintainability agent — where
  maintainability says "churn is fine if it improves the code," reviewability says "don't
  change what you didn't need to, and split what you did." Triage reconciles the two
  (Step 3).

You may add task-specific agents on top of these three (e.g. a concurrency agent for a
lock change), but never fewer.

## Step 0 — Preflight

1. **Require jj.** This skill drives Jujutsu. If `.jj/` is absent, stop and tell the user
   it's jj-only. Read the `jujutsu` skill's safety rules before mutating anything — never
   touch a change the user didn't initiate without confirmation.
2. **Resolve the target, and decide single-commit vs. range.** The skill argument is a jj
   revset; default to `@` (the current working copy) when none is given.
   - `TARGET=<arg or @>`
   - Enumerate the commits the revset names, oldest first:
     `jj log -r "$TARGET" --no-graph --reversed -T 'change_id.shortest() ++ " " ++ description.first_line() ++ "\n"'`
   - **One commit** → a single-commit review (the original path). **Two or more** → a
     **stack review**: **N independent single-commit reviews, one per commit, each judged
     as if it were the only change on top of its parent.** The cardinal rule of this skill
     is that *every commit stands on its own* — so a stack review **never squashes the
     commits into one diff**. A squashed/net-of-the-stack view would hide exactly the
     failures the review exists to catch (a commit that only builds, only makes sense, or
     only reads cleanly because a *later* commit rescues it). Run the per-commit reviews in
     parallel, or one at a time, but keep them independent. Later steps branch on the mode.
3. **Make a unique per-review run directory.** Several reviews may run at once — multiple
   agents, multiple repos, even multiple revisions of the same repo — so never use a fixed
   global path that another review would clobber. Create one isolated dir per invocation
   and put every scratch file (diff, brief, agent notes) inside it:
   - `RUNDIR="$(mkdir -p /tmp/bwm-review && mktemp -d /tmp/bwm-review/rev-CHANGEID-XXXXXX)"`
   `mktemp -d` guarantees a fresh, collision-free directory. Use `$RUNDIR/...` for all
   paths below and in the agent prompts; do not write anything to a bare `/tmp/bwm-*`.
4. **Give each commit an accurate tree to read — at *its own* state, not the tip.** The
   agents are told (Steps 2–4) to open the *actual source file* to confirm every
   `file:line` and to trace blast radius through the real repo. For a standalone review of
   commit `C`, that tree must be the snapshot **as of `C`** — the code with `C` applied and
   nothing after it — so callers reflect `C`'s world and a dependency on a *later* commit
   shows up as the breakage it is. The tip's tree, or `@`'s, would hide that. So, per
   commit `C` under review:
   - If `C` **is** `@`, the live working copy already is `C`'s state — review in place, set
     `WS_C="$(pwd)"` (the repo root).
   - Otherwise check `C` out into an ephemeral, read-only workspace:
     `jj workspace add --name "$(basename "$RUNDIR")-$C" -r "$C" "$RUNDIR/ws-$C"`, then
     `WS_C="$RUNDIR/ws-$C"`. This lands a working-copy commit on top of `C`, so `$WS_C` holds
     the tree after `C` is applied — and, being a separate workspace, nothing here moves the
     user's main `@`.
   - The agents for that commit read, grep, and run `jj` **inside `$WS_C`**. Pass the
     absolute `$WS_C` into their prompts as the repo root to explore.
   - A stack review makes one such checkout per commit (created in parallel if you fan the
     commits out concurrently, or one at a time if you'd rather serialize — your call on
     cost). **Tear every workspace down** in Step 5 even if the review aborts:
     `jj workspace forget "<name>"` (from the main repo) and `rm -rf "$RUNDIR/ws-*"`. A
     skipped teardown leaves orphaned workspaces and "stale working copy" warnings in the
     user's repo.
5. **Pull each commit's own diff, saved into the run dir.** One patch per commit under
   review — never a squashed or net-of-stack patch (Step 0.2). For each commit `C`, taken
   with `jj -R "$WS_C"` so it matches the tree its agents read:
   - `jj -R "$WS_C" diff -r "$C" --git > "$RUNDIR/<C>.patch"` — the patch its agents review.
   - `jj -R "$WS_C" diff -r "$C" --stat > "$RUNDIR/<C>.stat"` — the file list / shape.
   - `jj -R "$WS_C" log -r "$C" --no-graph -T 'description'` — that commit's description.
   For a single-commit review, `C` is just `$TARGET`. If a commit's diff is empty (e.g. `@`
   has no changes and no revision was named), stop and say so.
6. **Note the project's rules** so the agents judge against them, not against generic
   taste. Collect paths (don't inline contents into prompts unless small): the root
   `CLAUDE.md`, any `CLAUDE.md` in touched directories, and any `docs/style-*.md` /
   `<crate>/docs/style.md` the repo defines. Pass these paths to the agents.
7. **Establish each commit's standalone build/test baseline — the mechanical proof of the
   cardinal rule.** The agents *argue* whether a commit stands on its own; the toolchain can
   *prove* it. Discover the project's pre-merge check (from `CLAUDE.md` / `mise tasks` /
   Makefile / package scripts — e.g. `mise check`, else at minimum a build) and run it **in
   each commit's `$WS_C`**, against that commit's own tree. Record pass/fail per commit.
   - A **failure is a confirmed blocker finding** for that commit — it does not stand on its
     own (won't build/lint/test with nothing after it applied) — fed straight into triage
     with the error text. No agent confidence needed; the toolchain already proved it.
   - This also *earns* the "ignore anything a compiler/linter/formatter catches" exclusion
     the agents are given (Step 2): the skill now actually runs that check per commit,
     instead of trusting a CI that only ever sees the squashed PR and can stay green even
     when an intermediate commit is broken.
   Burn the build time — a green tip hiding a broken middle commit is exactly the bad-PR
   failure this skill exists to stop.

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

**For a stack review, write one brief per commit — each commit is reviewed alone, so each
gets its own.** The job is to judge whether *this* commit stands on its own, so the brief
states what the commit is supposed to accomplish **by itself, on top of its parent**, and
what it must not lean on. Per commit, give the agents:

- **Standalone intent** — what this commit alone does, framed so "stands on its own" is
  checkable: it should build, behave sensibly, and read cleanly with nothing after it
  applied.
- **Suspected forward dependencies — as leads to *disprove*** — anywhere you suspect the
  commit secretly relies on a later one (calls a symbol a later commit defines, leaves a
  caller broken until a later commit fixes it, reads only given context a later commit
  adds). Flag these as *the thing to catch*, not as exonerating context: if the agent
  confirms the dependency, the commit does **not** stand on its own and that's a blocker.
  Do **not** hand the agent the later commit's content to "complete the picture" — that
  defeats the test.
- **Where to scrutinize** — the one or two commits in the stack you'd lose sleep over.

**Latitude to steer (don't waste it).** You — the supervisor — often know the one thing
this particular review must not miss: a specific invariant, a serialized format that
mustn't drift, a caller in another service, a past incident in this code. You have two
levers, and a custom agent is *not* always the right one:

- **Focus directives** (lightweight, preferred) — a short "pay particular attention to X"
  you fold into the relevant agent's prompt under Step 2. Use this when the concern fits an
  existing agent's remit (a tricky invariant → correctness; a load-bearing comment →
  maintainability). Frame it as **a lead, not a verdict**: "scrutinize the locking in
  `foo()`," never "confirm the locking in `foo()` is wrong." Over-steering defeats the
  fresh-context independence that makes these agents worth running — they exist partly to
  catch what *you* were blind to, so point them, don't pre-decide for them.
- **A task-specific agent** (heavier) — add one only when the concern is a genuinely
  distinct discipline the three don't cover (concurrency, crypto, a migration's data
  safety), per the "you may add agents" note above.

If there is no implementation context in the session (reviewing an arbitrary commit
cold), reconstruct the brief from the diff + commit description and **say so in the
brief** — a reconstructed brief is weaker and the agent should weight its own exploration
more heavily. A reconstructed brief also means you have *less* standing to issue focus
directives: you're guessing at intent too, so keep them to what the diff plainly implies.

Keep it tight: ~10–20 lines for a single commit, plus one line per commit for the stack
map. Write it to `$RUNDIR/brief.md` (the run dir from Step 0) so the agent prompts can
reference the path instead of re-inlining it.

## Step 2 — Spawn the three mandatory agents (parallel, fresh context)

Launch all three `Agent` calls (`subagent_type: general-purpose`) in a single message so
they run concurrently. Each gets:

- **The repo root to explore: `$WS_C`** (from Step 0.4 — the live repo when the commit
  under review is `@`, otherwise the ephemeral workspace checked out at *that commit*). Tell
  every agent to read, grep, and run **all `jj`/`git` commands from inside `$WS_C`**, because
  that is the only tree whose files match the commit under review. This is the fix for
  citing lines against the wrong content — do not let an agent reason about the commit from
  the live working copy, or from the stack's tip, when those differ. For their **read-only**
  history mining (`jj log`, `jj file annotate`, etc.), tell them to use
  `jj --ignore-working-copy ...` so a peek never snapshots the workspace and churns the op
  log mid-review (per the jujutsu skill's `workspaces.md` guidance) — this matters more when
  per-commit workspaces are live in parallel.
- **That commit's own diff** (`$RUNDIR/<C>.patch`, or inline if small) — and *only* that
  commit's. A finding names no commit but this one; there is no squashed or net-of-stack
  patch by design (Step 0.2).
- **The standalone mandate (stack reviews).** Tell the agents plainly: judge this commit as
  if it were the only change on top of its parent. A commit that builds, behaves, or reads
  correctly *only* because a later commit follows it **fails** this review — that is a
  blocker for correctness (won't build / breaks a caller on its own) or a finding for
  reviewability (the diff can't be understood without a commit that isn't here). They must
  not pull in later commits' content to "complete the picture."
- **The brief** for this commit (`$RUNDIR/brief.md` or the per-commit brief) and the
  **project-rules paths** from Step 0.6.
- **Any focus directives** for that agent from Step 1, folded into its prompt as leads.

Pass absolute, expanded paths into the prompts — a subagent has its own shell and won't
share your `$RUNDIR`/`$WS_C` variables. Each must return findings in the exact schema in
Step 3.

Tell **all three** agents, verbatim, what is *not* a finding:

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
> - jj (prefix `--ignore-working-copy` — these are read-only peeks and must not snapshot the
>   workspace): `jj --ignore-working-copy log -r 'latest(::@, 20)' <path>` (revisions
>   touching a path), descriptions via
>   `-T 'change_id.shortest() ++ " " ++ description.first_line() ++ "\n"'`, and
>   `jj --ignore-working-copy file annotate <path>` for line-level blame.
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

### Reviewability agent (lightweight)

> You are a reviewability reviewer with fresh eyes on a single jj change, and your client
> is the reviewer reading **this diff today**. A diff that's twice as big as it needed to
> be — or that braids an incidental refactor through a real logic change — costs every
> reviewer time and hides the bug that matters. Your one job is to make this diff easy to
> grok. Keep it light: you are not a second maintainability pass and you do not hunt for
> bugs. Read the brief at `<brief path>` for intent, then look only for the two things
> below.
>
> 1. **Gratuitous churn.** Changes that alter the source without changing behavior and
>    without a readability payoff — the diff would be strictly easier to review if the
>    line had been left alone. Examples: a variable/function/parameter renamed for no
>    reason the change needs; code moved or reordered with no functional effect;
>    reformatting or rewrapping untouched lines; import reshuffling; whitespace-only edits;
>    switching an idiom (e.g. `if let` vs `match`) where old and new are equally clear. For
>    each, state plainly **why it has no payoff** and that reverting it to the original
>    shrinks the diff with zero behavioral cost. Be careful: a rename that genuinely
>    improves clarity, or a move required by the logic change, is **not** gratuitous — do
>    not flag it. When unsure whether there's a payoff, lower your confidence rather than
>    dropping the lead; triage decides.
> 2. **Tangled concerns.** A single change that mixes a pure refactor (rename, extract,
>    reorder, reformat) with a behavioral/logic change, such that the logic delta is hard
>    to isolate in the diff. The remedy is to **split**: recommend extracting the pure
>    refactor into a *predecessor* commit so the logic change then reads as a small, clean
>    diff on top. Name concretely which hunks/files are the refactor and which are the
>    logic, so the split is actionable.
>
> Hard rules for your judgment:
> - **You optimise for the diff, not the destination.** "This churn makes the code nicer"
>   does **not** justify it to you if the change didn't need it — the payoff has to be in
>   *this* diff's legibility, not in some abstractly tidier end state. Surface the cost and
>   move on; a separate triage step weighs your findings against the other reviews and
>   decides what stands, so your job is to make the cost visible, not to win the argument
>   or pre-concede it.
> - **Never invent work.** If the diff is already tight and single-concern, say so plainly
>   and return nothing. A clean diff is the expected result, not a failure to find things.
> - Don't re-flag formatting a formatter would catch (CI runs it) unless it's churn on
>   lines the change had no reason to touch.
>
> For each issue return: a stable id; a one-line title; the file:line — **a line number
> from the actual source file, which you must open to confirm; never cite the patch's own
> line numbers**; **severity** (blocker / important / minor — gratuitous churn is rarely
> above minor; a badly tangled change is important); **confidence** 0–100 (that the churn
> truly has no payoff, or that the concerns are genuinely separable); the review cost (how
> the diff misleads or slows the reader); a specific suggested fix (**"revert to
> `<original>`"** for churn, or the concrete predecessor-split for tangling); and
> **placement** (gratuitous churn -> revert within this change; tangle -> recommend a
> predecessor split, never auto-applied). If you find nothing, say so.

## Step 3 — Triage

Collect all three agents' findings into one list with fields:
`id · agent · title · file:line · severity · confidence · failure/cost · suggested fix · placement`.
For a stack review, add a **commit** field (which change id the finding lands in) — it
drives where the fix goes in Step 4 and lets you spot when one defect spans commits.

**Dedupe across agents first.** The same defect frequently surfaces in more than one
agent's output — often as a confirmed finding from one and a low-confidence lead from
another (e.g. a panic-in-a-`Result` flagged by maintainability *and* listed as a
correctness lead). Merge any two entries that point at the same file:line / same
underlying issue into **one** finding: keep the higher severity and the higher confidence,
union the reasoning, and note that both flagged it (independent agreement is itself signal
— weight it up). Don't report the same problem twice under two ids.

**Then resolve reviewability-vs-maintainability conflicts.** These two agents are designed
to disagree, and they will land on the same lines. Resolve each clash by this rule:

- **Reviewability wins only when the churn is *purely cosmetic*** — the lines it wants
  reverted carry no correctness or maintainability finding and have no behavioral effect.
  A gratuitous rename/reorder with nothing real attached → revert it; drop the
  maintainability "it's a bit nicer this way" view, because "a bit nicer" doesn't pay for
  diff cost on a change that didn't need it.
- **Correctness or maintainability wins when there's a *real* finding on those lines** —
  if reviewability wants to revert a change that correctness flagged as a needed fix, or
  that maintainability flagged as fixing a genuine defect (wrong comment, real
  duplication, a readability problem that actually bites a future reader), the real
  finding stands and reviewability's revert is dropped. Note the tension in the report so
  the user sees it was considered.
- **Tangled-concern (split) findings never conflict** — they don't ask to revert anything,
  only to reorganize history. Carry them through to the confirm set regardless.

When you genuinely can't tell whether churn has a payoff, treat it as *not* purely
cosmetic (leave it; don't auto-revert) and surface it as a low-confidence reviewability
lead rather than acting on it.

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
  local de-duplication, a safe mechanical readability fix, or **reverting purely cosmetic
  gratuitous churn** to its original form (a reviewability finding that survived the Step 3
  conflict rule — i.e. no real finding sits on those lines);
- you have everything needed to make it correct without guessing.

**Commit-splitting is never auto-applied.** Reviewability's tangled-concern findings —
"extract this refactor into a predecessor so the logic reads clean" — reshape history and
are judgment calls about how to organize the change; they always go to the confirm set
with a recommended split, and you apply only what the user approves. Reverting cosmetic
churn is fine to auto-apply (it just makes lines you wrote match what was there before);
re-slicing the change into multiple commits is not.

A high-confidence fix that **changes runtime behavior** may still be auto-applied, but
call it out prominently in the report — the user is most likely to want to eyeball those.

### Where fixes land (decide per finding)

`C` is the commit the finding lands in (the one being reviewed). Run history mutations in
that commit's workspace `$WS_C` from Step 0.4 — `jj -R "$WS_C" ...` — so they never disturb
the user's main `@`. Editing `C` auto-rebases its descendants, including the user's own
commits stacked above it; their main working copy simply shows "stale" and refreshes on its
next `jj` command. That propagation is the point — the fix flows into `C` and everything on
top of it.

**Parallel fold-ins churn the stack — expect it, don't panic.** The reviews fan out safely
(read-only workspaces), but *applying* fold-ins is different: each edit to a commit
rewrites every commit above it in the stack, so the other per-commit workspaces — sitting
on the now-rewritten commits — go **stale**. When you `jj workspace update-stale` one to
continue, a later snapshot can make it look like a workspace's content vanished. **It did
not.** jj never deletes data; `update-stale` snapshots the stale copy *before* resetting,
and that snapshot lands behind a `reconcile divergent operations` op where it's easy to
miss. Do **not** reach for `jj undo` / `jj op restore`. Follow the jujutsu skill's
*"`jj workspace update-stale` ate my uncommitted changes"* recovery (under *Recovering data
without `jj op restore`*): find the `snapshot working copy` op just before the reconcile and
`jj restore --from <commit-id>` it forward. If you'd rather sidestep the churn entirely,
apply fold-ins serially from the top of the stack downward; but the review fan-out itself
should always be parallel.

- **Introduced by `C`** → fold into `C`. If `C` is `@` (reviewed in place), just edit the
  files — the working copy *is* the commit. Otherwise `jj -R "$WS_C" edit "$C"`, make the
  edits in `$WS_C`; jj auto-rebases the descendants.
- **Pre-existing, and fixing it first makes `C` cleaner** → recommend a **predecessor**:
  `jj -R "$WS_C" new --before "$C"`, fix, describe, so `C` rebases onto the cleaned-up code.
- **Pre-existing, independent** → recommend a **follow-up**: `jj -R "$WS_C" new --after "$C"`,
  fix, describe.
- **Tangled concern, split recommended** (reviewability) → this is the in-scope shape of
  "stands on its own": a commit that braids a pure refactor through a logic change should be
  split so each half stands alone. Recommend peeling the refactor out *ahead* of the logic
  change. The mechanic is `jj -R "$WS_C" split` on `C` — interactively select the
  refactor-only hunks into the first (predecessor) commit, leaving the logic change in the
  second; describe both. This is **always confirm-only**, so present it as a concrete
  recommendation — name the hunks that go into the refactor commit — and run it only with
  the user's go-ahead.

For the **auto-fix set** (only non-empty when the authorship gate above is open), apply
using the placement rule above (introduced-by-change fixes default to folding into the
target). For the **confirm set**, present each finding with its recommended placement and
apply only what the user approves — this is the "let me decide per-finding" contract:
recommend, then wait.

When you do fix, **fix it properly**. Do not half-fix to keep the diff small — that just
manufactures the next finding. If a proper fix is too large for this session, say so and
leave it as an explicit recommendation rather than a botched partial.

**Re-verify after fixing.** An auto-fix is not "applied" until the commit it landed in
still passes its Step 0.7 baseline check in `$WS_C` — re-run that check after folding a fix
in, especially a behavior-changing one. If it now fails, the fix was wrong or incomplete:
back it out (restore the file to its pre-fix state) and demote the finding to the confirm
set with the breakage noted — a wrong auto-fix that breaks the build is worse than a
reported one. Because folding into `C` rebases its descendants, also re-run the baseline for
the commits above `C`: a fix in `C` can break a later commit's standalone build, and that
regression is itself a blocker.

Run `jj st` after any history mutation to confirm it did what you intended.

## Step 5 — Report and tear down

For a stack review, **group the report by commit** — one section per commit, in stack
order — because each was reviewed as a standalone change and the user fixes them
per-commit. Lead each commit's section with whether it stands on its own. Within a commit,
present (local only — no PR/GitHub posting):

1. **What was reviewed** — the commit (change id + description) and one line on its diff
   shape; for the run as a whole, the target revset and how many commits it covered.
2. **Auto-fixed** — each fix, its placement, and a one-line diff summary; flag any that
   changed behavior. Show `jj diff` of what you applied so the user can veto.
3. **Needs your call** — the confirm set, grouped by severity, each with file:line, the
   concrete failure/future-cost, the suggested fix, and recommended placement.
4. **Diff hygiene** — reviewability's tangled-concern split recommendations (always
   confirm-only), each naming which hunks form the refactor predecessor and which are the
   logic change, plus any cosmetic-churn revert that lost to a real finding in Step 3 (so
   the user sees the tension was weighed, not missed).
5. **Low-confidence leads** — the correctness agent's unconfirmed suspicions and
   reviewability's uncertain churn calls, briefly, so nothing is silently dropped.

**Then, stack-wide: systemic patterns.** After the per-commit sections, call out any finding
that *recurs across commits* — the same defect or smell copied into several (e.g. the same
unchecked unwrap in C2, C5, C7). Do **not** merge these into one (each commit still stands
on its own and is fixed in place), but surface the pattern once so the user fixes the
*pattern*, not N look-alikes, and sees it's systemic rather than incidental. Per-commit
triage can't see this — it's only visible once every commit's findings sit side by side.

If all agents came back clean for a commit, say that plainly for it — no manufactured
findings.

**Then tear down every ephemeral workspace from Step 0.4**, even if the review aborted or
errored: for each created workspace, `jj workspace forget "<name>"` from the main repo and
`rm -rf "$RUNDIR/ws-*"`. Confirm with `jj workspace list` that only the user's own
workspaces remain, and `jj st` in the main repo to surface (and resolve) any leftover
staleness. A skipped teardown leaves orphaned workspaces and stale-copy warnings the user
will trip over later.

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
6. **Gratuitous churn.** Renaming, reordering, or reformatting lines the change had no
   reason to touch, so the reviewer wades through noise to find the real delta. The
   reviewability agent reverts the purely cosmetic noise and recommends splitting a refactor
   out of a logic change — the deliberate counterweight to anti-pattern #3, reconciled in
   Step 3 (real findings beat diff size; pure cosmetics lose to it).
