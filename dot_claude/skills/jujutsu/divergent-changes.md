# Resolving Divergent Changes

A change is *divergent* when the same change ID points at two
or more commits — the change got rewritten independently in
two contexts. Most often this happens when:

- Multiple jj workspaces share one repo and both touch the
  same change (one workspace's `@` and another's `@` were the
  same change ID).
- A change you're working on gets rebased from a different
  workspace while you're paused; `jj workspace update-stale`
  brings the rewritten variant in alongside your local one.

`jj` does not auto-pick a winner. You have to.

## Recognising it

- `jj st` shows `(divergent)` next to `@` when the working
  copy is on a divergent change.
- `jj log` shows the same change ID on multiple lines.
- Using the unqualified change ID errors:

  ```
  Error: Change ID `kotnwump` is divergent
  Hint: Use change offset to select single revision:
        kotnwump/0, kotnwump/2
  ```

## The `change_id/N` slash form

Each variant is addressable as `<change_id>/<N>`. The `N` is
an ordinal jj assigns when listing variants — it includes
hidden / obsolete variants, so the indices may skip (`/0,
/2`) or run higher than the visible-in-`jj log` count
suggests.

To map slash form → commit ID, list every variant with both
fields in the template:

```bash
jj log -r 'change_id(xxx)' --no-pager -T \
  'change_id.short() ++ "  " ++ commit_id.short() ++ "  " ++ \
   if(empty, "(empty)", "(has work)") ++ "  " ++ \
   committer.timestamp() ++ "\n"'
```

If a slash variant isn't shown by `jj log` (hidden /
obsolete), use `jj show xxx/N --no-patch` to inspect it
directly — that prints the commit ID at the top.

## Resolution patterns

### Empty undescribed variant → always safe to abandon

If one of the divergent variants is empty (`(empty)`) and has
no description, abandoning it is risk-free regardless of
which workspace it belongs to. After the abandon, the
workspace whose `@` was on it gets relocated by jj.

```bash
jj abandon <commit-id-of-empty-variant>
# or: jj abandon xxx/N
```

### One variant has the real work, others are orphans

Common after a rebase: the rewritten variant lives where you
expect, and the stale copies (often empty, or based on the
pre-rebase parent) are orphans.

```bash
jj edit xxx/<real-variant-N>   # switch @ to the keeper
jj abandon xxx/<orphan-N>      # drop each orphan
```

`jj abandon` is reversible via the operation log (`jj op
log` / `jj op restore`) until another agent's op buries the
recovery point — see the skill's main note on why `jj op
restore` is risky with parallel agents. Don't bulk-abandon
without first confirming you can identify the keeper.

### Both variants have real, *different* work → ask the user

This is a content collision, not a stale-copy situation.
Don't silently pick one. The user knows which variant
represents intended work; jj cannot.

If you must investigate before asking:

- `jj show xxx/N` for each variant prints its own
  description and diff against its parent.
- Avoid `jj diff --from xxx/0 --to xxx/1` for comparing
  divergent variants — see the next subsection.

## Pitfall: `jj diff --from X --to Y` across divergent siblings

`jj diff --from A --to B` shows the tree difference between
A and B, *not* the difference between their respective change
contents. If A and B are divergent variants of the same change
ID but have **different parents** (e.g., one parent got
rebased and the other didn't), the diff includes every commit
that differs between the parents — which can be enormous and
completely unrelated to the divergent change itself.

To see what each variant actually contributes, use:

```bash
jj diff -r xxx/N --stat   # the variant's own diff vs. its parent
jj show xxx/N             # description + full patch
```

These describe what the variant changes, independent of its
parent's history.

## Sanity checks after resolution

1. `jj st` — confirm `@` is no longer marked `(divergent)`.
2. `jj log -r 'change_id(xxx)'` — confirm only one variant
   remains visible.
3. If you abandoned anything, glance at `jj op log` so you
   can rewind if you realise something was lost. (Skip if
   multiple agents are working in parallel — `jj op restore`
   is unsafe then.)
