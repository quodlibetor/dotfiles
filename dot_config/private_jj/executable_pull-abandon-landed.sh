#!/usr/bin/env bash
# Called by `jj pull` after fetching. Abandons local copies of PRs that the
# merge queue has already squash-landed on main: matched by the local
# `Pull Request: .../pull/N` trailer against a `(#N)` subject on main.
#
# Commits are judged per run (a connected group of landed-PR commits), not one
# at a time: a stack that lands in a different order rebases into per-commit
# diffs that don't match the squashes (add/add conflicts that a later commit
# resolves), yet the run as a whole adds nothing. A run is abandoned only when
# every head of it matches the newest of its landed squashes on every file the
# run touches, so a post-landing edit keeps the whole run.
#
# Usage: pull-abandon-landed.sh SKIP_REVSET [--dry-run]
set -euo pipefail
skip=$1
dry_run=${2:-}

landed_window='committer_date(after:"60 days ago")'
declare -A landed=() # PR number -> commit id on main
while read -r cid subject; do
  [[ $subject =~ \(#([0-9]+)\)$ ]] && landed[${BASH_REMATCH[1]}]=$cid
done < <(jj log --no-graph -r "::main@origin & $landed_window" \
  -T 'commit_id ++ " " ++ description.first_line() ++ "\n"')

cands="((mine() ~ ::main@origin) & mutable() & description(regex:'(?m)^Pull Request: ')) ~ ($skip)::"
declare -A pr_of=() # local commit id -> PR number
while read -r cid url; do
  [[ $url =~ /pull/([0-9]+)$ ]] || continue
  [[ -n ${landed[${BASH_REMATCH[1]}]:-} ]] && pr_of[$cid]=${BASH_REMATCH[1]}
done < <(jj log --no-graph -r "$cands" \
  -T 'commit_id ++ " " ++ description.lines().filter(|l| l.starts_with("Pull Request: ")).map(|l| l.remove_prefix("Pull Request: ")).join(" ") ++ "\n"')

((${#pr_of[@]})) || exit 0
all_set=$(printf '%s|' "${!pr_of[@]}"); all_set="(${all_set%|})"

to_abandon=()
remaining=$all_set
while :; do
  seed=$(jj log --no-graph -r "latest($remaining)" -T commit_id)
  [[ -n $seed ]] || break
  run=$(jj log --no-graph -r "reachable($seed, $all_set)" -T 'commit_id ++ "\n"')
  run_set=$(tr '\n' '|' <<<"$run"); run_set="(${run_set%|})"
  remaining="$remaining ~ $run_set"

  landed_set=$(for c in $run; do printf '%s|' "${landed[${pr_of[$c]}]}"; done)
  # heads(), not latest(): a queue batch lands with identical committer times.
  newest=$(jj log --no-graph -r "heads(${landed_set%|})" -T 'commit_id ++ "\n"' | head -1)
  touched=$(for c in $run; do jj diff -r "$c" --name-only; done | sort -u)
  ok=1
  for head in $(jj log --no-graph -r "heads($run_set)" -T 'commit_id ++ "\n"'); do
    differs=$(comm -12 <(jj diff --from "$newest" --to "$head" --name-only | sort -u) <(echo "$touched"))
    if [[ -n $differs ]]; then
      ok=0
      echo "pull: keeping landed run at ${head:0:12}, it differs from main in:" >&2
      sed 's/^/pull:   /' <<<"$differs" >&2
    fi
  done
  ((ok)) && to_abandon+=($run)
done

((${#to_abandon[@]})) || exit 0
echo "pull: abandoning local copies of landed PRs:"
for c in "${to_abandon[@]}"; do
  jj log --no-graph -r "$c" -T '"pull:   " ++ change_id.short() ++ " #'"${pr_of[$c]}"' " ++ description.first_line() ++ "\n"'
done
if [[ $dry_run == --dry-run ]]; then
  echo "pull: (dry run, nothing abandoned)"
else
  jj abandon --retain-bookmarks $(printf -- '-r %s ' "${to_abandon[@]}")
fi
