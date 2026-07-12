# Cross-workspace infrastructure & coordination

Sibling jj workspaces share one repo (op log, history, commit
store) but are **separate directories and separate processes**.
The moment you build tooling that must coordinate *across* them —
a lock so only one workspace does X at a time, a shared queue, a
cache/marker set every workspace reads, a serialization point —
you are writing cross-process infrastructure, and a few patterns
keep it correct. This file is the general playbook; the concrete
worked example is fernweh's `ws:integrate` merge queue
(`mise.toml` + `scripts/integration-lock.py`).

## Where shared state lives: the main checkout, gitignored

Every workspace lives at `<main>/.workspaces/<name>`. To find the
one shared location all siblings agree on, derive the main
checkout from the workspace root:

```sh
root="$(jj workspace root)"
main="${root%%/.workspaces/*}"   # same in every sibling
```

Put coordination files under `<main>/` (e.g. `<main>/.coord/`) so
there is exactly **one** instance, not one per workspace. Guard
the derivation: if `$(dirname "$main")` ends in `/.workspaces`,
you mis-derived (you're nested) — fail loudly rather than write to
the wrong tree.

**Anything you drop under the tree MUST be gitignored.** jj
auto-snapshots the working copy of whatever checkout a command
runs in; an untracked-but-not-ignored coordination file becomes
*commit content* and silently dirties `@`. In a workflow that
requires `@` (or `default@`) to be an empty tip, that trips
emptiness gates with a baffling "working copy has content"
error. Ephemeral-only artifacts (a lock file) can instead live in
`$TMPDIR` keyed by a hash of `$main` — no gitignore dependency,
and the model jj itself can't snapshot them. Persistent artifacts
(caches, markers) stay in-tree, gitignored, like a `.gate-logs/`.

### The gitignore bootstrap trap

If the commit that *introduces* the tooling is also the commit
that adds the `.gitignore` entry hiding the tooling's artifacts,
that tooling **cannot land itself**: on its first run the artifact
isn't ignored yet, gets snapshotted, dirties the working copy, and
any emptiness gate refuses. Land the first instance by the *old*
path (or add the ignore in a separate earlier commit); every run
after that is clean. Document this so the one-time exception isn't
read as a bug later.

## Locking: use an OS advisory lock, not a hand-rolled lockfile

The recurring temptation is a PID lockfile (`mkdir lock.d` +
write the holder pid + `kill -0` to detect a dead holder +
reclaim). **Don't.** It has two failure modes you cannot fully
close in a shell:

- **Reclaim races (TOCTOU).** Detecting a stale lock and removing
  it is never atomic against another waiter that already re-took
  it — you end up deleting a live lock and double-holding. Every
  guard you add (atomic `mv`-steal, re-read-before-steal) shrinks
  the window but doesn't eliminate it.
- **PID reuse.** After a holder is SIGKILLed the OS can hand its
  pid to an unrelated process, so `kill -0` reports "alive" and
  the dead lock is **never** reclaimed — every waiter blocks until
  a timeout. A pid heuristic is not just racy, it's *wrong*.

An **OS advisory lock releases on the holder's death — any death,
including SIGKILL — because the kernel owns it.** That deletes the
entire stale-detection problem: no reclaim, no pid heuristic, no
TOCTOU. Two forms:

1. **`flock(2)` held for a shell script's lifetime.** The lock is
   attached to an *open file description*; it releases only when
   the last fd referring to it closes. So the shell keeps the fd
   open for the whole run and a one-shot helper takes the flock on
   the inherited fd:

   ```sh
   exec 9>>"<main>/.coord/lock"          # fd 9 open for the whole run block
   python3 lock.py acquire --fd 9 ...     # child flocks the INHERITED fd, exits
   #   ... the whole critical section runs here, lock still held ...
   #   NO trap, NO release — the kernel frees it when this shell's fd 9 closes
   ```

   The helper (a child) flocking fd 9 and exiting does **not**
   release: the shell's fd 9 still references the same description.
   The lock frees when the shell exits or is killed. macOS ships no
   `flock(1)` CLI, but `flock(2)` is reachable from stdlib
   `python3 -c 'import fcntl; fcntl.flock(9, ...)'` (or perl) — **no
   dependency needed**; a `filelock`-style library only helps if it
   wraps the whole critical section in one process, which the
   inherited-fd trick avoids.

   Helper essentials: `LOCK_EX | LOCK_NB` → fail-fast on
   contention (exit non-zero, print the holder from a sibling
   `lock.holder` file); a poll loop on `LOCK_NB` for a bounded
   `--wait`. Catch **only** `BlockingIOError` as "held elsewhere" —
   let any other `OSError` (e.g. `EBADF` from an unopened fd)
   surface as the real setup bug it is.

   Subtlety: a subprocess that must NOT keep the lock alive (a test
   runner that may spawn a lingering daemon) should close the fd
   for itself only — `( exec 9>&-; the-subprocess )`. The parent
   keeps its fd, so the lock stays held across the section, but an
   orphaned grandchild can't pin it after the run ends.

2. **A bound unix-domain socket**, for a lock held for a
   long-lived *process's* life rather than a shell script's. The
   kernel releases the binding on any death; a waiter distinguishes
   "held" from "stale socket file" by connecting (the holder
   answers with its identity; `ECONNREFUSED` = gone). fernweh's
   `tests/machine-lock.ts` is the reference implementation.

Pick (1) when the lock must span several sub-commands of one shell
task; pick (2) when a single process holds it start to finish.

## Snapshot hygiene across siblings

jj auto-snapshots only the workspace a command runs *in*. If your
tool reads recorded commits in *other* checkouts (an emptiness
check, a "what's on that line" query), un-snapshotted edits there
read as absent and can be clobbered. Snapshot every side you'll
judge first (`cd <side> && jj st`), and remember that a checkout
that is both stale and dirty, when refreshed, rescues its edits
into a *divergent* sibling — detect that and abort rather than
proceed. See [`workspaces.md`](workspaces.md) for the
cross-workspace read rules and [`divergent-changes.md`](divergent-changes.md)
for the divergence resolution.
