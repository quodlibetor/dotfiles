---
name: jj
description: "**REQUIRED** - Always activate this jujutsu FIRST on any git/VCS operations (commit, status, branch, push, etc.), especially when HEAD is detached. If `.jj/` exists -> this is a Jujutsu (jj) repo - git commands will corrupt data. Essential git safety instructions inside. DO NOT IGNORE."
allowed-tools: Bash(jj *)
---

# Jujutsu (jj) Version Control System

This skill helps you work with Jujutsu, a Git-compatible VCS with mutable commits and automatic rebasing.

**Tested with jj v0.37.0** - Commands may differ in other versions.

## Important: Automated/Agent Environment

When running as an agent:

1. **Always use `-m` flags** to provide messages inline rather than relying on editor prompts:

```bash
# Always use -m to avoid editor prompts
jj desc -m "message"      # NOT: jj desc
jj squash -m "message"    # NOT: jj squash (which opens editor)
```

Editor-based commands will fail in non-interactive environments.

2. **Verify operations with `jj st`** after mutations (`squash`, `abandon`, `rebase`, `restore`) to confirm the operation succeeded.

## Core Concepts

### The Working Copy is a Commit

In jj, your working directory is always a change (referenced as `@`). Changes
are automatically snapshotted when you run any jj command. There is no staging
area.

`jj commit` combines `jj describe` and `jj new`. If the user asks you to commit something
they usually mean describe + new.

### Commits Are Mutable

**CRITICAL**: Unlike git, jj focuses on the concept of *changes*, changes can
be freely modified, and when modified the commit will be affected but the
change is stable.

1. Before starting work in a session, run `jj st`. If `@` already has changes
   unrelated to the current work run `jj new` first.
2. Describe your intended changes with `jj desc -m"Message"`
3. Run jj new again so that you're working in an empty change
3. Make your changes. As you reach functional checkpoints, squash them into the parent
   change (the one you created with -m"Message").
   - It is recommended to update the description as you iterate on changes, new
     learnings that force a new direction should be captured in the description
     if it will help reviewers understand the overall structure of the change.

Modifications will be snapshot on every jj command, if you want to run an
experiment you can run `jj new`, make some changes, and then either squash them
into your primary change or abandon them and `jj edit` your primary change.

**NEVER** modify a change that you did not initiate without user confirmation.
If you are asked to fix something in someone else's code **ALWAYS** run jj new first
and ask the user if they'd like you to squash into their changes.

### Change IDs vs Commit IDs

- **Change ID**: A stable identifier (like `tqpwlqmp`) that persists when a
  change is modified, creating a new commit
- **Commit ID**: A content hash (like `3ccf7581`) that changes when commit content changes

Prefer using Change IDs when referencing commits in commands.

### Revsets describe sets of changes

For example, since branches aren't a thing in jujutsu, the revset "trunk()..@" represents
all the changes in the current history that are not in main, and could be thought of as
"the current branch".

## Essential Workflow

### Starting Work: Describe First, Then Code

Generally, create your commit message before writing code:

```bash
# First, describe what you intend to do
jj desc -m "Add user authentication to login endpoint"

# Then make your changes - they automatically become part of this commit
# ... edit files ...

# Check status
jj st
```

Exceptions to this rule are built around using the current change as a scratch
pad for a fix.


### Creating Atomic Changes

- Each jj change should represent ONE logical change.
- Use conventional commits.

Change summaries should describe the effect of a change, not the implementation.

Facts about the implementation, things delayed for future work, concerns, and
how testing was performed should all get their own sections, of appropriate
length for the change. Sections can be omitted if reading them adds no value.

Descriptions should be in github flavored markdown.

### Viewing History

Regular changes:

```bash
# View recent changes
jj log

# View with patches
jj log -p

# View specific commit
jj show <change-id>

# View diff of working copy
jj diff
```

Evolution of an individual change, records all snapshots of a change:

