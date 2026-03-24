# Source this file to define the jjcd function.
# Usage: jjcd [workspace-name]
#   No argument: pick a workspace with fzf
#   With argument: cd to that workspace, or fall back to fzf on error

__jjcd_jj() {
  jj --ignore-working-copy "$@"
}

__jjcd_pick() {
  local items count height current_change list_template preview_template delete_bind

  list_template=$(cat <<'EOF'
self.name() ++ ": " ++
coalesce(
  self.target().bookmarks().map(|b| b.name()).join(","),
  self.target().parents().map(|p| p.bookmarks().map(|b| b.name()).join(",")).join(" "),
  self.target().parents().map(|p| p.parents().map(|g| g.bookmarks().map(|b| b.name()).join(",")).join(" ")).join(" "),
  "🔖"
) ++ " | " ++
coalesce(
  self.target().description().first_line(),
  self.target().parents().map(|p| coalesce(p.description().first_line(), p.parents().map(|g| g.description().first_line()).join("; "))).join("; "),
  "(no description)"
) ++ "\n"
EOF
)
  export __JJCD_LIST_TEMPLATE="$list_template"

  current_change=$(__jjcd_jj log -r @ --no-graph --template 'change_id')
  preview_template=$(cat <<EOF
name=\$(awk -F": " '{print \$1}' <<< {})
root=\$(jj --ignore-working-copy workspace root --name "\$name")
if [[ -n "\$root" ]]; then
  jj --ignore-working-copy -R "\$root" log -r "trunk()..@ | ${current_change}..@ | @" -n 5 --no-pager --color=always
fi
EOF
)

  # Quoted heredoc: $__JJCD_LIST_TEMPLATE is not expanded by zsh here; it
  # will be expanded by sh when fzf runs the reload command.
  delete_bind=$(cat <<'EOF'
ctrl-d:execute(
  name=$(printf "%s" {} | cut -d: -f1)
  root=$(jj --ignore-working-copy workspace root --name "$name" 2>/dev/null)
  if [ -z "$root" ]; then
    printf "Error: could not find root for workspace \"%s\"\n" "$name" >&2
  else
    printf "Forget workspace \"%s\" and delete \"%s\"? [y/N] " "$name" "$root"
    read -r confirm < /dev/tty
    case "$confirm" in
      [Yy]*) jj --ignore-working-copy workspace forget "$name" && rm -rf "$root" ;;
    esac
  fi
)+reload(jj --ignore-working-copy workspace list --template "$__JJCD_LIST_TEMPLATE")
EOF
)

  items=$(__jjcd_jj workspace list --template "$list_template")
  count=$(echo "$items" | wc -l)
  height=$(( count < 8 ? count + 4 : 12 ))
  echo "$items" | fzf \
    --prompt="workspace [ctrl-d: delete]> " \
    --height=$height \
    --preview="$preview_template" \
    --preview-window='right:55%:wrap' \
    --bind "$delete_bind" \
    | awk -F': ' '{print $1}'
}

jjcd() {
  local workspace_name="$1"
  local workspace_dir

  if [[ -n "$workspace_name" ]]; then
    workspace_dir=$(__jjcd_jj workspace root --name "$workspace_name" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
      __jjcd_jj workspace root --name "$workspace_name" >/dev/null  # replay to emit the error
      workspace_name=$(__jjcd_pick) || return 0
      [[ -z "$workspace_name" ]] && return 0
      workspace_dir=$(__jjcd_jj workspace root --name "$workspace_name")
    fi
  else
    workspace_name=$(__jjcd_pick) || return 0
    [[ -z "$workspace_name" ]] && return 0
    workspace_dir=$(__jjcd_jj workspace root --name "$workspace_name")
  fi

  [[ -n "$workspace_dir" ]] && cd "$workspace_dir"
}
