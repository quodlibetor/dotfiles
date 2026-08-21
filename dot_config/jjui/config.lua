-- Override copy_to_clipboard to use wezterm OSC user-var for remote clipboard
-- support. Works with the BWM_COPY_TEXT handler in wezterm.lua.
local _builtin_copy = copy_to_clipboard

-- base64 encode in pure lua (no io.popen needed)
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64_encode(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    b = b or 0
    c = c or 0
    local n = a * 65536 + b * 256 + c
    local rem = #data - i + 1
    out[#out + 1] = b64chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
    out[#out + 1] = b64chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
    out[#out + 1] = rem >= 2 and b64chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
    out[#out + 1] = rem >= 3 and b64chars:sub(n % 64 + 1, n % 64 + 1) or "="
  end
  return table.concat(out)
end

copy_to_clipboard = function(text)
  if text == nil or text == "" then
    return nil, "nothing to copy"
  end
  local encoded = base64_encode(text)
  -- Write OSC 1337 SetUserVar directly to /dev/tty. The escape sequence is
  -- invisible (consumed by wezterm, not rendered) so it won't disturb the TUI.
  local tty = io.open("/dev/tty", "w")
  if tty then
    tty:write("\027]1337;SetUserVar=BWM_COPY_TEXT=" .. encoded .. "\007")
    tty:flush()
    tty:close()
    return true, nil
  end
  if _builtin_copy then
    return _builtin_copy(text)
  end
  return nil, "copy failed"
end

-- $EDITOR-with-fallbacks, resolved by the shell exec_shell() runs the line in.
local EDITOR = "${EDITOR:-${VISUAL:-vi}}"

-- Files the details view is pointing at: everything checked if anything is,
-- otherwise just the highlighted one. Paths are relative to the workspace
-- root, which is also the cwd exec_shell() and jj() run in.
local function selected_files()
  local checked = context.checked_files()
  if checked and #checked > 0 then
    return checked
  end
  local file = context.file()
  if file and file ~= "" then
    return { file }
  end
  return {}
end

-- Quote a path for the single command line exec_shell() hands to `$SHELL -c`.
local function shquote(text)
  local escaped = tostring(text):gsub("'", "'\\''")
  return "'" .. escaped .. "'"
end

-- A jj fileset matching exactly one path, escaped the way jjui escapes the
-- file names it passes to jj itself.
local function fileset(file)
  local escaped = file:gsub("\\", "\\\\"):gsub('"', '\\"')
  return 'file:"' .. escaped .. '"'
end

local function is_working_copy(change_id)
  if not change_id or change_id == "" then
    return false
  end
  local out = jj("log", "-r", "(" .. change_id .. ") & @", "--no-graph", "--ignore-working-copy", "-T", '"x"')
  return out ~= nil and out ~= ""
end

local function copy_paths(paths, what)
  if #paths == 0 then
    flash({ text = "No file selected", error = true })
    return
  end
  copy_to_clipboard(table.concat(paths, "\n"))
  if #paths == 1 then
    flash("Copied: " .. paths[1])
  else
    flash("Copied " .. #paths .. " " .. what)
  end
end

-- Trailer keys (normalized to lowercase, single-space) whose value is a URL
-- worth opening in a browser.
local URL_TRAILER_KEYS = {
  ["pull request"] = true,
}

-- URLs from `Key: URL` trailer lines whose key is in URL_TRAILER_KEYS, in the
-- order they appear, deduplicated. jj keeps trailers as ordinary description
-- lines, so this is a scan rather than anything jj can query for us.
local function trailer_urls(description)
  local urls, seen = {}, {}
  for _, line in ipairs(split_lines(description)) do
    local key, value = line:match("^%s*(%a[%w%s_-]*):%s*(%S+)%s*$")
    if key then
      key = key:lower():gsub("[%s_-]+", " ")
    end
    if key and URL_TRAILER_KEYS[key] and value:match("^https?://") and not seen[value] then
      seen[value] = true
      urls[#urls + 1] = value
    end
  end
  return urls
end

-- Hand a URL to $BROWSER without disturbing the TUI: detached, so jjui isn't
-- blocked waiting on it; stdout kept on the terminal, because $BROWSER may be a
-- shim that talks to the terminal emulator rather than opening a window itself
-- (weztermopen writes an OSC escape, invisible here just like the clipboard one
-- above); stderr dropped, so a chatty browser can't garble the UI.
local function open_url(url)
  local browser = os.getenv("BROWSER")
  if not browser or browser == "" then
    browser = "xdg-open %s 2>/dev/null || open %s"
  end
  local quoted = shquote(url)
  local line
  if browser:find("%%s") then
    -- freedesktop convention: %s is where the URL goes.
    line = (browser:gsub("%%s", function()
      return quoted
    end))
  else
    line = browser .. " " .. quoted
  end
  os.execute("({ " .. line .. " ; } >/dev/tty 2>/dev/null &)")
end

function setup(config)
  config.action("copy-change-id", function()
    local short_id = context.change_id()
    if short_id and short_id ~= "" then
      local full_id, err = jj("log", "-r", short_id, "--no-graph", "-T", "change_id")
      if not full_id or full_id == "" then
        flash({ text = "Failed to get change id: " .. (err or "unknown"), error = true })
        return
      end
      local id = full_id:sub(1, 8)
      copy_to_clipboard(id)
      flash("Copied: " .. id)
    else
      flash({ text = "No change id", error = true })
    end
  end, {
    key = "Y",
    scope = "revisions",
    desc = "copy change id",
  })

  config.action("copy-file-path", function()
    copy_paths(selected_files(), "paths")
  end, {
    key = "y",
    scope = "revisions.details",
    desc = "copy file path",
  })

  config.action("copy-file-abs-path", function()
    local files = selected_files()
    if #files == 0 then
      flash({ text = "No file selected", error = true })
      return
    end
    local root, err = jj("root")
    if not root or root == "" then
      flash({ text = "Failed to find workspace root: " .. (err or "unknown"), error = true })
      return
    end
    root = root:gsub("%s+$", "")
    local paths = {}
    for i, file in ipairs(files) do
      paths[i] = root .. "/" .. file
    end
    copy_paths(paths, "absolute paths")
  end, {
    key = "Y",
    scope = "revisions.details",
    desc = "copy absolute file path",
  })

  config.action("edit-file", function()
    local file = context.file()
    if not file or file == "" then
      flash({ text = "No file selected", error = true })
      return
    end
    local change_id = context.change_id()
    -- Only the working copy has the file on disk to edit in place.
    if is_working_copy(change_id) then
      exec_shell(EDITOR .. " " .. shquote(file))
      return
    end
    local checkout = "jj edit " .. change_id .. ", then edit the file"
    local readonly = "open this version read-only"
    local choice = choose({
      title = change_id .. " is not the working copy",
      options = { checkout, readonly },
      ordered = true,
    })
    if choice == checkout then
      jj_async("edit", "-r", change_id)
      exec_shell(EDITOR .. " " .. shquote(file))
    elseif choice == readonly then
      -- Snapshot the file as it is in that revision and open the copy
      -- write-protected, so a stray :w can't look like it landed anywhere.
      local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/jjui-" .. change_id .. "-" .. file:match("[^/]+$")
      exec_shell(table.concat({
        "rm -f " .. shquote(tmp),
        "jj file show -r " .. shquote(change_id) .. " " .. shquote(fileset(file)) .. " >" .. shquote(tmp),
        "chmod a-w " .. shquote(tmp),
        EDITOR .. " " .. shquote(tmp),
      }, " && "))
    end
  end, {
    -- alt+e is what file_search binds edit to; e is free here because the
    -- details view doesn't inherit revisions.edit.
    key = { "e", "alt+e" },
    scope = "revisions.details",
    desc = "edit file in $EDITOR",
  })

  config.action("open-pull-request", function()
    local change_id = context.change_id()
    if not change_id or change_id == "" then
      flash({ text = "No change selected", error = true })
      return
    end
    local description, err = jj("log", "-r", change_id, "--no-graph", "--ignore-working-copy", "-T", "description")
    if not description then
      flash({ text = "Failed to read description: " .. (err or "unknown"), error = true })
      return
    end
    local urls = trailer_urls(description)
    if #urls == 0 then
      -- change_id here is the shortest unique prefix, too terse to name in a
      -- message; the highlighted row is the change anyway.
      flash({ text = "No pull request trailer in this change", error = true })
      return
    end
    local url = urls[1]
    if #urls > 1 then
      url = choose({ title = "Which URL?", options = urls, ordered = true })
      if not url then
        return
      end
    end
    open_url(url)
    flash("Opening " .. url)
  end, {
    key = "O",
    scope = "revisions",
    desc = "open pull request in $BROWSER",
  })
end
