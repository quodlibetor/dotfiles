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
  if text == nil or text == "" then return nil, "nothing to copy" end
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
  if _builtin_copy then return _builtin_copy(text) end
  return nil, "copy failed"
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
end
