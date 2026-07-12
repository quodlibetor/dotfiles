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

### Keeping *both* variants — `jj metaedit --update-change-id`

The three patterns above all end with one variant surviving.
When both are real and both should live, there is a fourth
option: mint a fresh change ID for one of them, so the two
stop being variants of a single change at all.

```bash
jj metaedit --update-change-id -r xxx/2
```

`jj metaedit` edits a revision's metadata without touching its
content, so no work is rewritten and nothing is abandoned —
the divergence resolves because there is now one commit per
change ID. Prefer this to abandoning whenever the answer to
"which one do I keep?" is "both." Confirm with `jj st` (no
longer `(divergent)`) and re-describe the new change, since it
inherits the old description.

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

To compare the two variants *against each other* despite the
differing parents, reach for **`jj interdiff`** — it compares
what two revisions *do*, not their raw trees, so the unrelated
parent history drops out:

```bash
jj interdiff --from xxx/0 --to xxx/2          # whole change
jj interdiff --from xxx/0 --to xxx/2 -- path  # scoped (it takes filesets)
```

This is the tool the `--from/--to` pitfall above should send
you to. An empty interdiff means the two variants make the
same change and differ only in where they sit — the safe case
for abandoning one.

## Sanity checks after resolution

1. `jj st` — confirm `@` is no longer marked `(divergent)`.
2. `jj log -r 'change_id(xxx)'` — confirm only one variant
   remains visible.
3. If you abandoned anything, glance at `jj op log` so you
   can rewind if you realise something was lost. (Skip if
   multiple agents are working in parallel — `jj op restore`
   is unsafe then.)
