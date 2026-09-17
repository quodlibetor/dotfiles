-- Workspace commands for the revisions view, under the `w` prefix.
--
-- Each acts on the workspace whose working copy is the highlighted change, so
-- `w d` on a `name@` row deletes that workspace. On any other row they fall
-- back to a picker over every workspace in the repo.
--
-- Workspaces share a change once one of them is squashed into another, so a
-- row can name several. `w d` then offers them one at a time or together,
-- leaving out the workspace holding the repo and the one jjui is in.
--
-- jjui cannot cd its parent shell, so `w s` and `w c` write their destination
-- to $JJUI_CD_FILE and the `jjj` shell function moves there once jjui exits.

local M = {}

-- Quote a path for the `sh -c` line os.execute() runs.
local function shquote(text)
  return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

-- Collapse `.` and `..` in an absolute path. The repo directory is only
-- reachable as a relative pointer (see repo_root), and jj's -R rejects a path
-- that still contains them.
local function normalize(path)
  local parts = {}
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then
      table.remove(parts)
    elseif segment ~= "." then
      parts[#parts + 1] = segment
    end
  end
  return "/" .. table.concat(parts, "/")
end

-- The workspace holding the repo: "default", unless it has been renamed. It is
-- never something to delete, and older repos record no path for it, so find it
-- from jjui's own workspace, where .jj/repo is either the repo directory
-- itself or a file pointing at the workspace that has it.
local function repo_root()
  local here, err = jj("root")
  if not here or here == "" then
    return nil, "Failed to find workspace root: " .. (err or "unknown")
  end
  here = here:gsub("%s+$", "")
  local store = io.open(here .. "/.jj/repo/store/type", "r")
  if store then
    store:close()
    return here, nil
  end
  local pointer = io.open(here .. "/.jj/repo", "r")
  local target = pointer and pointer:read("*a")
  if pointer then
    pointer:close()
  end
  if not target or target == "" then
    return nil, "Cannot find the workspace holding the repo"
  end
  -- The pointer is relative to the .jj directory holding it, not to the
  -- workspace root.
  target = target:gsub("%s+$", "")
  if target:sub(1, 1) ~= "/" then
    target = here .. "/.jj/" .. target
  end
  return (normalize(target):gsub("/%.jj/repo$", "")), nil
end

local LIST_TEMPLATE = table.concat({
  "self.name()",
  '"\t"',
  "root",
  '"\t"',
  "self.target().change_id().short(12)",
  '"\t"',
  -- A workspace's working copy is usually an empty change on top of the work,
  -- so fall back through its ancestors the way jjcd's picker does.
  table.concat({
    "coalesce(",
    "self.target().description().first_line(),",
    'self.target().parents().map(|p| coalesce(p.description().first_line(),',
    'p.parents().map(|g| g.description().first_line()).join("; "))).join("; "),',
    '"(no description)")',
  }, " "),
  '"\n"',
}, " ++ ")

-- Every workspace in the repo, each marked with whether it holds the repo and
-- whether it is the one jjui is in. Both are decided by path: a working copy
-- commit says nothing about which workspace it belongs to, and several
-- workspaces sitting on one commit is exactly the case `w d` has to get right.
local function workspaces()
  local out, err = jj("workspace", "list", "--ignore-working-copy", "-T", LIST_TEMPLATE)
  if not out then
    flash({ text = "Failed to list workspaces: " .. (err or "unknown"), error = true })
    return nil
  end
  local here = jj("root")
  here = here and here:gsub("%s+$", "") or ""
  local holder, holder_err = repo_root()
  local list = {}
  for _, line in ipairs(split_lines(out)) do
    local name, root, change_id, desc = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if name and name ~= "" then
      -- jj leaves the root empty for a workspace it has no recorded path for,
      -- which in older repos is the one holding the repo.
      if root == "" then
        root = holder or ""
      end
      list[#list + 1] = {
        name = name,
        root = root,
        change_id = change_id,
        desc = desc,
        current = root ~= "" and root == here,
        holder = root ~= "" and root == holder,
      }
    end
  end
  if #list == 0 then
    flash({ text = "No workspaces found", error = true })
    return nil
  end
  return list, holder_err
end

-- The workspaces whose working copy is the highlighted change. More than one
-- lands on a single change whenever a workspace's own change is squashed
-- elsewhere, which leaves it sharing that commit.
local function workspaces_at_cursor(list)
  local found = {}
  local short = context.change_id()
  if not short or short == "" then
    return found
  end
  local full = jj("log", "-r", short, "--no-graph", "--ignore-working-copy", "-T", "change_id")
  if not full or full == "" then
    return found
  end
  full = full:gsub("%s+$", "")
  for _, ws in ipairs(list) do
    if ws.change_id ~= "" and full:sub(1, #ws.change_id) == ws.change_id then
      found[#found + 1] = ws
    end
  end
  return found
end

local function pick(list, title)
  local labels, by_label = {}, {}
  for _, ws in ipairs(list) do
    local label = ws.name .. "  " .. ws.desc
    if ws.current then
      label = label .. "  (current)"
    end
    labels[#labels + 1] = label
    by_label[label] = ws
  end
  local choice = choose({ title = title, options = labels, ordered = true })
  if not choice then
    return nil
  end
  return by_label[choice]
end

-- The workspace to act on: the one under the cursor, else whatever the user
-- picks out of the ones that share the change or, with none there, out of the
-- whole repo.
local function target(title)
  local list = workspaces()
  if not list then
    return nil
  end
  local found = workspaces_at_cursor(list)
  local ws
  if #found == 1 then
    ws = found[1]
  else
    ws = pick(#found > 1 and found or list, title)
  end
  if not ws then
    return nil
  end
  if ws.root == "" then
    flash({ text = "Workspace " .. ws.name .. " has no recorded path", error = true })
    return nil
  end
  return ws
end

-- Leave the destination for the `jjj` shell function to cd to on exit.
local function record_cd(path)
  local file = os.getenv("JJUI_CD_FILE")
  if not file or file == "" then
    return false, "JJUI_CD_FILE unset: start jjui as jjj to have the shell follow"
  end
  local handle = io.open(file, "w")
  if not handle then
    return false, "Cannot write " .. file
  end
  handle:write(path .. "\n")
  handle:close()
  return true, nil
end

-- Snapshot a workspace's working copy so nothing on disk is lost with the
-- directory. A stale working copy fails this, and update-stale is what
-- unsticks it.
local function snapshot(root)
  local _, err = jj("status", "-R", root)
  if not err then
    return true, nil
  end
  local _, stale_err = jj("workspace", "update-stale", "-R", root)
  if stale_err then
    return false, stale_err
  end
  local _, retry_err = jj("status", "-R", root)
  if retry_err then
    return false, retry_err
  end
  return true, nil
end

-- The workspaces `w d` may act on: never the one holding the repo, never the
-- one jjui is in.
local function deletable(list)
  local kept = {}
  for _, ws in ipairs(list) do
    if ws.root ~= "" and not ws.holder and not ws.current then
      kept[#kept + 1] = ws
    end
  end
  return kept
end

-- Which of the workspaces sharing the highlighted change to delete: one of
-- them, or all.
local function narrow(found)
  local labels, by_label, names = {}, {}, {}
  for i, ws in ipairs(found) do
    local label = "only " .. ws.name .. "  " .. ws.desc
    labels[i] = label
    by_label[label] = { ws }
    names[i] = ws.name
  end
  local all = "all of them: " .. table.concat(names, ", ")
  labels[#labels + 1] = all
  by_label[all] = found
  local choice = choose({ title = "Workspaces on this change", options = labels, ordered = true })
  if not choice then
    return nil
  end
  return by_label[choice]
end

local function remove(ws)
  local _, forget_err = jj("workspace", "forget", ws.name)
  if forget_err then
    return false, "Failed to forget " .. ws.name .. ": " .. forget_err
  end
  if os.execute("rm -rf -- " .. shquote(ws.root) .. " >/dev/null 2>&1") ~= 0 then
    return false, "Forgot " .. ws.name .. " but could not remove " .. ws.root
  end
  return true, nil
end

function M.setup(config)
  config.action("workspace-switch", function()
    local ws = target("Switch to workspace")
    if not ws then
      return
    end
    local ok, err = change_workspace(ws.root)
    if not ok then
      flash({ text = "Failed to switch: " .. (err or "unknown"), error = true })
      return
    end
    revisions.refresh()
    local recorded, cd_err = record_cd(ws.root)
    if not recorded then
      flash({ text = ws.name .. ": " .. cd_err, error = true })
      return
    end
    flash("Workspace: " .. ws.name)
  end, {
    seq = { "w", "s" },
    scope = "revisions",
    desc = "switch to workspace (shell follows on exit)",
  })

  config.action("workspace-cd", function()
    local ws = target("Quit into workspace")
    if not ws then
      return
    end
    local recorded, err = record_cd(ws.root)
    if not recorded then
      flash({ text = err, error = true })
      return
    end
    jjui.ui.quit()
  end, {
    seq = { "w", "c" },
    scope = "revisions",
    desc = "quit jjui and cd to workspace",
  })

  config.action("workspace-delete", function()
    local list, holder_err = workspaces()
    if not list then
      return
    end
    -- Without knowing which workspace holds the repo there is no way to keep
    -- it out of the set, so nothing gets deleted.
    if holder_err then
      flash({ text = holder_err, error = true })
      return
    end
    list = deletable(list)
    if #list == 0 then
      flash({ text = "No workspace here can be deleted", error = true })
      return
    end
    local found = workspaces_at_cursor(list)
    if #found == 0 then
      local ws = pick(list, "Delete workspace")
      found = ws and { ws } or nil
    elseif #found > 1 then
      found = narrow(found)
    end
    if not found then
      return
    end

    -- Snapshot them all before removing any: a workspace that cannot be
    -- snapshotted stops the whole delete rather than losing what it holds.
    for _, ws in ipairs(found) do
      local safe, err = snapshot(ws.root)
      if not safe then
        flash({ text = "Not deleting " .. ws.name .. ": " .. err, error = true })
        return
      end
    end

    local title, delete
    if #found == 1 then
      local summary = jj("log", "-R", found[1].root, "--ignore-working-copy", "-r", "@", "--no-graph", "-T",
        'if(empty, "(empty) ", "") ++ coalesce(description.first_line(), "(no description)")')
      title = found[1].name .. " @ " .. (summary or "")
      delete = "forget and rm -rf " .. found[1].root
    else
      local names = {}
      for i, ws in ipairs(found) do
        names[i] = ws.name
      end
      title = "Workspaces on this change: " .. table.concat(names, ", ")
      delete = "forget and rm -rf every one of them"
    end
    if choose({ title = title, options = { delete, "cancel" }, ordered = true }) ~= delete then
      return
    end

    local deleted = {}
    for _, ws in ipairs(found) do
      local ok, err = remove(ws)
      if not ok then
        revisions.refresh()
        flash({ text = err, error = true })
        return
      end
      deleted[#deleted + 1] = ws.name
    end
    revisions.refresh()
    flash("Deleted " .. table.concat(deleted, ", "))
  end, {
    seq = { "w", "d" },
    scope = "revisions",
    desc = "delete workspace",
  })
end

return M
