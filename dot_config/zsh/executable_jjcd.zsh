# Source this file to define the jjcd function.
# Usage: jjcd [workspace-name]
#   No argument: pick a workspace with fzf
#   With argument: cd to that workspace, or fall back to fzf on error

__jjcd_pick() {
  local items count height
  items=$(jj workspace list)
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
