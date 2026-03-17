# git-stack

Helpers for working with stacked PR branches in git. These commands operate on
your entire PR stack at once, so you don't have to remember which branch is at
the top or manually repeat commands for each branch.

A "stack" is all branches that share history since the merge-base with
`origin/main`. Stacks can be linear or branching (multiple branches forking off
a common point).

## Install

```
brew tap quodlibetor/tap
brew install --head quodlibetor/tap/git-stack
```

## Commands

All commands support `-h` for detailed help.

### git-rebasestack

```
git rebasestack <git-rebase args> <target-branch>
```

Rebase everything in the current stack onto `<target-branch>`. Finds the
topmost branch in the stack, checks it out, runs
`git rebase --update-refs <target>`, and returns you to your original branch.

Without this, you'd need to manually find the last branch in the stack, check
it out, rebase with `--update-refs`, and check out your branch again.

**Note:** This command requires linear history — it will error if your stack
has branches that diverge from a common point. Use `git-lgstack` to visualize
the stack, and you can manually `git rebase` after checking out the branch
you care about.

### git-pushstack

```
git pushstack
```

Force-push all branches in the current stack to origin using
`--force-with-lease`. Prompts before pushing:

- **y** — push all branches
- **s** — choose which branches to push interactively
- **N** — abort

### git-lgstack

```
git lgstack
```

Show the log for all branches in the current stack at once (via `git lgs`).
Unlike `git log`, which shows a single ref, this automatically discovers every
branch in the stack and displays them together.

## Examples

### Linear stack

```
*  44444  me/finish-ui    code review
*  33333                  finish the ui
*  22222  me/do-backend * respond to code review
*  11111                  write the backend
```

From any branch in the stack:

- `git rebasestack origin/main` — rebases the entire stack onto `origin/main`
- `git pushstack` — offers to push both `me/do-backend` and `me/finish-ui`
- `git lgstack` — shows the log for both branches together

### Branching stack

```
*  55555  me/new-endpoint   add API endpoint
| *  44444  me/finish-ui    code review
|/
*  33333  me/do-backend *   respond to code review
*  22222                    write the backend
```

Here `me/finish-ui` and `me/new-endpoint` both branch off `me/do-backend`.
`git-lgstack` and `git-pushstack` work with all three branches.
`git-rebasestack` does not support this shape — rebase each fork separately
with `git rebase --update-refs`.
