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
