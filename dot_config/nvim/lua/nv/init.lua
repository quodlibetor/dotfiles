--- nv: emacsclient-style sessions for nvim.
---
--- Server half. A project's session is a headless daemon -- `nvim --headless
--- --listen <socket>`, started on demand by the client -- that holds the
--- buffers, LSP clients and undo history. `nv` attaches a TUI to it in
--- whichever pane you are standing in, and leaving detaches instead of
--- quitting, so the session outlives the terminal. See `:h ui-lifecycle`.
---
--- One UI at a time: nvim has no frames, so every attached UI mirrors the same
--- screen. Attaching in a new pane therefore detaches the old pane's client --
--- and kills it, because a detached TUI freezes rather than exiting (it
--- ignores SIGTERM too).
local M = {}

local root_mod = require("nv.root")

local uv = vim.uv or vim.loop

--- Panes that have registered with us: token -> { token, pid, chan }
local panes = {}
--- Attached UIs: channel -> pane
local by_chan = {}
--- Token of the pane whose UI we are expecting next.
local pending = nil

M.root, M.reason = nil, nil

--- A pane is about to attach a UI. Called over RPC by the client.
function M.register(token)
  panes[token] = panes[token] or { token = token }
  pending = token
  return true
end

--- The wrapper reports the pid of the TUI it just started, so we can put the
--- pane out of its misery when its UI goes away.
function M.bind_client(token, pid)
  local pane = panes[token]
  if pane then
    pane.pid = tonumber(pid)
  end
  return true
end

--- Drop every attached UI. Each client's own pane cleans up after it.
function M.detach()
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    pcall(vim.fn.chanclose, ui.chan)
  end
end

local function on_ui_enter(chan)
  local pane = pending and panes[pending]
  pending = nil
  if pane then
    pane.chan = chan
    by_chan[chan] = pane
  end
  -- Exclusive UI: a second one would just mirror this screen at the smaller of
  -- the two sizes.
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.chan ~= chan then
      pcall(vim.fn.chanclose, ui.chan)
    end
  end
end

local function on_ui_leave(chan)
  local pane = by_chan[chan]
  by_chan[chan] = nil
  if not pane then
    return
  end
  panes[pane.token] = nil
  if pane.pid then
    pcall(uv.kill, pane.pid, "sigkill")
  end
end

--- Open files sent by a client.
---@param req { files: string[], line: integer?, col: integer?, wait: boolean?, token: string?, sentinel: string? }
---@return { pid: integer, root: string? }
function M.open(req)
  local files = req.files or {}
  local first = files[1]

  if first and req.wait then
    -- A blocking client (git/jj commit message, `crontab -e`, ...). Its own
    -- tab, and closing that tab is what tells the client we are done --
    -- `bufhidden=wipe` means :wq, :q and navigating away all release it.
    vim.cmd.tabedit(vim.fn.fnameescape(first))
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].bufhidden = "wipe"
    vim.b[buf].nv_wait = true
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload", "BufDelete" }, {
      buffer = buf,
      once = true,
      callback = function()
        local pane = req.token and panes[req.token]
        if pane and pane.chan then
          pcall(vim.fn.chanclose, pane.chan) -- hands the pane back to the shell
        end
        if req.sentinel then
          os.remove(req.sentinel) -- nested clients poll this instead
        end
      end,
    })
  else
    -- Extra files land in the buffer list; the first one gets the window.
    for i = #files, 2, -1 do
      local buf = vim.fn.bufadd(files[i])
      vim.bo[buf].buflisted = true
    end
    if first then
      vim.cmd.drop(vim.fn.fnameescape(first))
    end
  end

  if first and req.line then
    local line = math.max(1, math.min(req.line, vim.api.nvim_buf_line_count(0)))
    pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(0, (req.col or 1) - 1) })
    vim.cmd("normal! zz")
  end

  return { pid = uv.os_getpid(), root = M.root }
end

--- Is this the last window that :q could close, i.e. would the session end?
--- Floats don't count -- LazyVim's cmdline popup is one, and it must not make
--- a quit look survivable.
function M.last_window()
  if #vim.api.nvim_list_tabpages() > 1 then
    return false
  end
  local editing = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      editing = editing + 1
    end
  end
  return editing <= 1
end

function M.status()
  local attached = {}
  for chan, pane in pairs(by_chan) do
    attached[#attached + 1] = ("chan %d (client %s)"):format(chan, pane.pid or "unknown")
  end
  return table.concat({
    ("root:   %s (%s)"):format(M.root or "?", M.reason or "?"),
    ("socket: %s"):format(vim.v.servername),
    ("uis:    %d attached"):format(#vim.api.nvim_list_uis()),
    ("panes:  %s"):format(#attached > 0 and table.concat(attached, ",") or "none registered"),
  }, "\n")
end

function M.setup()
  -- Only daemons serve. A plain `nvim` is a plain nvim -- including one
  -- started from a :terminal inside a session, which inherits NV_DAEMON but
  -- listens on its own socket rather than the project's.
  if vim.env.NV_DAEMON ~= "1" or not vim.v.servername:find(root_mod.socket_dir(), 1, true) then
    return
  end
  -- Don't pass the marker on to terminals, LSP servers or anything else we
  -- spawn from here.
  vim.env.NV_DAEMON = nil

  M.root, M.reason = root_mod.detect(uv.cwd())

  local group = vim.api.nvim_create_augroup("nv", { clear = true })

  vim.api.nvim_create_autocmd("UIEnter", {
    group = group,
    callback = function(ev)
      on_ui_enter(ev.data and ev.data.chan or vim.v.event.chan)
    end,
  })

  vim.api.nvim_create_autocmd("UILeave", {
    group = group,
    callback = function(ev)
      on_ui_leave(ev.data and ev.data.chan or vim.v.event.chan)
    end,
  })

  -- :q would take the whole session with it. Give the pending quit a scratch
  -- window to close instead, then let go of the UI. :qa is left alone, so
  -- "quit all" really does end the session.
  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      if not M.last_window() then
        return
      end
      vim.cmd("new")
      vim.schedule(function()
        M.detach()
      end)
    end,
  })

  vim.api.nvim_create_user_command("NvStatus", function()
    vim.notify(M.status(), vim.log.levels.INFO)
  end, { desc = "nv: show this session's root, socket and UIs" })

  vim.api.nvim_create_user_command("NvQuit", function()
    vim.cmd("qa")
  end, { desc = "nv: end this project's session" })
end

return M
