# Parallel work in jj workspaces

A *workspace* is an independent working copy backed by the same
repo: its own directory and its own working-copy commit (`@`),
but a **shared** operation log, history, and commit store. It is
the jj counterpart to a git worktree, with the difference that
commits move freely between workspaces by rebase — there is no
per-branch checkout and no mandatory merge step.

Use one when you need real filesystem isolation while sharing
history: run a long test suite in one while you keep editing in
another, compare a file across two commits side by side, or
sandbox several agents on divergent lines at once. This is *not*
the tool for everyday single-track work — a normal `jj new` /
`jj edit` is. This repo happens to run several long-lived
workspaces (see `tasks/WORKFLOW.md`); the live set is whatever
`jj workspace list` reports.

## Create

`jj workspace add` does **not** create intermediate directories,
so `mkdir -p .workspaces` first on a repo that has never had one
(otherwise it fails with `Cannot access …` naming the *target*,
when it's the parent that's missing). First-time setup of the
`.workspaces/` directory — the ignore entry it needs before the
first add, and the build-cache config that keeps each new
workspace cheap — is in
[`workspace-setup.md`](workspace-setup.md).

```bash
# New workspace in a sibling dir, with an explicit name.
jj workspace add --name <name> ../<dir>

# Start it on a specific revision instead of a fresh child of @:
jj workspace add --name <name> -r <change-id> ../<dir>
```

Without `-r`, the new workspace gets a fresh empty commit. The
name is what `jj workspace list` / `--name` lookups use; default
is the directory basename, so pass `--name` when you want it
stable and predictable.

## List and locate (non-interactive)

```bash
# Names + working-copy commit.
jj workspace list

# Names + one-line description, easy to scan/grep.
jj workspace list --template \
  'self.name() ++ ": " ++ coalesce(self.target().description().first_line(), "(no description)") ++ "\n"'

# Resolve a workspace's directory by name (good for -R below).
jj workspace root --name <name>
```

## Inspect another workspace — two tools, opposite purposes

Cross-workspace views are **stale by default**: a jj command only
snapshots the working copy it runs against, so anything you read
about *other* workspaces is their last-recorded state, not what's
on their disk right now.

| Goal | Command | Effect |
|------|---------|--------|
| Side-effect-free peek / listing (stale OK) | `jj --ignore-working-copy -R <root> log -r 'trunk()..@'` | **Skips the snapshot** → guaranteed-stale read, including of the target. Fast, non-mutating. |
| Fresh, accurate state of another workspace | `jj status -R <root>` (no `--ignore-working-copy`) | **Snapshots that workspace first**, then reports the truth. |

`--ignore-working-copy` does **not** give you a clean read of
another workspace — it *guarantees* staleness by refusing to
snapshot at all. Reach for it only when you explicitly want a
fast, non-mutating glance and stale is acceptable. When you need
to know what's actually in another workspace, run a normal
(snapshotting) command against it with `-R <root>`.

## Referencing another workspace's commit — change IDs are global, `@`-relative revsets are not

A commit made in another workspace is a **sibling** of your `@`,
not an ancestor of it: both descend from a shared base, on
divergent lines. So any **`@`-relative revset** — `trunk()..@`,
`main..@`, `::@`, "my current branch" — **does not include it.**
Running `jj log -r 'trunk()..@'` in workspace A will never show
workspace B's work, no matter how recent.

What *does* reach across workspaces is the **change ID** — it's
stable and global, resolvable from any workspace regardless of
where each `@` sits:

```bash
jj show -r <change-id>          # inspect another workspace's commit from yours
jj diff -r <change-id>          # its diff, from anywhere
jj log  -r '<name>@'            # a workspace's working-copy commit by name (e.g. default@, feature@)
jj log  -r 'all() & description(glob:"*needle*")'   # find it without an @-relative filter
```

Practical trap when coordinating across workspaces (e.g. handing
a job to a per-workspace agent or script): **don't tell it to
locate a target commit via an `@`-relative revset.** From its
workspace the sibling commit isn't on that line, so it finds
*nothing* — or worse, grabs a different commit that **is** on its
line (a same-named scaffold/plan commit, an earlier task whose
description matches the same string). Pass the **explicit change
ID plus the commit's expected one-line description**, and have the
consumer confirm `jj show -r <id>` matches before acting. If you
want the target reachable by an ordinary `@`-relative revset,
first move onto it (`jj new <id>` / `jj edit <id>`) — that puts it
on your line.

Related reading pitfall: to answer "is X present / implemented?"
read the **current file** at that commit, not a `jj diff` — a
unified diff shows removed (old) lines that read like live code
and invite the opposite conclusion. Use the diff for *what
changed*, the file for *what is*.

## Handing work to a per-workspace agent — verify it landed where you think

An agent told to work in `.workspaces/<name>` can silently do its
edits in the **main checkout** instead (wrong `cd`, or `jj`
commands run from the wrong directory), so its content snapshots
into `default@` — the floating empty tip — rather than the
assigned workspace. The work isn't lost, but it's on `default`'s
line, not where you're about to review or integrate from.
`jj status` in the assigned workspace shows *empty*; only
`jj workspace list` reveals the described commit sitting on
`default`.