```bash
# View the evolution of the current change
jj evolog

# View the evolution of a specific change
jj evolog -r <change-id>
```

### Moving Between Commits

```bash
# Create a new empty commit on top of current
jj new

# Create new commit with message
jj new && jj desc -m "Commit message"

# Edit an existing commit (working copy becomes that commit)
jj edit <change-id>

# Edit the previous commit
jj prev -e

# Edit the next commit
jj next -e
```

## Refining Commits

### Squashing Changes

Move changes from current commit into its parent:

```bash
# Squash all changes into parent
jj squash
```

**Note**: `jj squash -i` opens an interactive UI and will hang in agent environments. Avoid it.

### DANGER — `jj squash --from X --into Y` MOVES content (does not copy)

`jj squash --from <source> --into <target>` (with optional file paths)
**moves** content out of the source commit into the target. The source loses
the named files. If you then abandon the target commit, **the moved content
is destroyed** — it is no longer in either commit and cannot be recovered
except via `jj op restore`.

The most common way to wipe out work by accident:

```bash
# DON'T do this for bisecting / "let me try with just file X"
jj new <ancestor> -m "bisect: try with subset of files"
jj squash --from <real-commit> --into @ src/foo.ts src/bar.ts
# ... run tests ...
jj abandon @          # ← destroys src/foo.ts and src/bar.ts in <real-commit>!
```

Safer ways to do partial / experimental checkouts:

```bash
# (a) `jj restore --from` COPIES files from another commit into the working
#     copy without modifying the source. Use this for "what does the test do
#     with just file X from commit Y?"
jj new <ancestor>
jj restore --from <real-commit> src/foo.ts src/bar.ts
# ... run tests ...
jj abandon @  # safe — <real-commit> is untouched

# (b) `jj duplicate` if you want to keep the original commit intact and
#     experiment on a copy:
jj duplicate <real-commit>
jj edit <new-duplicate>
# ... mutate freely; original is intact

# (c) If you've already done a destructive squash+abandon, recover the content
#     *forward* (NOT via `jj op restore`, which rewinds the whole repo and
#     conflicts with parallel agents):
jj op log --no-graph -n 20 \
  -T 'self.id().short() ++ "  " ++ self.description() ++ "\n"'   # find the op before the abandon
jj log --no-graph -r 'at_operation(<op-id>, <change-id>)' \
  -T 'commit_id ++ "\n"'                   # commit ID of the lost content
jj restore --from <commit-id> [paths]      # bring it back into the working copy
#     See "Recovering data without `jj op restore`" below for the full pattern.
```

Rule of thumb: `--from` / `--into` are **content moves**, not content copies.
Before abandoning any commit that received content via squash, confirm the
source still has what it needs (`jj diff -r <source>`) or that the receiving
commit will be kept.

### Splitting Commits

**Warning**: `jj split` with no arguments is interactive and will hang in agent environments.
**ALWAYS provide a `-m MESSAGE` flag**

To divide commits, use `jj split -m wip -- path/to/file`.

To divide a commit, use `jj restore` to move changes out, then create separate commits manually.

You can restore from a specific change or commit, including evolog commits and commits in the op log,
using `jj restore --from <change or commit id> -- path/to/file`.

### DANGER — `jj absorb` redistributes the ENTIRE source commit

`jj absorb` operates on the full diff of the source revision (`@` by
default), not just incremental working-copy edits. Every hunk gets
moved to the closest mutable ancestor that last touched those lines.

That heuristic is unsafe when `@` is itself a real commit whose
additions happen to land in regions an ancestor created. Common case:
a stacked commit B that adds lines inside a function or modal markup
defined in A. `jj absorb` will move B's *own* additions backward into
A, then silently rebase B on top of the modified A — shredding B's
content into A and stripping it from B's diff.

**Default rule: do not run bare `jj absorb`.** Reach for one of these
instead, in order:

