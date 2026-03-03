# Source this file to define the jjcd function.
# Usage: jjcd [workspace-name]
#   No argument: pick a workspace with fzf
#   With argument: cd to that workspace, or fall back to fzf on error

__jjcd_pick() {
  local items count height
  items=$(jj workspace list --template '
self.name() ++ ": " ++
self.target().change_id().shortest(4) ++ " " ++
self.target().commit_id().shortest(4) ++ " " ++
if(self.target().empty(), "(empty) ", "") ++
coalesce(
  self.target().bookmarks().map(|b| b.name()).join(","),
  self.target().parents().map(|p| p.bookmarks().map(|b| b.name()).join(",")).join(" "),
  self.target().parents().map(|p| p.parents().map(|g| g.bookmarks().map(|b| b.name()).join(",")).join(" ")).join(" "),
  "(no bookmark)"
) ++ " | " ++
coalesce(
  self.target().description().first_line(),
  self.target().parents().map(|p| coalesce(p.description().first_line(), p.parents().map(|g| g.description().first_line()).join("; "))).join("; "),
  "(no description)"
) ++ "\n"
')
  count=$(echo "$items" | wc -l)
  height=$(( count < 10 ? count +2 : 12 ))
  echo "$items" | fzf --prompt="workspace> " --height=$height | awk -F': ' '{print $1}'
}

jjcd() {
  local workspace_name="$1"
  local workspace_dir

  if [[ -n "$workspace_name" ]]; then
    workspace_dir=$(jj workspace root --name "$workspace_name" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
      jj workspace root --name "$workspace_name" >/dev/null  # replay to emit the error
      workspace_name=$(__jjcd_pick) || return 0
      [[ -z "$workspace_name" ]] && return 0
      workspace_dir=$(jj workspace root --name "$workspace_name")
    fi
  else
    workspace_name=$(__jjcd_pick) || return 0
    [[ -z "$workspace_name" ]] && return 0
    workspace_dir=$(jj workspace root --name "$workspace_name")
  fi

  [[ -n "$workspace_dir" ]] && cd "$workspace_dir"
}