Guard both ends:

- **Brief the agent** to run `jj workspace root` before starting
  and confirm it prints the assigned `.workspaces/<name>` path
  (STOP if it prints the main checkout), and to keep every
  `jj`/edit command's cwd inside that workspace.
- **Verify after** the agent reports done: `jj workspace list`
  must show the agent's commit on the assigned workspace, not on
  `default`. Also confirm the content actually landed —
  `jj diff -r <change> --stat` shows the expected files, and grep
  the commit for a signature string of the change. An empty /
  `--stat`-clean commit means the edits never snapshotted (a stale
  working-copy view, or edits made in the wrong place); re-apply.

**Recovery when work landed on `default@`:** from the main
checkout, `jj new <content-commit>` — that turns the mis-placed
commit into a normal ancestor on `default`'s line and restores
`default@` as an empty tip. Then review and gate it in place
rather than attempting to move it cross-workspace.

**Recovery when the stray work is uncommitted in `default@`'s
working copy** *and* the assigned workspace already holds its own
(empty) target commit — the common case when the agent wrote to
main-checkout absolute paths while the workspace's `@` was a fresh
empty tip: `jj squash --from <default@> --into <workspace-commit>`
moves just that diff into the intended commit and returns
`default@` to empty. This works only when the stray files are
**disjoint** from anything else in `default@` (verify first).
Afterward the main checkout's working copy is **stale** (its `@`
was rewritten out from under it) — run `jj workspace update-stale`
there and confirm `jj status` is clean, or the next command in the
main checkout errors. This is the same staleness recovery as
below, reached by a different route.

## Staleness — when your own workspace falls behind

When another workspace rewrites a commit *your* workspace sits
on, yours goes **stale** and jj refuses to operate until you run
`jj workspace update-stale`. That command snapshots your stale
working copy *first* (so nothing is lost) before resetting `@`.
The recovery pattern — and where the snapshot lands in the op log
— is documented in `SKILL.md` under
*"`jj workspace update-stale` ate my uncommitted changes"*. Don't
reach for `jj undo` / `jj op restore` to fix staleness: both
rewind the whole repo and clobber the other workspaces' work (see
*Undoing Operations* in `SKILL.md`).

## One live writer per workspace — reap an agent before reusing its tree

A workspace has exactly one working-copy commit, and jj snapshots it on
every command. So two agents live in the *same* workspace are two writers
on one `@`, and jj gives you no protection: their edits interleave into
one change, each one's snapshot races the other's, and neither report
describes what actually landed. Symptoms seen in practice: files appearing
in a commit that no reviewer ever saw, an agent's `jj diff` disagreeing
with the disk, and a torn build cache when both sides run a build in the
tree at once.

