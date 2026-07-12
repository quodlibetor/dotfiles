---
name: jj
description: "**REQUIRED** - Always activate this jujutsu FIRST on any git/VCS operations (commit, status, branch, push, etc.), especially when HEAD is detached. If `.jj/` exists -> this is a Jujutsu (jj) repo - git commands will corrupt data. Essential git safety instructions inside. DO NOT IGNORE."
allowed-tools: Bash(jj *)
---

# Jujutsu (jj) Version Control System

This skill helps you work with Jujutsu, a Git-compatible VCS with mutable commits and automatic rebasing.

**Tested with jj v0.43.0** - Commands may differ in other versions. Notably,
`jj rebase`'s destination flag is now `-o`/`--onto`; `-d`/`--destination`
survive as aliases, and `--before`/`--after` as aliases of `-B`/`-A`.

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

A *revset* is an expression naming a set of commits; every `-r` takes one.
Since branches aren't a thing in jujutsu, `trunk()..@` represents everything
in the current history that isn't in main — "the current branch." (`trunk()`
is config-resolved, not literal: the default bookmark of the `upstream` or
`origin` remote, falling back to `main`, `master`, then `trunk`.)

| you want | jj | the git habit that FAILS |
|---|---|---|
| parent / grandparent | `X-` / `X--` | `X~1`, `X~2`, `X-2` |
| child | `X+` | — |
| N generations back | `ancestors(X, N)` | `X~N` |
| ancestors including X | `::X` | |
| descendants including X | `X::` | |
| range **including** both ends | `A::B` | |
| range **excluding** A | `A..B` (same as git) | |
| and / or / **difference** | `A & B`, `A \| B`, `A ~ B` | `~` is NOT "parent" |
| commits touching a path | `files(path)` | `file(path)` — no such function |
| git's `diff A...B` | `jj diff -r 'A..B'` | git's `...` has no jj operator |

`-` and `+` are postfix operators that **chain** (`@---`); there is no
numeric suffix. Two syntax rules, each worth a wasted round trip:

- **No whitespace around `..` or `::`.** `A .. B` is `Error: Failed to
  parse revset: Syntax error`. Write `A..B`.
- **Quote the whole revset** — `~`, `|`, `&` are shell metacharacters.

And one that is worse because it is silent:

- **A backwards range is empty, not an error.** `B..A`, where A is an
  *ancestor* of B, prints nothing and **exits 0**; `jj diff -r` on it
  reports `0 files changed`. When a revset comes back empty, suspect the
  direction before you suspect the repo.
- **`..` does not distribute over `|` on its left side.** Per jj's own
  docs, `(A | B)..` is *not* `A.. | B..` — it is `A.. & B..`. Build the
  union inside the endpoints only when you mean intersection.

### Inspecting a revision — `jj show` takes no paths

`jj show`'s only positional argument is `[REVSETS]...`. It has **no**
path/fileset filter, so extra arguments are parsed as *more revisions* and
git-style path scoping fails with a misleading error:

```bash
jj show -r mslluvyvysup --git src/hooks/usePopoverDismiss.ts
# Error: Revision `src/hooks/usePopoverDismiss.ts` doesn't exist
```

A `--` separator does **not** help — there is no positional slot for it to
retarget to. This is the most-repeated jj mistake in this user's history
(30+ occurrences across a dozen sessions, mostly review subagents trying to
scope a diff read). Reach for one of these instead:

```bash
jj diff -r <rev> --git -- <path>...   # the patch, path-scoped
jj file show -r <rev> <path>          # the file's full content at <rev>
```

`jj log` and `jj split` carry the mirror-image trap: their positional
argument is `[FILESETS]`, *not* revisions. `jj log <rev>` does not fail —
it prints `Warning: The argument "<rev>" is being interpreted as a fileset
expression` and an empty log, which is easy to miss. Always `jj log -r
<rev>`. (`show`, `new`, `abandon` and `duplicate` *do* accept a bare
positional revision.)

