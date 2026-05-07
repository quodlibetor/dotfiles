---
name: s3glob
description: Use when listing or downloading S3 objects with glob patterns (`s3glob ls`/`s3glob dl`). Faster alternative to `aws s3 ls`/`aws s3 cp --recursive` when the keyspace can be narrowed by globs. Includes parallelism tuning guidance for large keyspaces.
allowed-tools: Bash(s3glob *)
---

# s3glob

`s3glob` is a fast `aws s3 ls`/downloader that accepts unix-style glob patterns. Prefer it over `aws s3 ls ... | grep` or `aws s3 cp --recursive` when you can describe the keyspace with a glob — it parallelizes prefix listing and avoids scanning entire buckets.

Repo: <https://github.com/quodlibetor/s3glob>

## Pattern syntax

Pattern is either an `s3://` URI or `<bucket>/<glob>`:

- `s3://my-bucket/2024-12-*/data/*.json`
- `my-bucket/2024-12-*/data/*.json`

Glob characters:

- `*` — matches any chars within a single delimiter segment (default delimiter `/`)
- `**` — matches across delimiters (i.e. any depth)
- `?`, `[abc]`, `{a,b}` — standard glob constructs

s3glob enumerates prefixes through every non-`**` segment of the pattern via parallel `ListObjects` calls with the delimiter, then filters the resulting objects client-side. `**` is where prefix expansion stops — anything past `**` (or after the last segment that contains only single-`*`/literal globs) is matched by client-side filtering on the listed objects.

Quote the pattern (double quotes are usually fine, and let `$VAR` interpolate) — otherwise the shell may expand `*`/`?`/`{...}` against the cwd before s3glob sees them.

```bash
s3glob ls "my-bucket/2026-*/data.json"
s3glob ls "$BUCKET/2026-*/data.json"
```

## Credentials

Standard AWS SDK credential chain — no s3glob-specific config:

1. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (+ `AWS_SESSION_TOKEN`) env vars
2. `AWS_PROFILE` selecting a profile from `~/.aws/credentials` / `~/.aws/config` (incl. SSO profiles)
3. EC2/ECS/EKS instance or task role

For public buckets not tied to your account, pass `--no-sign-request` instead of fighting credentials.

## Subcommands

### `s3glob ls <PATTERN>` — list matching objects

Useful flags:

- `-f, --format <FMT>` — custom output format. Variables: `{kind}` (`OBJ`|`PRE`), `{key}`, `{bucket}`, `{uri}`, `{size_bytes}`, `{size_human}`, `{last_modified}` (RFC3339). Default: `"{last_modified} {size_human} {key}"`.
- `--stream` — stream keys as found instead of sorting/buffering until done. Use for very large result sets.

```bash
# just the URIs, streaming
s3glob ls -f '{uri}' --stream 'my-bucket/logs/2026-05-*/**/*.log'

# size + key, default sorted output
s3glob ls 'my-bucket/dumps/2026-*/snapshot.parquet'
```

### `s3glob dl <PATTERN> <DEST>` — download matching objects

Useful flags:

- `-p, --path-mode <MODE>` — how keys map to local paths. Values:
  - `from-first-glob` (`g`) — **default**; reproduce path starting at the first globbed segment
  - `absolute` (`abs`) — reproduce full key path under DEST
  - `shortest` (`s`) — strip longest common directory prefix
- `--flatten` — replace `/` with `-` in filenames; everything lands directly in DEST.

```bash
# default: paths relative to first glob
s3glob dl 'my-bucket/exports/2026-*/region=us/*.csv' ./out

# flatten into one dir
s3glob dl --flatten 'my-bucket/cve/*/data.json' ./cves
```

### `s3glob help parallelism` — print parallelism tuning doc

Run this if `s3glob` feels slow or you hit `SlowDown` errors.

## Parallelism — make it fast

s3glob parallelizes by enumerating prefixes for each `*` segment, multiplicatively. `**` halts prefix expansion (everything from the `**` onward becomes one bulk listing per prefix already generated).

Given keyspace `s3://bucket/{a-z}/{0-999}/OBJECT_ID.txt`, looking for `OBJECT_ID = 5`:

| Pattern                          | Parallelism |
| -------------------------------- | ----------- |
| `bucket/**/5.txt`                | 1           |
| `bucket/*/**/5.txt`              | 26          |
| `bucket/*/*/5.txt`               | 26,000      |

**Rule of thumb:** replace `**` with explicit `*/*/...` segments when you know the depth — each extra `*` segment multiplies prefix-listing concurrency.

## Common global flags

- `-M, --max-parallelism <N>` — cap concurrent requests (default `10000`). Lower it if you see `SlowDown` errors from S3.
- `-d, --delimiter <CHAR>` — non-`/` delimiter (rare).
- `-r, --region <REGION>` — starting region for auto-discovery (default `us-east-1`); usually unnecessary.
- `--no-sign-request` — anonymous request, for public buckets not tied to your account.
- `--force-path-style` — for S3-compatible servers (MinIO etc.) that don't support virtualhost-style addressing.
- `-v` / `-vv` / `-vvv` — debug / trace / trace-with-deps. Or set `S3GLOB_LOG` (rust-tracing `EnvFilter` syntax) for finer control.
- `-q` / `-qq` — suppress progress / errors. Overrides `-v`.

## When to reach for s3glob vs the AWS CLI

- Use `s3glob ls` when you'd otherwise pipe `aws s3 ls --recursive` into `grep` or run many `aws s3 ls` calls in a loop.
- Use `s3glob dl` when you'd otherwise loop over keys calling `aws s3 cp`, or when `aws s3 cp --recursive --exclude/--include` would download more than needed.
- Stick with `aws s3 cp` for a single known key if the aws cli is installed -- no glob, no benefit.
