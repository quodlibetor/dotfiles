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
jj squash -m "message"    # NOT: jj squash
jj split -m "message" -- PATH    # NOT: jj split
```

Editor-based commands will fail in non-interactive environments.

2. **Verify operations with `jj st`** after mutations (`squash`, `abandon`, `rebase`, `restore`) to confirm the operation succeeded.
3. Always use the `--git` flag for diffs (`jj diff --git`, `jj show --git`, `jj evolog --patch --git`, etc)


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
jj log -p --git

# View specific commit
jj show --git <change-id>

# View diff of working copy
jj diff --git
```

Evolution of an individual change, records all snapshots of a change:

```bash
# View the evolution of the current change
jj evolog --git

# View the evolution of a specific change
jj evolog -r <change-id> --git
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

```
# Squash all changes into parent
jj squash

# Squash just the files from directory a/b/c and the file test/file.txt into change id xxl
jj squash -t xxl -- a/b/c test/file.txt
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

# (c) If you've already done a destructive squash+abandon, recover with:
jj op log                    # find the operation before the damage
jj op restore <op-id>        # rewinds the entire repo to that state
```

Rule of thumb: `--from` / `--into` are **content moves**, not content copies.
Before abandoning any commit that received content via squash, confirm the
source still has what it needs (`jj diff -r <source>`) or that the receiving
commit will be kept.

### Splitting Commits

**Warning**: `jj split` with no arguments is interactive and will hang in agent environments,
**ALWAYS provide a `-m MESSAGE` flag**

To divide commits, use `jj split -m wip -- path/to/file`.

You can restore from a specific change or commit, including evolog commits, using `jj restore --from <change or commit id>`.

### Absorbing Changes

Automatically distribute changes to the commits that last modified those lines:

```bash
# Absorb working copy changes into appropriate ancestor commits
jj absorb
```

### Abandoning Commits

Remove a commit entirely (descendants are rebased to its parent):

```bash
jj abandon <change-id>
```

### Undoing Operations

**NEVER** use `jj undo` or `jj op restore` -- THESE WILL CONFLICT IF MULTIPLE
AGENTS ARE WORKING IN PARALLEL.

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

jj allows committing conflicts — you can resolve them later:

```bash
# View conflicts
jj st
```

**Agent conflict resolution**: Do not use `jj resolve` (interactive). Instead, edit the conflicted files directly to remove conflict markers, then run `jj st` to verify resolution.

## Preserving Commit Quality

**IMPORTANT**: Because commits are mutable, always refine them:

1. **Review your commit**: `jj show @` or `jj diff`
2. **Is it atomic?** One logical change per commit
3. **Is the message clear?** Use imperative verb phrase in sentence case format with no full stop: "Verb object"
4. **Are there unrelated changes?** Use `jj restore` to move changes out, then create separate commits
5. **Should changes be elsewhere?** Use `jj squash` or `jj absorb`

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
| Auto-distribute | `jj absorb` |
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