### Comparing two revisions — `--from/--to`, not `A..B`

`jj diff -r <revset>` shows the combined diff *of the commits in that
revset* against their parents. `jj diff --from A --to B` compares two
trees. On a linear ancestor chain the two agree, which is exactly why
`A..B` looks safe — but **it degrades silently when A is not an ancestor
of B.**

Reference incident: a review brief scoped round 2 of a task as
`jj diff -r '5bd05283..da926e07'`. Those were two rounds of the *same
amended change* — predecessor and successor, not parent and child — so
they share a parent, the revset collapsed to just `{da926e07}`, and the
subagent got that commit's entire diff against its own parent. A
byte-identical `gate-cheap-suite.sh` was rendered as 85 lines all-new, and
the review pass reviewed the wrong thing.

**To compare two specific commits, always `jj diff --from A --to B`.**
Reserve `-r 'A..B'` for "show me the work in this range," where you already
know A is an ancestor of B. The same trap applies to divergent siblings —
see [`divergent-changes.md`](divergent-changes.md).

### Which selection flag does this subcommand take?

The vocabulary is not uniform. `--to` is an alias of `--into` on
`squash`/`restore`/`absorb`, but `diff` has only `--to` (there is no
`--into`), and `rebase` has none of them:

| command | source | destination |
|---|---|---|
| `diff` | `-r` (a revset, may be a range), `--from` | `--to` |
| `squash` | `-r`, `--from` | `--into` (alias `--to`) |
| `restore` | `--from`, `-c/--changes-in` | `--into` (alias `--to`) |
| `absorb` | `--from` | `--into` (alias `--to`) |
| `rebase` | `-r` / `-s` / `-b` | `-o/--onto` (alias `-d`), `-A/--insert-after`, `-B/--insert-before` |
| `bookmark move` | `--from` | `--to` |

`jj rebase` with no selector at all defaults to `-b @`. Which of
`-r`/`-s`/`-b` to reach for, and why `--before`/`--after` beats a bare
`-o`, is [`reordering.md`](reordering.md).

### A revision name carries no repo with it

Change IDs are global *within* a repo — but which repo is decided by the
shell's cwd, and the agent harness resets cwd between Bash calls. Observed
twice in one session: a `jj edit <rev>` intended for one workspace ran in a
sibling and moved *that* workspace's working copy onto the wrong commit
while a gate was running against it. Either `cd` explicitly inside every jj
call or pass `-R <path>`; never inherit a cd from a previous call.

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

### Commit early and often — squashing is cheap, splitting is dear

The refinement operations are **asymmetric** in jj. Combining commits is
trivial and safe: `jj squash`, or `jj squash --into <target>` to fold a
focused change into an earlier one. **But a bare `jj squash` targets
whatever `@`'s parent happens to be — check `jj log -r @ -T 'parents…'`
first whenever the working copy might not sit where you think.** In a
shared-line workflow the failure is severe: after a merge-queue land
re-attaches a workspace, `@` can be a SIBLING of the stack you're working
(parented directly on the landed tip), and a bare squash then AMENDS THE
LANDED COMMIT — rewriting history other workspaces have rebased onto
(observed live; `jj undo` recovered it). When folding stray working-copy
edits into a stack, always name the destination: `jj squash --into
<stack-head>`. `jj undo` reverts the whole last operation including the
descendant rebases — use it immediately on any surprise, before new
operations bury the mistake. Pulling commits *apart* is the painful
direction — `jj split` with no args is interactive (hangs in agent
environments), the `-m -- <paths>` form only divides cleanly along file
boundaries, and untangling two topics that share a file means a manual
`jj restore` dance.

So bias toward **more, smaller commits** as you work. Describe the change
before you start, snapshot at each functional checkpoint, and start a new
described change when you move to a distinct concern — rather than letting
one giant undescribed working copy accumulate several unrelated topics that
you then have to tease apart by hand.

