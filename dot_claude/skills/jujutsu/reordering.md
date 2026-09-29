# Reordering commits: use `--before` / `--after`, not bare `-r … -o`

`jj rebase` can place a commit *relative to another commit* in one step, and
this is almost always what you want when reordering within a stack:

```bash
# Move B so that it sits immediately below A (B becomes A's parent)
jj rebase -r B --before A

# Move B so that it sits immediately above A (B becomes A's child)
jj rebase -r B --after A
```

Both forms do two things at once, correctly:

1. **Detach B and heal the hole**, reparenting B's old children onto B's old
   parents, and
2. **Splice B in at the destination**, reparenting the commit at the insertion
   point onto B.

Doing this by hand with two plain-destination rebases is the error-prone way.
`jj rebase -r B -o NEW` (`-o`/`--onto` is the destination flag; `-d` is now
an alias of it) performs only step 1's detach — B's old children are
re-parented onto B's old parents and **nothing reattaches them to B**. You
then have to `jj rebase -s <child> -o B` yourself, and if you forget, the stack quietly
builds and tests *without* B while every individual `jj diff -r <child>` still
looks correct. See the danger note in `SKILL.md`.

So:

| intent | command |
|---|---|
| move a commit earlier/later in a stack | `jj rebase -r B --before A` / `--after A` |
| lift a commit out to somewhere unrelated | `jj rebase -r B -o DEST` (then check what was above B) |
| move a commit *and everything on top of it* | `jj rebase -s B -o DEST` |
| slot a finished stack in under a commit (e.g. "rebase it behind `default@`") | `jj rebase -b TIP -B default@` |

## Slotting a whole stack in under a commit

`jj rebase -b TIP -B X` moves every ancestor of `TIP` that isn't already
an ancestor of `X`'s parents, so it's the whole stack whatever it forked
from. The stack goes onto `X`'s parents, and `X` is reparented onto the
moved stack. One command does "rebase this work behind `default@`" and
leaves the empty `default@` on top. Commits that branch off `X`'s parent
(other sessions' side branches) stay where they are.

`-b` takes descendants along too. If anything else sits on the stack, such
as another workspace's `@` or an abandoned experiment on a middle commit,
it moves with the stack, and **`X` becomes a merge of every head**. Check
first that `TIP` is the only head:

```bash
jj log -r 'heads(roots(X-..TIP)::) ~ X'    # must print only TIP
```

If other heads show up, move or abandon them first. Don't reach for
`-r 'X-..TIP' -B X`: `-r` leaves those side commits behind, stranded on
the nearest ancestor that didn't move.

`--before` also accepts the root of a series, so pushing a fix to the very
bottom of a stack — where it can become its own immediately-landable PR — is
one command:

```bash
jj rebase -r <fix> --before <current-bottom-of-stack>
```

Afterwards, read the parentage back rather than trusting the operation
summary:

```bash
jj log -r 'main::' -T 'change_id.short(8) ++ " <- " ++
                       parents.map(|p| p.change_id().short(8)).join(",") ++
                       "  " ++ description.first_line() ++ "\n"'
```