1. **`jj squash --into <target>`** when you have a focused diff (or a
   scratch commit) that should land in a known commit. Explicit,
   atomic, no heuristic — it moves exactly what you say from exactly
   where you say. This is the best option whenever it fits.
2. **`jj edit <target>`** when you need to make changes in several
   places inside the target and want to see the file in its
   post-target state. Predictable, descendants auto-rebase cleanly.
3. **`jj absorb --into <revset>`** only as a last resort, when you
   have many small unrelated hunks that each belong to different
   ancestors and listing them out individually would be tedious.

When you do reach for `jj absorb`, **always pass `--into <revset>`** to
restrict which ancestors can receive hunks. The default `--into mutable()`
is too broad — it includes every mutable ancestor.

```bash
# Move only into a specific commit
jj absorb --into <change-id>

# Move only into the immediate parent
jj absorb --into @-
```

Even with `--into`, audit the result afterward with `jj diff -r <source>`
and `jj diff -r <target>` to confirm no descendant lost content. Safest
when the source commit has no description (i.e. it's a scratch
working-copy commit); risky when the source is a real described commit.

### Abandoning Commits

Remove a commit entirely (descendants are rebased to its parent):

```bash
jj abandon <change-id>
```

### Undoing Operations

**NEVER** use `jj undo` or `jj op restore` -- THESE WILL CONFLICT IF MULTIPLE
AGENTS ARE WORKING IN PARALLEL. Both rewind the *entire repo* to a past
operation, clobbering concurrent work from other workspaces and reintroducing
divergent operations. When you need data from a past operation, recover it
*forward* instead — see *Recovering data without `jj op restore`* below.

### Recovering data without `jj op restore` (agent-safe)

**jj never actually deletes data.** Every working-copy snapshot and every
commit is preserved in the operation log and the content store, reachable by
commit ID. So "I lost my changes" is almost always "my changes are orphaned in
an earlier operation," not real loss.

The naive recovery is `jj op restore <op>` — **don't** (see above). Instead,
**bring the lost content forward into the current operation** by referencing
the orphaned commit's ID directly. A full commit ID stays resolvable in the
current op *even when the commit is hidden/abandoned* — `jj show`,
`jj restore --from`, `jj new`, `jj duplicate` all accept it.

The bridge between a past operation and the current one is the
**`at_operation(<op-id>, <revset>)`** revset function: it evaluates a revset as
of an earlier operation but returns commit IDs usable *now*. Combine it with
ordinary revset functions to *locate* the lost commit by content instead of
eyeballing IDs — `mine()`, `description(pat)`, `subject(pat)`,
`files(fileset)`, `author(pat)`, `diff_lines(text, [files])` /
`diff_lines_added` / `diff_lines_removed`.

Everything below is non-interactive — no pager, no `jj op restore`:

```bash
# 1. Find the operation that holds the lost state. Read it from a templated
#    op log (do NOT page-and-search). `snapshot working copy` ops are the ones
#    that captured working-copy state.
jj op log --no-graph -n 20 \
  -T 'self.id().short() ++ "  " ++ self.description() ++ "\n"'

# 2. Resolve the commit ID of `@` (or any revset) as of that operation.
jj log --no-graph -r 'at_operation(<op-id>, @)' -T 'commit_id ++ "\n"'
#    Or narrow by content if several ops could hold it, e.g.:
#    -r 'at_operation(<op-id>, mine() & files("src/foo.ts"))'

# 3. In the CURRENT operation, that commit ID is still resolvable. Bring the
#    content forward however fits the situation:
jj restore --from <commit-id>            # pull all those files into the working copy
jj restore --from <commit-id> path/...   # ...or just specific paths
jj new <commit-id>                        # ...or resume work directly on top of it
jj duplicate <commit-id>                  # ...or copy it into the visible history
```

Verify with `jj st` / `jj diff` that the content is back before continuing.

