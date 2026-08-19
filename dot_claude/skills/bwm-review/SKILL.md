---
name: bwm-review
description: Deep error-search review of the current jj working-copy change (or a specified jj revision) using fresh-context sub-agents sized to the diff — a correctness agent that traces blast radius for logic bugs and far-reaching effects, a maintainability agent that biases toward the future (comment accuracy, unexplained intentional-wrongness, duplication, readability), and a lightweight reviewability agent that hunts gratuitous churn and tangled concerns so the diff reads cleanly. Auto-fixes high-confidence findings, then re-reviews the fixed change recursively (up to 3 re-review rounds) until it comes back clean, escalating to a structural agent when the rounds churn instead of converging. Use when the user says "/bwm-review", "bwm review", "review my change(s)", "review this commit", "blast-radius review", or asks for a deep correctness + maintainability pass on a change before committing/pushing.
---

# bwm-review

A pre-merge review that takes the long view. A PR is read once; misleading, verbose, or
duplicated code is debugged over and over for years. So this skill is not a polite
nitpick pass — it digs for real defects and real future-cost, and it **fixes what it
finds** rather than logging it for later.

Three sub-agents carry the review. They run in parallel, each with **fresh context**
(no conversation history) so they judge the code independently:

- **correctness** — blast-radius and logic-bug hunter, *guided* by a brief from the
  implementing Claude about what's likely to matter.
- **maintainability** — biases toward the future: comment accuracy, comment scope and
  placement, unexplained intentional wrongness, duplication, and readability.
- **reviewability** — lightweight; biases toward the *reviewer reading this diff today*.
  Hunts gratuitous churn (renames, reorderings, moves with no behavioral or readability
  payoff) and tangled concerns (a pure refactor smuggled in with a logic change), so the
  diff is easy to grok. It deliberately pulls *against* the maintainability agent — where
  maintainability says "churn is fine if it improves the code," reviewability says "don't
  change what you didn't need to, and split what you did." Triage reconciles the two
  (Step 3).

**The roster is sized, not fixed.** All three running is the default for a substantial
change on its first pass, and that default is deliberately hard to escape — but a review
that spends a 2700-line feature's budget on a 20-line comment fix is wasting the user's
money, and an agent whose mandate the diff makes *empty* finds nothing however strong its
model. So before anything is spawned, **Step 0.8 sizes the roster, picks each agent's model,
and sets a spawn ceiling** from the diff's own shape; **Step 5 then decays the roster** as
the unreviewed surface shrinks round over round. Two rules keep sizing honest: you may
always add task-specific agents on top (e.g. a concurrency agent for a lock change), and you
may always tier **up** when the change is nastier than its line count suggests. Sizing down
is a decision the user is entitled to see, so Step 7 reports it.

**Models are capped, not chosen freely.** Because the roster runs *per commit per round*, the
model choice multiplies. Every agent here runs at **Opus 4.8 or below**; the sole exception is
the Step 6 structural agent, which is spawned at most once per invocation and gets the newest
Opus. Step 0.8 spells out how that cap is enforced.

A fourth agent is **conditional**, not spawned up front:

- **structural** — spawned only when the review/fix loop churns instead of converging
  (Step 6). Its target is not the code's behavior but its *shape*: the type-system misuse,
  module boundary, or missing test that keeps *manufacturing* findings round after round.

**One pass is not a review.** Applying a fix is itself a change to the code, and an unreviewed
fix is exactly the kind of thing this skill exists to catch — fixes introduce bugs, half-solve
the problem, or drag a second concern into the diff. So after any round of non-trivial fixes,
the review **re-runs from scratch on the fixed change** and keeps doing so until it comes back
clean, up to 3 re-review rounds (Step 5). If those rounds churn — the same defect keeps
resurfacing, or each fix spawns the next finding — that is evidence the problem is
*structural*, not a sequence of local mistakes, and the structural agent is spawned to name it
mechanically (Step 6).

## Step 0 — Preflight

1. **Require jj.** This skill drives Jujutsu. If `.jj/` is absent, stop and tell the user
   it's jj-only. Read the `jujutsu` skill's safety rules before mutating anything — never
   touch a change the user didn't initiate without confirmation.
   **Require the pinned worker agent, too.** Every agent here is spawned as
   `subagent_type: bwm-review-worker`, whose definition pins Opus 4.8 (Step 0.8). Confirm
   `~/.claude/agents/bwm-review-worker.md` exists and has `model: claude-opus-4-8` in its
   frontmatter. If it is missing, stop and tell the user to restore it — the agent registry is
   read at session start, so a freshly created definition needs a session restart before it
   resolves. **Do not substitute `general-purpose`**: it would run the entire roster, every
   commit and every round, on the newest Opus, which is the exact cost this pin exists to
   avoid.
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
   **Reviews come in rounds** (Step 5 re-reviews the change after fixes), so scope
   per-round artifacts — patches, agent findings, fix logs, baseline results — under a
   round dir, and keep every round's for the convergence check and the final report:
   - `ROUND=1` and `ROUNDDIR="$RUNDIR/round-$ROUND"`, `mkdir -p "$ROUNDDIR"`.
   Cross-round state (the brief, the finding ledger) lives at `$RUNDIR/` itself.
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
     cost). The workspaces must **survive every review round** (Step 5 re-reviews in the same
     `$WS_C`), so tear them down only at the very end — **Step 7** — even if the review aborts:
     `jj workspace forget "<name>"` (from the main repo) and `rm -rf "$RUNDIR/ws-*"`. A
     skipped teardown leaves orphaned workspaces and "stale working copy" warnings in the
     user's repo.