The trap is that the first agent usually *looks* finished. A subagent that
backgrounds a long command and stops is **parked, not done** — the harness
re-invokes it when that command exits and it goes right back to editing,
possibly tens of minutes later, on top of whoever you handed the tree to
next. Its "finished" notification is a sign-off, not a report ("waiting on
the gate to finish before reporting").

**So before you point a second agent at a workspace or a change — a
revision agent onto the implementer's commit, a fix agent onto a reviewed
one — explicitly terminate the first (`TaskStop`), then clear the
stragglers it left running:**

```bash
# Orphaned gates/builds/e2e from the stopped agent still hold the tree.
pgrep -af "<workspace-path>" | grep -E "next build|vitest|playwright|check:green"
# Process age is the tell: old procs are the corpse's, fresh ones are the live agent's.
pgrep -f "<workspace-path>" | while read p; do ps -o pid,etime,command -p "$p" | tail -1; done
```

Assuming an agent is done because it said so is how a "finished"
implementer lands unreviewed code into a commit a revision agent is
editing. `TaskStop` is idempotent and free — spend it. (The supervisor-side
protocol lives in the `tasks-workflow` skill, `references/agents.md`
§ *A stopped agent is NOT a dead agent*.)

## Touching the same change from two workspaces → divergence

If two workspaces modify the same change ID, or a rebase from one
lands under another, you get a **divergent change** (the same
change ID pointing at two commits). That has its own resolution
pitfalls — see [`divergent-changes.md`](divergent-changes.md).
Avoid it by keeping each workspace on its own line of work and
rebasing deliberately (`jj rebase -s <src> -d <dest>`) rather
than editing a shared change from two places.

## After the user rebases the workspace you're in

The user sometimes rebases a workspace's stack onto a new base
while you're paused, and will say so on resume. Before any other
work (this is the pattern `CLAUDE.md` points here for):

1. Run the build, typecheck, and the tests relevant to the area
   you're working on. Confirm green.
2. Check the conflict state of **only the changes you touched
   this session**, not every ancestor:

   ```bash
   # Conflicts within your current stack (trunk()..@).
   jj log -r 'trunk()..@ & conflicts()'
   ```

   Resolve anything that surfaces there (see *Handling Conflicts*
   in `SKILL.md`). A conflict in a commit you didn't write this
   session belongs to whoever owns that work — leave it.

## Fold a sibling's work into a collector workspace

When several workspaces finish independently and you want them to
land as **one** stack, pick the first to finish as the *collector*
and rebase each sibling's work onto it as that sibling completes.
(Whether folding is worth doing is a workflow decision — see the
`tasks-workflow` skill's `references/landing.md`. What follows is
the jj mechanics, verified against jj 0.43 in a scratch repo:
topology, working-copy updates, guard behaviour and the failure
modes below were reproduced, not assumed.)

```sh
# A is the collector. B finishes next.
( cd ../B && jj st )      # MUST be clean — see hazard 1
jj rebase -r 'trunk()..B@ ~ B@' --before 'A@' -R ../A
( cd ../B && jj workspace update-stale )   # B is stale now — never skip
# then tear B down (Cleanup), and re-verify inside A.
# …repeat for C, D… then land A's stack once.
```

Why that exact form:

- **`-r 'trunk()..B@ ~ B@'`** is B's *work* at any stack depth,
  excluding B's empty scratch tip. Substitute whatever revset
  names your integrated base for `trunk()`. `-r <one-change-id>`
  moves exactly one commit and silently leaves the rest of a
  two-commit stack behind.
- **`--before 'A@'`** inserts under the collector's empty tip, so
  it works whatever A's stack looks like. `--after <A's top
  commit>` means naming that top commit correctly every round.
- **`-R ../A`** does update A's working copy on disk: the rebase
  re-parents `A@` onto the incoming work and materialises its
  files (`Added N files`). **A following `jj new` is redundant** —
  it abandons the tip the rebase just made and builds an
  identical one.
- **Tear the donor down *after* the rebase — and run `jj workspace
  update-stale` inside it first.** Tearing down first destroys the
  `B@` the revset needs. Tearing down after leaves B's checkout
  **stale**: the `-r` rebase re-parents B's own empty `@` back onto
  the old base without touching B's working copy. `update-stale`
  snapshots that working copy before resetting `@` (see *Staleness*
  above), and it is the one step in this recipe that preserves
  anything B edited since its last snapshot — Cleanup below is
  `jj workspace forget` + `rm -rf` and snapshots nothing, so an
  `rm -rf` over a stale checkout discards those edits with no
  warning and no way back. It is a backstop for a precondition
  hazard 1 already requires — not a licence to skip the `jj st`.

  **Then look at what it did: the two outcomes need different
  things from you.** Rescued nothing → the tip is empty and
  `jj workspace forget` abandons it; carry on. Rescued edits →
  they land as a **divergent twin hanging off** the collector's
  new stack rather than on it, so it sits outside `trunk()..A@`,
  the revset every landing in this file uses, and `jj st` inside
  A still reads clean. Landing A would silently leave those edits
  behind, and Cleanup's `rm -rf` is one step away. Squash the twin
  back before you forget or remove anything — see SKILL.md
  § *`jj workspace update-stale` "ate" my uncommitted changes*.

Hazards — each one reproduced, not theorized:

1. **Snapshot the donor first (`jj st` inside it).** A jj command
   run in A does not snapshot B. Rebase B's work away while B has
   un-snapshotted edits and B's checkout goes stale;
   `update-stale` then rescues those edits into a **divergent**
   commit hanging off the middle of the collector's new stack.
   `jj st` costs nothing, and it both snapshots and proves the
   empty-tip hygiene a landing guard will demand anyway.
2. **The fold is where cross-workspace conflicts surface.**
   `jj rebase` exits **0** when it *materialises* conflicts — it
   warns, writes conflict markers into the collector's working
   copy, and leaves a `(conflict)` commit in the stack. Resolve
   there (`jj new <conflicted>` → `jj resolve` → `jj squash`).
   Don't lean on an emptiness preflight to catch it: a
   conflicted-but-empty `A@` still reads *clean*.
3. **A donor that touched the dependency manifest or lockfile**
   invalidates any shared or symlinked dependency tree the
   collector is using — reconcile it right after folding that
   donor in.
4. **Fold file-disjoint work.** Same constraint as running the
   batch in parallel at all; the fold just moves the collision
   from land time to fold time.

The collected tip is a **fresh commit id**, so any green-marker
fast path keyed on a tested tree's id cannot match it — the batch
gets a real verification run, once, on exactly the tree that
lands.

## Cleanup — two independent steps

Forgetting a workspace and deleting its directory are separate
actions; neither does the other, and jj does **not** stop you
from forgetting the one you're standing in.

```bash
# From a DIFFERENT workspace (don't forget the one you're in):
jj workspace forget <name>     # drops it from the repo's tracking
rm -rf "$(…/<root>)"           # then remove the directory yourself
```

If you only `forget`, a stray directory lingers on disk; if you
only `rm -rf`, the repo keeps a dangling workspace entry. Do both.