This is also the recovery for a destructive `squash --from/--into` + `abandon`
(see the squash danger note above): the abandoned commit's content is still
reachable by its commit ID from the op just before the abandon — `jj restore
--from <commit-id>` brings it back without rewinding the repo.

#### `jj workspace update-stale` "ate" my uncommitted changes

The most common trigger. When another workspace rewrites a commit your
workspace sits on, your workspace goes *stale*, and `jj workspace update-stale`
resets `@` to the current working-copy commit. It **snapshots your stale
working copy first**, so nothing is lost — but that snapshot lands in the op
log *behind* a `reconcile divergent operations` op, where it's easy to miss and
panic.

The op you want is the `snapshot working copy` op that runs *immediately
before* `reconcile divergent operations` — that snapshot, NOT the reconcile,
holds your work:

```bash
jj op log --no-graph -n 20 \
  -T 'self.id().short() ++ "  " ++ self.description() ++ "\n"'
#   ...read the list, pick the `snapshot working copy` just before
#   `reconcile divergent operations`.
jj log --no-graph -r 'at_operation(<snapshot-op-id>, @)' -T 'commit_id ++ "\n"'
jj restore --from <commit-id>    # then rebase onto the new base as needed
```

### Hiding changes

For bisecting, it's usually better to split and rebase than it is to restore,
this is similar to git's stash workflow:

For example:

```
# get current parent commit
current_parent=$(jj log -T change_id -n 1 --no-graph -r @-)
# creates a new commit containing just path to file, ancestor of the change you end up on
jj split -m "message" -- path/to/file.txkt
# move that new commit *out from under you* so it is on a divergent branch
jj rebase -r @ -o "$current_parent"
```

### Restoring Files

Discard changes to specific files or restore files from another revision:

```bash
# Discard all uncommitted changes in working copy (restore from parent)
jj restore

# Discard changes to specific files
jj restore path/to/file.txt

# Restore files from a specific revision
jj restore --from <change-id> path/to/file.txt
```

## Working with Bookmarks (Branches)

Bookmarks are jj's equivalent to git branches:

```bash
# Create a bookmark at current commit
jj bookmark create my-feature -r@

# Move bookmark to a different commit
jj bookmark move my-feature --to <change-id>

# List bookmarks
jj bookmark list

# Delete a bookmark
jj bookmark delete my-feature
```

## Git Integration

### Working with Existing Git Repos

```bash
# Clone a git repository
jj git clone <url>

# Initialize jj in an existing git repo
jj git init --colocate
```

### Switching Between jj and git (Colocated Repos)

In a colocated repository (where both `.jj/` and `.git/` exist), you can use both jj and git commands. However, there are important considerations:

**Switching to git mode** (e.g., for merge workflows):
```bash
# First, ensure your jj working copy is clean
jj st

# Then checkout a branch with git
git checkout <branch-name>
```

**Switching back to jj mode**:
```bash
# Use jj edit to resume working with jj
jj edit <change-id>
```

**Important notes:**
- Git may complain about uncommitted changes if jj's working copy differs from the git HEAD
- ALWAYS ensure your work is committed in jj before switching to git
- After git operations, jj will detect and incorporate the changes on next command

### Pushing Changes

When the user asks you to push changes:

```bash
# Push a specific bookmark to the remote
jj git push -b <bookmark-name>

# Example: push the main bookmark
jj git push -b main
```