5. **Pull each commit's own diff, saved into the round dir.** One patch per commit under
   review — never a squashed or net-of-stack patch (Step 0.2). For each commit `C`, taken
   with `jj -R "$WS_C"` so it matches the tree its agents read:
   - `jj -R "$WS_C" diff -r "$C" --git > "$ROUNDDIR/<C>.patch"` — the patch its agents review.
   - `jj -R "$WS_C" diff -r "$C" --stat > "$ROUNDDIR/<C>.stat"` — the file list / shape.
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
   each commit's `$WS_C`**, against that commit's own tree. Record pass/fail per commit, and
   record the command itself in `$RUNDIR/check.md`: Step 4 and every re-review round in
   Step 5 must re-run the *same* command, and re-deriving it per round invites drift.
   - A **failure is a confirmed blocker finding** for that commit — it does not stand on its
     own (won't build/lint/test with nothing after it applied) — fed straight into triage
     with the error text. No agent confidence needed; the toolchain already proved it.
   - This also *earns* the "ignore anything a compiler/linter/formatter catches" exclusion
     the agents are given (Step 2): the skill now actually runs that check per commit,
     instead of trusting a CI that only ever sees the squashed PR and can stay green even
     when an intermediate commit is broken.
   Burn the build time — a green tip hiding a broken middle commit is exactly the bad-PR
   failure this skill exists to stop.
8. **Size the review: roster, models, budget.** Everything this skill spawns is spawned *per
   commit per round*, so the roster is the one real cost lever it has. Size it here, from
   facts the artifacts above already give you — this step must add no exploration of its own.

   **Measure the diff.** From `$ROUNDDIR/<C>.stat` take insertions, deletions, and files
   changed. From `jj -R "$WS_C" diff -r "$C" --summary` take the per-file change letters
   (`A`dded / `M`odified / `D`eleted / `R`enamed). One number picks the tier; the letters
   decide the reviewability gate.

   **Pick the tier** on total = insertions + deletions:

   | tier | when | round-1 roster |
   |---|---|---|
   | **XS** | ≤ 50 lines, **or** the diff touches only comments, docs, or config — no executable code | correctness only |
   | **S** | ≤ 300 lines | correctness + maintainability |
   | **M** | ≤ 1500 lines | all three |
   | **L** | > 1500 lines, **or** > 15 files | all three, plus a per-agent turn budget (below) |

   **When a diff matches more than one row, take the highest tier it matches** — a 100-line
   change spread across 20 files is L, not S. Line count measures how much there is to read;
   file count measures how far the blast radius spreads, and the second is the one that makes
   a review hard. Same rule for the roster: the widest matching row wins.

   A tier is a floor, never a verdict. **Tier up one level whenever the change is nastier
   than its size** — concurrency, locking, migrations, auth, money, data destruction,
   serialized formats, a shared type with many callers, anything the brief flags as
   load-bearing, or anything the Step 0.7 baseline just failed on. Never tier *down* off those
   signals, and never tier down because the change "looks simple": XS exists for diffs whose
   *content* is trivially bounded, not for diffs you hope are.

   **Gate the reviewability agent on the diff having something for it to find.** Its whole
   mandate is churn (renames, reorderings, moves, reformatting) and tangled concerns — all of
   which are edits to lines the change *didn't need to touch*. A diff whose `--summary` is
   **all `A` with zero deletions is insert-only: there are no untouched lines it could have
   needlessly touched and nothing to revert to**, so churn there is not merely absent, it is
   unrepresentable. Skip the agent in that case and say so in the report. Spawn it whenever
   the diff has any deletions, any `M`odified file, or any `R`ename — that is the whole test.

   **Assign a model per agent.** The three mandates are not equally hard, and paying top-tier
   rates for the mechanical one buys nothing. **Opus 4.8 is the cap for every agent this
   skill spawns, with exactly one exception: the Step 6 structural agent.** The cap is not
   a quality judgment — a review runs its whole roster per commit per round, so it is the one
   place in this workflow where the newest Opus's token cost multiplies out of proportion to
   what it buys. The structural agent is exempt because it is spawned at most once, only after
   competent local work has already failed, and it is the single highest-leverage call here.

   | agent | model | how to spawn | why |
   |---|---|---|---|
   | correctness | Opus 4.8 (the cap) | `subagent_type: bwm-review-worker`, **no `model`** | tracing blast radius across callers, history, and error paths is where model strength converts into a caught blocker. This is the agent whose miss ships broken code, so it sits at the cap and never below it. |
   | maintainability | Opus 4.8 on round 1; Sonnet on re-reviews | round 1: no `model`; re-reviews: `model: sonnet` | *finding* a wrong comment or real duplication is a judgment call. *Checking* whether last round's fix says what its code does is a much easier task on a much smaller surface. |
   | reviewability | Sonnet, always | `model: sonnet` | its checks are mechanical pattern-matching over the patch: is this hunk a rename, a reorder, a second concern. It is also the lowest-yield agent, so it is the wrong place to spend. |
   | fix agents (Step 4) | Opus 4.8 (the cap) | no `model` | a fix edits real code, and a bad fix is a defect the review itself introduced. |
   | structural (Step 6) | **newest Opus — the one exception to the cap** | `model: opus` | rare, one spawn per invocation, and the highest-leverage single agent here. |

   **The 4.8 cap is enforced by the agent definition, not by the `Agent` call.** The
   `model` parameter only accepts the aliases `opus`/`sonnet`/`haiku`/`fable`, and `opus`
   resolves to the *newest* Opus — so a version cannot be pinned from the call site. The
   `bwm-review-worker` agent (`~/.claude/agents/bwm-review-worker.md`) pins
   `model: claude-opus-4-8` in its frontmatter; **omitting `model` on the `Agent` call is what
   holds the cap**, and passing `model: opus` is what deliberately breaks it for the
   structural agent. If a spawn fails with *agent type not found*, the definition file is
   missing or the session predates it — say so and stop rather than falling back to
   `general-purpose`, which would silently run the whole roster at newest-Opus rates.

   **Never tier a model down where the cost of a miss is high** — anything you tiered up, and
   anything touching money, auth, or data destruction. Those stay at the cap (no `model`);
   the saving from Sonnet is real but small, and a missed blocker is not. Tiering *up* past
   the cap is not one of the moves available to you: the only agent that may exceed 4.8 is
   the structural one, and it is reached by escalation (Step 6), not by sizing.

   **Set a spawn ceiling.** Record in `$RUNDIR/budget.md`: the tier, the round-1 roster, the
   per-agent models, and a **hard ceiling on total agent spawns for the entire invocation** —
   every commit, every round, including fix agents and Step 6. Default it to
   `8 × <commits under review>` for XS/S and `12 ×` for M/L. Those numbers are the worst
   *legitimate* case, not a guess: a single M/L commit that runs the full four rounds spends
   3 + 2 + 1 + 1 reviewers under the decay schedule, plus one structural agent, plus up to
   one fix agent per round — twelve. Size the ceiling to bound *runaway*, never to cut off a
   review that is still converging, and re-derive it if you change the decay schedule. When a round would exceed the
   ceiling, **stop**: report what you have and say plainly that the ceiling ended the loop. An
   unbounded review is not a more thorough review, it is unbilled work the user never agreed
   to — and a run that stopped early must never be reported as one that came back clean.

   **On tier L, budget turns per agent too — but budget the *waste*, not the work.** An
   agent's cost is turns × context, and an agent on a large diff will spend tool calls
   re-deriving context it was already handed. Add to its prompt: *"Aim to finish within ~60
   tool calls on a first pass, ~40 when reviewing a fix delta. Do not re-derive what the
   brief already establishes, do not re-read a file you have already read in this session,
   and do not re-confirm a fact you have already confirmed. This is a budget on redundant
   exploration and nothing else: never stop while you are still tracing a live lead, and
   never skip opening the real file to confirm a `file:line` you intend to cite — if the
   change genuinely needs more calls than this, spend them and say why."* A soft aim that the
   agent may exceed with a reason is the point; a hard cap that truncates a blast-radius
   trace halfway buys a few dollars and hands back the missed blocker (anti-pattern #12).

   **Stack reviews: tier every commit on its own diff.** A stack's individual commits are
   usually small even when the stack is large, so per-commit tiering is most of the saving
   available here — do not tier the whole stack off its total. Sum the per-commit rosters
   against the single invocation-wide ceiling, and if they would blow it, review the commits
   in stack order and **tell the user which commits you did not reach**, rather than silently
   down-tiering all of them into a review too thin to catch anything.

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

## Step 2 — Spawn the round's agents (parallel, fresh context)

Launch this round's `Agent` calls (`subagent_type: bwm-review-worker`) in a single message so
they run concurrently. **Which agents run, and on which model, is not fixed**: the tier in
Step 0.8 sets it for round 1 and the decay schedule in Step 5 sets it for every round after.
Follow the *how to spawn* column of the Step 0.8 table literally — **omit `model` for an agent
at the Opus 4.8 cap and pass `model: sonnet` for a tiered-down one**; never pass
`model: opus` here, which would put a per-round agent above the cap. Count every spawn
against the spawn ceiling in `$RUNDIR/budget.md`. **Step 5 re-enters this step for each round**
with a fresh set of agents — never reuse a round's agents or their conclusions. Each gets:

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
- **That commit's own diff** (`$ROUNDDIR/<C>.patch`, or inline if small) — and *only* that
  commit's, freshly re-derived for this round so it includes any fixes already folded in. A
  finding names no commit but this one; there is no squashed or net-of-stack patch by design
  (Step 0.2).
- **The standalone mandate (stack reviews).** Tell the agents plainly: judge this commit as
  if it were the only change on top of its parent. A commit that builds, behaves, or reads
  correctly *only* because a later commit follows it **fails** this review — that is a
  blocker for correctness (won't build / breaks a caller on its own) or a finding for
  reviewability (the diff can't be understood without a commit that isn't here). They must
  not pull in later commits' content to "complete the picture."
- **The brief** for this commit (`$RUNDIR/brief.md` or the per-commit brief) and the
  **project-rules paths** from Step 0.6.
- **Any focus directives** for that agent from Step 1, folded into its prompt as leads.
- **On re-review rounds (round ≥ 2) only: the previous round's fix log**
  (`$RUNDIR/round-<N-1>/fixes.md`) — which findings were fixed and what edits were made —
  framed as **claims to test, not settled work**. Tell the agent plainly: these fixes are
  freshly written, unreviewed code, authored by the same person who wrote the defect, so
  check each one for whether it actually resolves what it claims, resolves it *completely*,
  and introduced nothing new. Give it the fixes and **nothing else** from prior rounds — not
  the earlier findings, not the earlier agents' reasoning, not what triage decided. It sees
  what changed; it does not see what was concluded. Anchoring it on the last round's verdicts
  destroys the independence that makes a re-review worth running, and suppressing
  already-settled findings is triage's job (Step 3's ledger), not the agent's.
- **On re-review rounds (round ≥ 2) only: the fix delta, as the round's primary target.**
  Along with the fix log, give the agent the diff of what the last round actually changed —
  `diff -u "$RUNDIR/round-<N-1>/<C>.patch" "$ROUNDDIR/<C>.patch"` — and tell it plainly:
  **the fixes are what this round is reviewing; the rest of the commit is context you may
  read but must not re-audit line by line.** Without this, a re-review re-derives the entire
  change from scratch and costs what round 1 cost — and by round 3 it spends that on comment
  wording instead of defects, because the fixes are the only genuinely unreviewed lines left.
  Scope the **starting point only, never the tracing**: the agent must still follow blast
  radius *outward* from the fixed lines as far as it goes, because a fix that breaks a distant
  caller is precisely what this round exists to catch.
- **On re-review rounds (round ≥ 2) only: the ledger's settled-*scope* list, as a boundary
  and not a verdict.** Pass the ledger's "cleared by reviewers" and "out of scope / separate
  tickets" entries with exactly this framing: *"these areas were mechanically verified in an
  earlier round — do not spend budget re-verifying them unless this round's fix delta reaches
  into them."* This is the only thing besides the fixes an agent may see from prior rounds,
  and the distinction is load-bearing: it conveys **what was already covered**, never **what
  was decided** about an open finding, so a real defect in cleared code stays findable the
  moment a fix touches it. Be honest about the trade — strict per-round independence is
  *why* rounds 2 and 3 cost what round 1 cost, and this is the concession that buys most of
  that back while keeping the agent's judgment its own.

Pass absolute, expanded paths into the prompts — a subagent has its own shell and won't
share your `$RUNDIR`/`$WS_C` variables. Each must return findings in the exact schema in
Step 3.

Tell **every agent this round**, verbatim, what is *not* a finding:

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
> 2. **Comment scope, placement, and length.** A comment describes the behavior of the code
>    it sits on. It is not the place for the *callers* ("the loader calls this after…"), for
>    *why the code exists* ("added so the eval job can…"), or for *history* ("was X, now Y",
>    "previously", "before this PR") — that content belongs in the commit message, and in the
>    source it goes stale silently. Each of these is a finding:
>    - **A doc comment on an exported/public item is written for that item's *users*** and
>      shows up in their editor. It says what the thing does, plus any invariant the caller
>      must uphold or can observe. Invariants are rare, so document one only when it would
>      surprise a competent caller, never to restate the signature. A caller-observable
>      property *is* such an invariant and stays on the signature — not thread-safe, panics
>      on empty, mutates its argument, must be called with the lock held, quadratic in an
>      argument that looks small. The caller never reads the body, so this is the only place
>      they can learn it. Judge "surprising" against a method of this shape in this language:
>      that it allocates, or blocks on I/O it is obviously named for, is not a finding and
>      not worth a line — documenting the ordinary cost of ordinary code is the noise this
>      criterion exists to remove.
>    - **A surprising *internal* detail belongs on the surprising line, not on the
>      signature.** A method doc explaining a buffering, ordering, or locking trick that the
>      caller cannot observe is misplaced; the remedy is to move it inline onto the code that
>      does the surprising thing, where the person changing that code will actually see it.
>      The test is whether the caller's own code can tell: if it can, it is an invariant and
>      belongs above; if only the maintainer cares, it goes inline.
>    - **A conceptual model belongs on one type or package doc**, not restated across the
>      methods that use it — restated models drift apart. If a method needs the model,
>      it should point at that single document rather than paraphrase it.
>    - **Length is capped by the explanation.** "Accumulate into a buffer before serializing
>      so that we break on the deserialized size" is a complete comment; five paragraphs
>      weighing the alternatives is a finding. Cut it to the reason.
>
>    **Deletion is the default remedy here, and this criterion is deliberately subtractive.**
>    Machine-written code arrives over-commented; a comment that has to be argued for is one
>    that should not exist. The one exception: when a comment carries something a reader
>    cannot recover from the code — an invariant, an approach that was tried and failed, an
>    external constraint like a wire format — rewrite it in place rather than delete it, even
>    if it is currently phrased as history or as caller narration.
> 3. **Unexplained intentional wrongness.** Flag *any* comment that admits a deliberately
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
> 4. **Duplication.** Code this change duplicates, *and* pre-existing duplication that
>    this change sits next to and could consolidate. Adjacent pre-existing duplication is
>    explicitly in scope.
> 5. **Readability refactors.** Verbose, convoluted, or poorly-named code; misplaced
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

Collect every agent this round ran into one list with fields:
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
to disagree, and they will land on the same lines. This whole reconciliation is a no-op in
any round where one of them didn't run (Step 0.8's insert-only gate, or Step 5's decay) —
there is no clash to resolve, and that is not a gap to fill by arguing one agent's findings
against a case the other never made. When both ran, resolve each clash by this rule:

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

### Reconcile against the cross-round ledger

`$RUNDIR/ledger.md` is the one place a finding's *history* lives, and it is what makes the
Step 5 loop terminate instead of hang. Maintain one row per **underlying issue** — keyed by
file + symbol + a one-line statement of the problem, **not** by agent-assigned id, since ids
are regenerated every round by fresh agents: `key · commit · first seen (round) · rounds seen
· disposition (auto-fixed / user-approved / user-declined / reported-only) · status (resolved
/ recurred / fix-induced / open)`. Create it in round 1; update it every round. For a stack
review, keep the rows scoped per commit.

On round 1 every finding is simply new. From round 2 on, classify each finding against the
ledger before triaging it:

- **Declined by the user in an earlier round** → do **not** re-raise it as an action, and do
  not auto-fix it. The user has ruled; independent re-discovery isn't new information about
  whether they want it fixed. Record the re-sighting and mention it once, as a single line in
  the report. A loop that keeps re-proposing rejected fixes is a hang, not a review.
- **Fixed in an earlier round and back again** → mark it `recurred`, and weight it *up*: a
  defect that survived a fix attempt is stronger evidence of something real than a first
  sighting. Do not re-apply the same fix — a fix that didn't stick was aimed at the wrong
  thing, so either fix the actual cause or move it to the confirm set. Recurrence is the
  primary churn signal Step 5 counts.
- **New, but landing on lines a previous round's fix wrote** → mark it `fix-induced`. Triage
  it like any other finding, but never drop the tag: it is the other churn signal Step 5
  counts, and a fix that spawns the next finding is the clearest evidence that the code's
  shape — not the author's care — is the problem.
- **New elsewhere** → ordinary triage.

### Split by the auto-fix gate

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
  deleting or relocating an out-of-scope one (caller narration, rationale-for-existence,
  history, a surprising detail parked on the signature instead of on the code),
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

### Log what you applied

Write `$ROUNDDIR/fixes.md` before leaving this step — it is the input the next round's agents
get (Step 2) and the data the churn check needs (Step 5), so it must be concrete, not a
summary. Per fix: the ledger key of the finding, its placement (folded into `C` /
predecessor / follow-up / split), **the files and line ranges actually written** (needed to
detect fix-induced findings), a one-line statement of the edit, whether it changed runtime
behavior, and the post-fix baseline result. Also record fixes the *user* approved from the
confirm set — for the purposes of the loop, a user-approved fix is a fix. A fix that was
**backed out** after failing its baseline check is *not* applied: log it as attempted and
reverted (that history matters to the structural agent) but it does not count toward
triggering a re-review, because the code it would have reviewed no longer exists. If nothing
was applied this round, write that; an empty fix log is what ends the loop.

## Step 5 — Re-review the fixed change (recursive, up to 3 rounds)

A fix is unreviewed code. The whole premise of this skill is that unreviewed code gets
merged with defects in it, and nothing about a fix being *called* a fix exempts it — fixes
routinely mis-target the problem, solve half of it, break a caller the original code didn't
touch, or drag a second concern into a diff that was clean. So the review loops.

**Loop condition.** After Step 4, if this round applied **any non-trivial fix**, go back to
Step 0.5 and run another round against the *now-fixed* commit: re-derive the patch, re-run
the baseline, spawn a **new** set of fresh-context agents per the decay schedule below
(Step 2), triage against the ledger (Step 3), apply (Step 4). Increment `ROUND` and make a
new `$ROUNDDIR` first.

**Roster decay across rounds.** Each round has less unreviewed code in front of it than the
one before — by round 3 the only genuinely unreviewed lines are the previous round's fixes —
so the roster shrinks with the surface. Starting from the round-1 roster the tier gave you
(Step 0.8), drop one mandate per round:

| round | roster | why this is safe to drop |
|---|---|---|
| 1 | the tier's full roster | the entire change is unreviewed |
| 2 | drop reviewability | it has already ruled on the diff's *shape*, and a fix round that only edits lines this change already touched cannot introduce churn against untouched code. **Keep it** when a fix **moved, renamed, reverted, or reformatted** code, or the user approved a split — those are the cases that genuinely change diff shape. |
| 3+ | correctness only | what remains to catch is a fix that is wrong or that breaks a caller. Comment drift inside a fresh fix is real but minor, and at this depth a maintainability pass mostly re-litigates the fix log rather than the code. |

**Tier back up mid-loop, never further down**, when a round surfaces a **blocker** or marks
anything `recurred` or `fix-induced`: restore the full roster for the next round, and restore
maintainability to the 4.8 cap (drop the `model: sonnet`) rather than leaving it tiered
down. Convergence is the thing being measured, a round that found a blocker has not converged,
and cost is the wrong quantity to optimize at that moment. Tiering back up stops at the
cap — a churning loop is what Step 6 is for, not a per-round agent on the newest Opus.

**Non-trivial** — any of these makes the round non-trivial and requires a re-review:

- any edit to executable code: control flow, conditions, types, signatures, error handling,
  defaults, concurrency, resource lifetimes;
- a de-duplication, an extracted helper, or any readability refactor that moved code;
- added or changed tests;
- anything flagged as behavior-changing;
- a history reshape the user approved (a split, a predecessor, a follow-up);
- **in aggregate**: more than about three individually-trivial fixes in one round. Trivial
  edits interact, and a wide sweep of them is its own risk. **But scale the response to the
  sweep.** When every fix in the round was comment or doc *wording* with no code change, this
  earns a **single comment-accuracy re-check agent** — maintainability's remit, on Sonnet
  (`model: sonnet`), scoped to exactly the lines the round rewrote — and **not** a full round.
  A pile of reworded comments cannot break a caller, and spending a correctness pass on it is
  precisely how a review degenerates into wording iteration. Anything else in the round (any
  code edit at all) makes it a normal non-trivial round with the decayed roster.

**Trivial** — safe to skip a re-review round for, *if the round contained nothing else*:
correcting comment or doc wording with no code change; reverting purely cosmetic gratuitous
churn to exactly its original form; a rename with no other edit in the same round.

**Stop the loop** — the first of these to hold:

1. **Clean.** The round produced no finding above `minor` that isn't already
   ledger-`user-declined`. This is the success exit; say so plainly in the report.
2. **Nothing applied.** The round applied no fixes at all — everything left is confirm-set
   awaiting the user, or trivial-only. There is nothing new to review; report and wait. When
   the user later approves confirm-set fixes, applying them re-opens the loop from Step 4 with
   the round counter continuing where it left off.
3. **Round cap.** Three re-review rounds have run (rounds 2, 3, and 4 — the initial review is
   round 1). Do not start a fifth.
4. **Churn detected.** Go to Step 6 instead of another round.
5. **Budget ceiling.** The next round would exceed the invocation-wide spawn ceiling from
   Step 0.8. Report what you have, say plainly that the ceiling ended the loop, and name what
   is still open — this exit is *not* a clean result and must never be written as one. If
   Step 6 escalation is also pending, spend the remaining budget on the structural agent
   rather than another local round: naming the shape is worth more than one more patch.

**Churn check — are we actually getting closer?** Run this at the end of every re-review
round, from the ledger. The round **converged** only if all three hold:

- the count of `blocker` + `important` findings strictly decreased versus the previous round;
- no finding was marked `recurred`;
- no finding was marked `fix-induced`.

Anything else is a **non-converging round**. Escalate to Step 6 when either:

- three re-review rounds have run and the change is still not clean (stop condition 3 —
  escalate rather than just reporting), **or**
- two consecutive non-converging rounds happened for the same reason — the same issue
  recurring, or fixes in the same area repeatedly spawning new findings. Don't burn the
  remaining rounds to confirm what two rounds already showed; the loop is not converging and
  more local fixes won't change that.

Note that escalation is triggered by *churn*, not by finding count. A round that fixes four
real, unrelated defects and surfaces two new unrelated ones in freshly-written code is
converging fine — the change is being genuinely improved. What earns escalation is the
*same* problem refusing to die.

**Per-commit loops in a stack review.** Each commit runs its own loop with its own round
counter, ledger rows, and churn state — a commit that came back clean in round 1 is done and
is not re-reviewed just because a sibling is on round 3. One exception: folding a fix into `C`
rebases everything above it, so after any fix, re-run the **baseline** for the descendant
commits (Step 4 already requires this) and if a descendant that was previously clean now
fails, that is a new blocker for *that* commit and re-opens its loop.

**Report the rounds, don't hide them.** The user sees one report at the end (Step 7), but it
states how many rounds ran and what each round changed. A review that quietly looped four
times reads as a one-pass review that got lucky; the round history is exactly the evidence
that tells the user how settled this code actually is.

## Step 6 — Structural escalation (conditional agent)

Reaching this step means the loop failed: three rounds of competent local fixes, or two
rounds of the same defect resurfacing, did not settle the change. **Stop fixing.** More local
fixes are the problem — each one is a patch over a shape that keeps producing defects. The
hypothesis now is that the churn has a *mechanical* cause: the code is arranged so that this
class of bug is easy to write, easy to miss, and impossible for the toolchain to catch.

Spawn **one** agent (`subagent_type: bwm-review-worker`, fresh context) whose entire job is to
name that cause mechanically. **This is the only spawn in the skill that passes `model: opus`**
— the one documented exception to the Opus 4.8 cap (Step 0.8). It is affordable precisely
because it happens at most once per invocation, and it is worth it because every cheaper agent
has already run and missed the shape. Unlike the per-round review agents, this one is given the
**full round history** — every round's patch, findings, and fix log, plus the ledger — because the
pattern it hunts is only visible across rounds. Give it `$WS_C` as the repo root, the brief,
and the project-rules paths, on the same terms as the others (read-only `jj` peeks with
`--ignore-working-copy`; confirm every `file:line` by opening the real file).

For a stack review, if two or more commits escalated, spawn **one** structural agent over all
of them together and say so — the same structural defect copied across commits is the loudest
possible version of this signal, and treating it per-commit would miss it.

### Structural agent

> You are a structural reviewer, and you are being called in because a review-and-fix loop
> failed. The same change has now been reviewed and fixed <N> times, and it is still not
> clean: <one line per round: findings found, fixes applied, what recurred or was
> fix-induced>. Every one of those fixes was locally reasonable. That is precisely why you
> are here — the problem is not that the fixes were careless, it is that the code's *shape*
> keeps manufacturing defects, and each fix patches an instance instead of the shape.
>
> Read the full round history at `<paths>` — every round's patch, findings, and fix log, plus
> the ledger — and then read the actual code in `<$WS_C>`. Your job is **not** to find more
> bugs; the other agents are better at that and have already done it three times. Your job is
> to find the **structural property** that makes this class of defect easy to write and hard
> to catch, and to express the remedy **mechanically** — as something the compiler, the type
> system, a module boundary, or a single test will enforce from now on, without anyone having
> to remember.
>
> Look specifically for:
>
> - **Type-system misuse.** An invariant enforced by convention across N call sites instead
>   of by a type. Primitives standing in for domain values (`String`/`u64`/`bool` where a
>   newtype, enum, or sealed variant belongs) so that wrong values are representable and
>   nothing rejects them. Illegal states that a type could have made unconstructible.
>   Optionality or fallibility modelled as a sentinel instead of `Option`/`Result`. A
>   too-wide type forcing every caller to re-handle cases that can't actually occur.
> - **Bad module boundaries.** Logic sitting where it can't see what it needs, so callers
>   compensate. Knowledge duplicated across a boundary so the two sides drift. A boundary
>   that leaks internals, so every change ripples. Something that should be one chokepoint
>   existing as N parallel implementations — the shape that guarantees a fix lands in one of
>   them and not the others.
> - **Missing or useless tests.** For each round's findings, ask: *what single test would
>   have failed?* If the answer is "none, because nothing tests this path," that absence is
>   the finding. If tests exist but passed through every round, say what makes them useless —
>   testing mocks rather than behavior, asserting on restated implementation, coverage
>   without assertions, a fixture so specific it can only fail if the code is rewritten. A
>   test that would have caught round 1's bug *and* round 3's is worth more than either fix.
>
> **Your output must be mechanical.** "Be more careful here", "add a comment explaining
> this", "review this area more closely", or "consider refactoring" are **not acceptable
> answers** — they are the same convention-based enforcement that already failed <N> times.
> The bar is: after your remedy lands, does the defect class become *unrepresentable*, or
> *automatically caught*? If you cannot meet that bar, say so explicitly rather than
> softening — an honest "there is no mechanical fix here; the recurring cost is X and it can
> only be managed by <specific human process>" is a valid and useful answer, and far better
> than a vague one.
>
> Return, once (not a list of findings — a diagnosis):
>
> - **Root cause** — one sentence naming the structural property, not the symptom.
> - **Mechanism** — how that property produced each round's findings. Walk the rounds and
>   attribute them; findings it cannot explain, list separately as genuinely unrelated.
> - **Mechanical remedy** — the concrete change, at `file:line`, in enough detail to
>   implement: the type to introduce and which signatures it replaces, the boundary to move
>   and what moves with it, the test to write and which rounds' findings it would have
>   caught. Name the enforcement: what will now fail, and at what point (compile, lint, test).
> - **Subsumes** — which of the accumulated findings simply cease to exist once the remedy
>   lands, and which still need their own fix afterward.
> - **Cost and placement** — the size of the restructure, and whether it belongs as a
>   **predecessor** commit (clean the shape first, then rebase this change onto it — usually
>   the right answer), a **rewrite** of the change under review, or a **follow-up** with the
>   accumulated local fixes shipping as-is. Be honest when the remedy is larger than the
>   change that provoked it; say so and let the user decide.
> - **If you do nothing** — what keeps recurring, and where it will surface next.

**The structural remedy is never auto-applied.** It reshapes types, boundaries, or history,
it is a judgment call about the design, and it is very likely larger than the change under
review. It goes to the user as a recommendation, and the loop **ends here** regardless of
their answer — do not start another review round on top of a structural diagnosis. If the
user accepts the remedy and it gets implemented, that restructure is a *new change* and
deserves its own fresh `/bwm-review` from round 1.

Report the diagnosis prominently in Step 7, above the individual findings: the structural
cause is the actionable item, and the accumulated local findings are its symptoms.

## Step 7 — Report and tear down

For a stack review, **group the report by commit** — one section per commit, in stack
order — because each was reviewed as a standalone change and the user fixes them
per-commit. Lead each commit's section with whether it stands on its own. Within a commit,
present (local only — no PR/GitHub posting):

1. **What was reviewed, and how big a review it got** — the commit (change id + description)
   and one line on its diff shape; for the run as a whole, the target revset and how many
   commits it covered. Then one line on the sizing from Step 0.8: the tier, which agents ran
   on which models, any agent the diff's shape made inapplicable (an insert-only diff skips
   reviewability), and the spawn ceiling with how much of it the run used. The user is paying
   for this; a sized-down review is a decision they are entitled to see rather than infer.
2. **Structural diagnosis** — *only if Step 6 ran*, and first, above everything else: the
   root cause, the mechanical remedy with its enforcement point, what it subsumes, its cost
   and recommended placement, and what recurs if nothing is done. Everything in the sections
   below is then presented as symptoms of it. Say plainly that the loop was stopped by churn
   rather than by coming back clean, and that nothing structural was applied.
3. **Round history** — how many rounds ran and, per round, the roster that ran it, findings
   above minor, fixes applied, and the convergence verdict (converged / recurred /
   fix-induced). Keep it to a compact table; it is how the user judges how settled the code
   is, and the roster column is what lets them see a later round was thinner than the first.
   State the exit reason: came back clean, nothing left to apply, round cap, churn
   escalation, or budget ceiling. A single-round clean review says exactly that in one line —
   no table needed.
4. **Auto-fixed** — each fix, its placement, the round it landed in, and a one-line diff
   summary; flag any that changed behavior. Show `jj diff` of the cumulative applied result
   (not per-round patches) so the user can veto.
5. **Needs your call** — the confirm set, grouped by severity, each with file:line, the
   concrete failure/future-cost, the suggested fix, and recommended placement. Mark anything
   the ledger shows as `recurred` — a fix already failed on it once, which is what the user
   most needs to know before choosing.
6. **Diff hygiene** — reviewability's tangled-concern split recommendations (always
   confirm-only), each naming which hunks form the refactor predecessor and which are the
   logic change, plus any cosmetic-churn revert that lost to a real finding in Step 3 (so
   the user sees the tension was weighed, not missed).
