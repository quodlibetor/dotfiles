# Setting up `.workspaces/` for a project

Creating a workspace should cost a few seconds and a few
megabytes, not a full dependency install and a cold build. That
is a property of the *containing directory*, set up once per
repo, not of each `jj workspace add`. This file covers that
one-time setup and the per-ecosystem build-cache config that
makes each new workspace cheap.

The layout every other file in this skill assumes:

```
<main>/                     ← the default workspace (the repo checkout)
  .workspaces/              ← ignored; holds everything below
    .cargo/config.toml      ← per-ecosystem build config, if any
    <name>/                 ← an actual jj workspace
      target/               ← build output stays INSIDE the workspace
```

Keeping workspaces *inside* the repo (rather than `../<name>`
siblings) is what lets tooling derive the one shared root from
any sibling — `main="${root%%/.workspaces/*}"`, see
[`cross-workspace-infra.md`](cross-workspace-infra.md) — and
makes teardown a single `rm -rf .workspaces/<name>`.

## One-time bootstrap, in this order

Order matters: step 1 must happen **before** the first
`jj workspace add`.

### 1. Create and Ignore `.workspaces/` first

jj does not create intermediate directories when `jj workspace add
path/to/workspace` is invoked.

jj skips *nested workspaces'* working copies when it snapshots
the main checkout — `.workspaces/feat/`'s files never appear in
`jj st` at the top level. But it does **not** ignore
`.workspaces/` itself, so anything else you put there (the
`.cargo/config.toml` below, logs, scratch output) snapshots
straight into the main checkout's `@`.

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
here because the build config and the build cache both land
under an un-ignored directory.

### 2. Add the per-ecosystem build config

See the sections below. For Rust this is a **question to ask the
user**, not a default to pick — see *Ask first*.

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
| Rust | `~/.cargo/registry` (sources); compiled crates only via a rustc wrapper | `target/` — never share a build-dir, see below |
| Node | the package manager's global store/cache | `node_modules/` |
| Python | `~/.cache/uv`, wheel caches | `.venv/` |

## Rust

### Ask first — this is a per-repo choice, not a default

When setting up `.workspaces/` for a Rust repo, check for an
existing `<main>/.workspaces/.cargo/config.toml`. If it is there,
follow it; the choice has been made. If it is not, **ask before
writing any config**:

> This repo's workspaces can either **share compiled dependencies**
> (via a `RUSTC_WRAPPER` cache — one copy of the compiled deps, and
> a new workspace skips most of the cold build), or **keep
> independent copies** (nothing to install, but every workspace
> pays its own cold build and its own disk). Which fits this
> project?

The deciding factor is the size of the build directory, so lead
with that rather than with the mechanism:

- **Tens of GiB per build dir** → share. Two copies of an 80 GiB
  target directory is 160 GiB, and that dominates everything else.
- **Ordinary size** → independent copies. Simpler, nothing to
  install, nothing extra to go wrong.

If the user has no preference, pick independent copies.

### Mode 1 — independent copies

Nothing to configure. Leave `target/` inside each workspace: it
is correct by construction, and teardown stays the
`rm -rf .workspaces/<name>` you already do. Dependency *sources*
are still shared via the user-global `~/.cargo/registry`, so a
new workspace never re-downloads — it only re-compiles.

### Mode 2 — share compiled artifacts with a rustc wrapper

Sharing must happen at the **artifact** layer. Each workspace
keeps its own `target/`, and a `RUSTC_WRAPPER` cache serves the
compiled crates across workspaces.

Requires [kache](https://github.com/kunobi-ninja/kache) on PATH
(binary releases, or add it as a mise tool for the project).
Then write `<main>/.workspaces/.cargo/config.toml`:

```toml
[build]
rustc-wrapper = "kache"     # or an absolute path
```

Cargo finds this by walking up from `.workspaces/<name>/`, so it
applies to every workspace and **not** to the main checkout,
which sits above it. Relative paths in this file resolve against
`.workspaces/`.

Do **not** run `kache init` for this — it rewrites
`$CARGO_HOME/config.toml` globally and installs a background
daemon. The config above needs neither.

Measured on a `regex` + `serde` project: 13.0s cold in the first
workspace, 4.47s in the second, 12/12 entries hit. With
*different* source per workspace, each still ran its own code.

Caveat to state when recommending it: kache is Apache-2.0 and
actively developed, but **pre-1.0 and young**. A rustc wrapper is
exactly where a bug becomes a silently-wrong binary, so treat it
as a considered bet rather than a safe default — which is part of
why Mode 1 is the fallback.

**Do not reach for `sccache` here.** It cannot share across
checkouts and no configuration changes that: its Rust hasher
deliberately hashes the cwd (*"The cwd of the compile. This will
wind up in the rlib."*), and `SCCACHE_BASEDIRS` — which looks
like precisely the fix — is implemented only for the C/C++ path,
so it logs `Using basedirs for path normalization: [...]` and
still returns zero cross-checkout hits.

### Never point two workspaces at one cargo build-dir

Whatever mode is chosen, do not "help" by setting `build-dir` or
`target-dir` to a shared location, and do not accept a request to
without flagging this. Two checkouts of one repo are the *same
unit* to cargo — same package name and version — so they share a
single artifact slot, and freshness is decided by mtime. The
workspace whose files are older is told `Finished`, compiles
nothing, and has its binary silently **replaced** with the other
workspace's code. It survives `cargo test` and `cargo run`
identically, so a workspace can test a sibling's binary and
report green.

Splitting `target-dir` does not help (the collision is in the
unit hash, which `build-dir` keys), and neither does the newer
build-dir layout. Upstream: [rust-lang/cargo#12516][12516], open,
"needs design".

[12516]: https://github.com/rust-lang/cargo/issues/12516

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

On the defaults recommended here that is the whole job: build
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