**Before pushing, ensure:**
1. Your bookmark points to the correct commit (bookmarks don't auto-advance like git branches)
2. The commits are refined and atomic
3. The user has explicitly requested the push

**IMPORTANT**: Unlike git branches, jj bookmarks do not automatically move when you create new commits. You must manually update them before pushing:

```bash
# Move an existing bookmark to the current commit
jj bookmark move my-feature --to @

# Then push it
jj git push -b my-feature
```

If no bookmark exists for your changes, create one first:

```bash
# Create a bookmark at the current commit
jj bookmark create my-feature

# Then push it
jj git push -b my-feature
```

## Handling Conflicts

jj allows committing conflicts — every conflict is part of a
commit's tree, not just a working-copy state. That means a
conflict can sit silently in an ancestor commit even when `@`
itself has no conflict markers.

```bash
# Working-copy conflicts (the ones git would show)
jj st

# Every conflict reachable from @, including in ancestors
jj log -r 'ancestors(@) & conflicts()'
```

Do **not** use `jj resolve` — it's interactive and hangs in
agent environments.

### Resolving conflicts in stacked commits

Walk conflicted commits oldest-first. For each one:

1. `jj new <conflicted-change-id>` — create an empty child of
   the conflicted commit.
2. Edit the conflicted files to remove conflict markers.
3. `jj squash` — folds the resolution into its parent, clearing
   the conflict there.
4. Move to the next conflicted commit and repeat.

Why this over `jj edit <id>` + edit-in-place: keeps each
resolution as a discrete reviewable step before it's folded
in, and avoids the working copy itself sitting on a conflicted
commit while you think.

### Self-resolving conflicts and empty commits

A conflict in commit A can sometimes be "resolved" by a
descendant B that happens to overwrite the same lines. The
working copy looks healthy, but A still carries a conflict in
its tree — the next rebase / split / revert will surface it.
Resolve A anyway using the pattern above.

After A is resolved, B may become **empty** (it was just
re-stating what A now says). Abandon empty commits when that
happens:

```bash
jj abandon <empty-change-id>
```

Verify with `jj log` that the empty commit is gone and the
stack is clean.

## Divergent changes

A change is *divergent* when the same change ID points at two
or more commits — usually because two workspaces touched the
same change, or a rebase from one workspace landed under
another. `jj st` / `jj log` mark these as `(divergent)`, and
the unqualified change ID errors with a hint listing slash
forms (`xxx/0`, `xxx/2`, …).

Resolving divergence is uncommon but has its own pitfalls
(the `change_id/N` slash form, mapping slash → commit, why
`jj diff --from A --to B` between divergent siblings is
misleading, when it's safe to abandon vs. when to ask the
user). When you hit a divergent change, read
[`divergent-changes.md`](divergent-changes.md) in this skill
directory — it covers the resolution patterns end to end.

## Preserving Commit Quality

**IMPORTANT**: Because commits are mutable, always refine them:

1. **Review your commit**: `jj show @` or `jj diff`
2. **Is it atomic?** One logical change per commit
3. **Is the message clear?** Use imperative verb phrase in sentence case format with no full stop: "Verb object"
4. **Are there unrelated changes?** Use `jj restore` to move changes out, then create separate commits
5. **Should changes be elsewhere?** Prefer `jj squash --into <target>` (best when it fits). Fall back to `jj edit <target>` for in-place edits. Avoid bare `jj absorb` — see the danger note above; if you must, scope it with `--into <revset>`.

## Quick Reference

| Action | Command |
|--------|---------|
| Describe commit | `jj desc -m "message"` |
| View status | `jj st` |
| View log | `jj log` |
| View diff | `jj diff` |
| New commit | `jj st` then `jj new` only if `@` has changes, then `jj desc -m "message"` |
| Edit commit | `jj edit <id>` |
| Squash to parent | `jj squash` |
| Auto-distribute (DANGEROUS — see danger note) | `jj absorb --into <revset>` |
| Abandon commit | `jj abandon <id>` |
| Copy files from another commit into working copy | `jj restore --from <id> [paths]` |
| Create bookmark | `jj bookmark create <name>` |
| Push bookmark | `jj git push -b <name>` |

## Best Practices Summary

1. **Describe first**: Set the commit message before coding
2. **One change per commit**: Keep commits atomic and focused
3. **Use change IDs**: They're stable across rewrites
4. **Refine commits**: Leverage mutability for clean history
5. **Embrace the workflow**: No staging area, no stashing - just commits
6. That said, stashing looks like splitting changes and making them not part of your current history

