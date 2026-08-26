# Setting up `.workspaces/` for a project

Creating a workspace should cost a few seconds and a few
megabytes, not a full dependency install and a cold build. That
is a property of the *containing directory*, set up once per
repo, not of each `jj workspace add`. This file covers that
one-time setup and what each ecosystem does and does not let you
share between workspaces.

The layout every other file in this skill assumes:

```
<main>/                     ← the default workspace (the repo checkout)
  .workspaces/              ← ignored; holds the workspaces below
    <name>/                 ← an actual jj workspace
      target/               ← build output stays INSIDE the workspace
```

Keeping workspaces *inside* the repo (rather than `../<name>`
siblings) is what lets tooling derive the one shared root from
any sibling — `main="${root%%/.workspaces/*}"`, see
[`cross-workspace-infra.md`](cross-workspace-infra.md) — and
makes teardown a single `rm -rf .workspaces/<name>`.

## One-time bootstrap: ignore `.workspaces/` before the first add

This must happen **before** the first `jj workspace add`, and it
is the only setup step — no ecosystem below needs a per-repo
build config.

jj does not create intermediate directories when `jj workspace add
path/to/workspace` is invoked.

jj skips *nested workspaces'* working copies when it snapshots
the main checkout — `.workspaces/feat/`'s files never appear in
`jj st` at the top level. But it does **not** ignore
`.workspaces/` itself, so anything else you put there (logs,
scratch output) snapshots straight into the main checkout's `@`.

Create a workspace and immediately gitignore it:

```sh
mkdir -p .workspaces
printf '*\n' >> .workspaces/.gitignore
```

jj honours `.gitignore`.

**If you forgot and the files are already tracked**, adding the
ignore does nothing — jj keeps tracking what it has already
snapshotted. Untrack them explicitly:

```sh
jj file untrack '.workspaces'
```

This is the same bootstrap trap described in
[`cross-workspace-infra.md`](cross-workspace-infra.md); it bites
here because build output lands under an un-ignored directory.

## The rule that decides what is safe to share

> **Content-addressed caches are safe to share across
> workspaces. Path- or mtime-keyed *output* directories are
> not.**

A content-addressed cache keys entries by a hash of the inputs,
so two checkouts with different source content simply get
different entries. An output directory keyed by package
name+version collides when two checkouts build the same package,
and cargo's mtime-based freshness check then hands you the
*other* workspace's artifact while reporting success.

| Ecosystem | Already shared, safe | Must stay per-workspace |
|---|---|---|
| Go | `GOCACHE`, `GOMODCACHE` (content-addressed, user-global) | nothing |
| Rust | `~/.cargo/registry` (sources) and compiled crates (the global `kache` rustc wrapper) | `target/` — never share a build-dir, see below |
| Node | the package manager's global store/cache | `node_modules/` |
| Python | `~/.cache/uv`, wheel caches | `.venv/` |

## Rust

Nothing to configure per-repo. `kache` is a `rustc-wrapper` set
globally in `$CARGO_HOME/config.toml`, so compiled crates are
already shared across every checkout on the machine. It is
content-addressed, so two workspaces with different sources get
different entries, and a new workspace's first build mostly hits
that cache instead of compiling cold.

Leave `target/` inside each workspace. It is correct by
construction, and teardown stays the `rm -rf .workspaces/<name>`
you already do.

### Never point two workspaces at one cargo build-dir

Do not "help" by setting `build-dir` or `target-dir` to a shared
location, and do not accept a request to without flagging this.
Two checkouts of one repo are the *same unit* to cargo — same
package name and version — so they share a single artifact slot,
and freshness is decided by mtime. The workspace whose files are
older is told `Finished`, compiles nothing, and has its binary
silently **replaced** with the other workspace's code. It
survives `cargo test` and `cargo run` identically, so a workspace
can test a sibling's binary and report green.

Splitting `target-dir` does not help (the collision is in the
unit hash, which `build-dir` keys), and neither does the newer
build-dir layout. Upstream: [rust-lang/cargo#12516][12516], open,
"needs design". That unfixed collision is the whole reason
sharing has to happen at the rustc-wrapper layer instead.

[12516]: https://github.com/rust-lang/cargo/issues/12516

`sccache` is not an alternative here: its Rust hasher
deliberately hashes the cwd, and `SCCACHE_BASEDIRS` — which looks
like precisely the fix — is implemented only for the C/C++ path,
so it returns zero cross-checkout hits.

## Go

Nothing to configure. `GOCACHE` and `GOMODCACHE` already default
to user-global, content-addressed directories
(`~/Library/Caches/go-build`, `~/go/pkg/mod`), shared across
every checkout on the machine. The same two-tree test that
corrupts cargo gives each tree its own correct binary under Go's
defaults, on every round.

A new Go workspace is therefore already as light as it gets:
source only, warm cache, no setup step.

## Node

`node_modules/` must stay per-workspace — it holds
platform-specific binaries and a symlink layout tied to its own
location. Do not symlink or share one between workspaces.

Cheapness comes from the package manager's global store instead:
pnpm's content-addressed store hard-links into each
`node_modules`, so a second workspace's install is close to free
in both time and disk. npm and yarn keep a global cache of
tarballs, which saves the download but still pays the unpack.
Nothing goes in `.workspaces/` for this — the store is already
user-global.

## Python

`.venv/` must stay per-workspace: absolute paths are baked into
the venv's scripts and `pyvenv.cfg`, so a copied or shared venv
points at the wrong tree.

`uv` makes the per-workspace venv cheap — its global cache
(`~/.cache/uv`) hard-links packages into each new venv, so
`uv sync` in a fresh workspace is near-instant. Again nothing
belongs in `.workspaces/`.

## Teardown

Removing a workspace is the two steps in
[`workspaces.md`](workspaces.md) — `jj workspace forget` **and**
`rm -rf .workspaces/<name>`.

On the layout here that is the whole job: build
output lives *inside* the workspace directory (`target/`,
`node_modules/`, `.venv/`) and dies with it. That property is
worth protecting. Any scheme that relocates build output to a
path merely *keyed* by the workspace — a hash directory, a
name-mangled sibling — trades a one-command teardown for
orphaned garbage you must reconcile by hand, which is a real
cost against usually-imaginary savings. A genuinely *shared*
`.workspaces/builds/` is fine by contrast: it belongs to no one
workspace, so prune it wholesale when it grows and let the next
build in each surviving workspace repopulate it.