The asymmetry is the whole point: a history that's too *fine* is cheap to
coarsen (squash); a history that's too *coarse* is expensive to refine
(split). When in doubt, err fine. It is completely fine to produce a string
of commits for a single task and combine them once the task is complete.

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

**`-m ""` silently ERASES the destination's description.** `jj squash -m <msg>`
sets the combined commit's message — an empty string is accepted and leaves the
commit undescribed, and a fallback chain like `jj squash -m "" || jj squash
--use-destination-message` "succeeds" down the first branch, so the fallback
never runs. When folding an undescribed working copy into a described parent,
use `--use-destination-message` (alone, no `-m`) to keep the parent's message.
Verify after: `jj log -r <dest> -T 'description.first_line()'` — an undescribed
commit can ride all the way to landing before anyone notices.

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

**Warning**: `jj split` will hang in agent environments, and it has **two**
separate interactive surfaces that need two different flags. `-m` alone is
**not** enough:

- The **diff editor** is suppressed by passing *filesets*. Per
  `jj split --help`, `-i/--interactive` "is the default if no filesets are
  provided" — so `jj split -m wip` with no path still opens an editor and
  hangs.
- The **description editor** is suppressed by `-m <MESSAGE>` ("the change
  description to use for the selected changes (don't open an editor)").

So always pass **both**: `jj split -m wip -- path/to/file`. Note that
`--tool` implies `--interactive`, and `--editor` forces the description
editor open — never pass either from an agent.

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

**Check `jj log` for a divergent twin first — it is often right there.**
The snapshot frequently lands as a second commit sharing your working copy's
*change id*: one empty (the reset `@`), one non-empty (your work). `jj st`
announces it as `(divergent)`, and `jj log -r <change-id>` errors with a hint
listing `<id>/0`, `<id>/2`. No op-log spelunking needed:

```bash
jj log -r 'change_id(wnmpwvvt)' --no-graph \
  -T 'commit_id.short() ++ " empty=" ++ if(empty,"yes","NO") ++ "\n"'
#   → the empty one is the reset @; the NON-empty one holds your edits.
jj diff -r <non-empty-commit-id>          # confirm it is really your work
jj squash --from <non-empty-commit-id> --into <target-change>
#   → edits land where you wanted them, and the divergence resolves.
```

Do **not** `jj abandon` the twin before diffing it — that is the move that
actually loses the work. And back edits up (`cp` to a temp dir) *before*
running `update-stale` when you have uncommitted work you care about; the
file on disk does come back without them.

If no twin is visible, fall back to the op log. The op you want is the
`snapshot working copy` op that runs *immediately before*
`reconcile divergent operations` — that snapshot, NOT the reconcile, holds
your work:

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

### DANGER — `jj rebase -r X` silently detaches X from its own children

`jj rebase -r <X> -o <dest>` moves **only** X. X's children do not follow it:
they are re-parented onto **X's old parents**, so the chain closes over the
gap where X used to be. That is the documented behaviour and it is what you
want when extracting a commit — but it is a trap when you meant "move this
commit and keep the stack on top of it," because the stack keeps building and
testing *without* X, and nothing reports an error.

The failure is quiet and arbitrarily delayed. What you see later is X's
contribution missing from every descendant — a module declaration gone, a
function you deleted in X reappearing — while `jj diff -r <child>` still looks
correct, because each child's own diff really is unchanged. Only the parentage
is wrong.

```bash
# BEFORE any -r rebase of a commit that has children, record the shape:
jj log -r 'A::' -T 'change_id.short(8) ++ " <- " ++
                    parents.map(|p| p.change_id().short(8)).join(",") ++ "\n"'
jj rebase -r X -o NEWDEST
# ...then read it back and confirm X's child still points at X:
jj log -r 'A::' -T 'change_id.short(8) ++ " <- " ++
                    parents.map(|p| p.change_id().short(8)).join(",") ++ "\n"'
jj rebase -s <X-child> -o X      # reattach when it did not follow
```

Rules of thumb:

- **Reordering within a stack? Use `jj rebase -r B --before A` (or `--after
  A`).** That splices B in at the destination *and* heals the hole it left, in
  one step — it is the right tool whenever you are moving a commit relative to
  another commit, and it avoids this whole trap. See
  [`reordering.md`](reordering.md).
- **`-s` moves the subtree** (the commit *and* its descendants). Reach for
  `-s` whenever you mean "move this and everything above it."
- **`-r … -o` moves one commit and heals the hole behind it, but reattaches
  nothing.** Only for lifting a commit out to an unrelated destination; after
  using it, always verify the parentage of what used to sit above.
- A merge that becomes redundant (`-r`'d so that one parent is now an ancestor
  of another) does **not** auto-simplify its child's parents either — reparent
  the child explicitly and confirm.

### Rebuilding a rewritten commit from its pre-surgery original

When a rebase resolution goes wrong partway up a long stack, do not hand-patch
forward from the broken state. The original commits are still reachable by
full commit id (record them with `jj log -r 'mutable()' -T commit_id` *before*
starting). Replay each change's own delta onto its corrected parent:

```bash
jj edit <change>
jj restore --from <its-new-parent>        # empty it
git reset -q                              # colocated: refresh git's stale index
git diff <old-parent-commit> <old-child-commit> > /tmp/delta.patch
git apply --3way /tmp/delta.patch         # real 3-way conflicts, with a base
```

`git apply --3way` gives ordinary `<<<<<<< ours / ||||||| base / >>>>>>> theirs`
markers — far easier to resolve correctly than a jj conflict whose "destination
side" is empty, because you can see what the change actually intended. Verify
the result by comparing `jj diff -r <change> --stat` against the original
commit's diffstat; they should match closely.

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

#### NEVER `git checkout <path>` / `git restore <path>` to undo an edit

In a colocated repo git's HEAD is `@-`, the **parent** of the working-copy
commit — not the working copy. So `git checkout -- src/foo.rs` does not
"undo my last edit to foo.rs"; it silently replaces the file with the
parent commit's version, **destroying every uncommitted change in that
file**, including hours of work unrelated to whatever you meant to revert.
git prints nothing, and `jj st` afterwards just shows the file as no longer
modified.

The evolog is **not** a reliable safety net here: jj snapshots the working
copy when a *jj command* runs, not when a file is written. A long stretch
of Edit/Write/`cargo test` with no jj command in between leaves NOTHING in
`jj evolog` to recover — the pre-checkout content never existed in a
snapshot. (Observed live: `git checkout <path>` after a run of edits, and
`jj evolog -r @` held only the state from before any of them.)

Instead:
- To drop a scratch block you appended: edit it back out with Edit/Write.
- To revert a file to its parent's content **deliberately**: `jj restore
  <path>` — same effect, but it is a jj operation, so it snapshots first
  and lands in the op log where it can be recovered forward.
- When making many edits without running jj, run a bare `jj st` at
  checkpoints purely to force a snapshot.

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

### Generated / checked-in files: regenerate, don't hand-merge

For conflicts in **generated** checked-in files (lockfiles,
vendored dep trees, gazelle BUILD files, codegen output), don't
hand-merge — the file is a function of its inputs. Resolve the
human-authored inputs by hand, clear the generated files'
markers with `jj restore --from @-`, then re-run the generator
and let the snapshot capture the result. Note that a global
lockfile (e.g. `MODULE.bazel.lock`) will re-conflict on every
rebase the stack modifies it — expected, not cruft.

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

### Amending a commit deep in a stack: snapshot the descendants first

Editing or splitting a commit that has descendants auto-rebases
them. Where a descendant touches the same region, that rebase
conflicts — and hand-merging those markers is both error-prone
and usually *unnecessary work*, because you already know what the
descendant's file should contain: nothing about it changed, only
its parent did.

So **before** the surgery, save the final content of every file
you're about to touch, for each descendant that also touches it:

```bash
# For each descendant D that touches the same files:
jj file show -r <D> path/to/file.rs > /tmp/keep-<D>-file.rs
```

Do the surgery. Then, for each conflicted descendant, overwrite
the conflicted file with the saved copy instead of merging markers:

```bash
jj edit <D>
cp /tmp/keep-<D>-file.rs path/to/file.rs
```

jj recomputes that commit's diff against its *new* parent, so the
descendant's content is preserved exactly while its diff shrinks to
just its own delta. Verify with `jj log -r 'conflicts()'` (empty)
and `jj diff -r <D> --stat`.

**Only correct when the descendant's final content genuinely should
not change.** That's the common case for a pure refactor or a fix
extracted downward — the descendant wanted that content before and
still does. But if the edit is meant to *propagate* (you fixed a bug
the descendant also carries, or renamed something it calls), then
restoring the old content silently reverts your fix in every commit
above. Decide which case you're in per file, not per stack.

Forgot to snapshot first? Recover forward — the pre-rebase content is
still reachable. Find the operation just before the surgery and read
the descendant's file as of then:

```bash
jj op log --no-graph -n 10 -T 'self.id().short() ++ "  " ++ self.description() ++ "\n"'
jj log --no-graph -r 'at_operation(<op-id>, <D>)' -T 'commit_id ++ "\n"'
jj file show -r <commit-id> path/to/file.rs > /tmp/keep-file.rs
```

This is the same forward-recovery idea as *Recovering data without
`jj op restore`* above, used deliberately rather than in a panic —
and it is why you still never need `jj undo` here.

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

## Parallel work in workspaces

jj *workspaces* are independent working copies that share one
repo's history — the rough equivalent of git worktrees, used to
run long tests while you keep editing, compare a file across
commits, or sandbox parallel agents on divergent lines. This repo
runs several long-lived ones (`jj workspace list`). When
**creating, listing, inspecting, or cleaning up** a workspace —
or after the user rebases the workspace you're in — read
[`workspaces.md`](workspaces.md). It covers the create/list/cleanup
commands, the `--ignore-working-copy`-guarantees-staleness rule
for cross-workspace reads, **referencing another workspace's commit
by its global change ID (an `@`-relative revset like `trunk()..@`
won't see a sibling workspace's work)**, and the post-rebase scope
check that `CLAUDE.md` points here for.

**Setting a repo up for workspaces the first time** — creating
the `.workspaces/` directory, or noticing that a new workspace
costs a full cold build — is a separate, rarer job: read
[`workspace-setup.md`](workspace-setup.md). It covers the
ignore-before-first-add ordering (and the `jj file untrack`
recovery if you missed it), the fact that `jj workspace add`
won't create the parent directory, and the per-ecosystem build
config that keeps a new workspace cheap. Read it **before
pointing two workspaces of a Rust project at one build
directory**: registry dependencies do share correctly, but the
repo's own crates collide on one artifact slot, so a workspace
whose sources are older than a sibling's last build gets
`Finished` and the *sibling's* binary — which is exactly the
workspace that only runs tests.

## Cross-workspace infrastructure

When you are **building tooling that coordinates across sibling
workspaces** — a lock so only one workspace runs something at a
time, a shared queue or serialization point, a marker/cache set
every workspace reads, anything that organizes or synchronizes
`.workspaces/*` — read
[`cross-workspace-infra.md`](cross-workspace-infra.md). It covers
where shared state must live (the derived main checkout,
gitignored, and the gitignore-bootstrap trap), why to use an OS
advisory lock (`flock(2)` on an inherited fd, or a bound unix
socket) instead of a hand-rolled PID/mkdir lockfile (reclaim
TOCTOU + pid-reuse deadlock), and snapshot hygiene when your tool
reads other checkouts.

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
| View log | `jj log` (revisions need `-r`; bare args are paths) |
| View diff | `jj diff` |
| View a commit's diff for some files | `jj diff -r <id> --git -- <path>` (**not** `jj show <id> <path>`) |
| Compare two commits | `jj diff --from <a> --to <b>` (**not** `-r 'a..b'`) |
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