7. **Low-confidence leads** — the correctness agent's unconfirmed suspicions and
   reviewability's uncertain churn calls, briefly, so nothing is silently dropped.
8. **Re-raised but already declined** — one line, not a section: findings a later round
   independently re-flagged that the user declined earlier. Named so nothing is hidden, and
   *not* re-argued.

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
7. **Shipping unreviewed fixes.** Reviewing the change, applying fixes, and calling it done —
   so the only code in the commit that *no one ever reviewed* is the code written under time
   pressure to correct a known defect. Every non-trivial fix round gets re-reviewed (Step 5).
8. **Whack-a-mole.** Fixing the same defect three times in three places because the shape of
   the code keeps regenerating it, and mistaking the churn for diligence. Two non-converging
   rounds is the signal; Step 6 exists to name the shape instead of patching the next
   instance.
9. **Non-mechanical remedies.** Answering a structural problem with "be careful here", a
   comment, or a convention. Convention is exactly what failed — if the remedy isn't enforced
   by a type, a boundary, or a test that fails, it isn't a remedy.
10. **Looping forever.** Re-proposing fixes the user already declined, or re-running rounds
    past the point of diminishing returns. The ledger suppresses settled findings, and the
    round cap, the churn escalation, and the spawn ceiling bound the loop; a review must
    terminate.
11. **Unsized review.** Spending a 2700-line feature's budget on a 20-line comment fix.
    Running an agent whose mandate the diff makes unrepresentable — hunting gratuitous churn
    in an insert-only diff. Re-deriving the whole change from scratch in round 3 to re-word a
    comment, at round-1 prices. Thoroughness is finding the defects that are actually there,
    not spawning a fixed number of agents; Step 0.8 sizes the roster to the diff and Step 5
    decays it as the unreviewed surface shrinks. The counterweight is #12.
12. **Sizing down into uselessness.** The opposite failure, and the more dangerous one: a
    review too thin to catch what was there, then reported as though it were clean. Tier is a
    floor you may always exceed, cost is never a reason to skip an agent whose mandate the
    diff *does* fit, a blocker or a `recurred` finding restores the full roster, and a run
    that stopped on the ceiling says so in the report. A cheap review that misses the blocker
    bought nothing — it cost the whole change.
