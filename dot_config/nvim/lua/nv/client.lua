--- nv: emacsclient-style sessions for nvim.
---
--- Client half, run as a script: `nvim -u NONE -l .../nv/client.lua -- ARGS`.
--- nvim starts in ~30ms with `-l` and gives us `vim.fs`, real msgpack-RPC and
--- job control for free, so the wrapper in ~/.local/bin/nv stays a few lines of
--- shell and there is no quoting to get wrong.
---
--- We find (or start) the project's daemon, hand it the files, and tell the
--- wrapper to attach a TUI to it. Contract with the wrapper:
---   exit 0  -- finished here (nested session, --where, --kill)
---   exit 10 -- no session possible; stdout holds the argv (one per line) the
---              wrapper should exec a plain nvim with
---   exit 11 -- attach: stdout holds the socket and this pane's token
local uv = vim.uv or vim.loop
local root_mod = require("nv.root")

local EXIT_LOCAL, EXIT_ATTACH = 10, 11

local function note(msg)
  io.stderr:write("nv: " .. msg .. "\n")
end

local function abspath(path)
  path = vim.fs.normalize(path)
  if path:sub(1, 1) ~= "/" then
    path = vim.fs.normalize(uv.cwd() .. "/" .. path)
  end
  return path
end

local files, line, col = {}, nil, nil

local dropped_separator = false
for _, a in ipairs(_G.arg) do
  if a == "--" and not dropped_separator then
    dropped_separator = true
  elseif a:match("^%+%d+$") then
    line = tonumber(a:sub(2))
  else
    files[#files + 1] = a
  end
end

-- `file:12:3` as pasted out of grep/rg output, but only when that isn't
-- itself a filename.
if files[1] and not uv.fs_stat(files[1]) then
  local base, l, c = files[1]:match("^(.+):(%d+):(%d+):?$")
  if not base then
    base, l = files[1]:match("^(.+):(%d+):?$")
  end
  if base and uv.fs_stat(base) then
    files[1], line, col = base, line or tonumber(l), col or tonumber(c)
  end
end

for i, file in ipairs(files) do
  files[i] = abspath(file)
end

--- No session to talk to: hand the resolved argv back to the wrapper.
local function run_locally()
  local argv = {}
  if line then
    argv[#argv + 1] = "+" .. line
  end
  vim.list_extend(argv, files)
  io.stdout:write(table.concat(argv, "\n"))
  os.exit(EXIT_LOCAL)
end

-- Which project is this?
local start = uv.cwd()
if files[1] then
  local stat = uv.fs_stat(files[1])
  start = (stat and stat.type == "directory") and files[1] or vim.fs.dirname(files[1])
end

local nested = vim.env.NVIM and vim.env.NVIM ~= ""
local sock, root, reason
if nested then
  -- We are a :terminal inside nvim. That nvim is the session, whatever the
  -- project says, and we cannot attach a second UI to our own terminal.
  sock, reason = vim.env.NVIM, "$NVIM"
else
  root, reason = root_mod.detect(start)
  -- A file that belongs to no project at all -- jj writes its description to
  -- $TMPDIR, `crontab -e` and friends do the same -- still belongs to whatever
  -- we are standing in.
  if reason == "cwd" and start ~= uv.cwd() then
    local cwd_root, cwd_reason = root_mod.detect(uv.cwd())
    if cwd_reason ~= "cwd" then
      root, reason = cwd_root, cwd_reason
    end
  end
  local ok, path = pcall(root_mod.socket, root)
  if not ok then
    note(tostring(path))
    run_locally()
  end
  sock = path
end

local function connect()
  if not uv.fs_stat(sock) then
    return nil
  end
  local ok, chan = pcall(vim.fn.sockconnect, "pipe", sock, { rpc = true })
  if ok and chan and chan > 0 then
    return chan
  end
  if not nested then
    os.remove(sock) -- a crashed daemon left it behind
  end
  return nil
end

local chan = connect()

if vim.env.NV_WHERE == "1" then
  io.stdout:write(
    ("root:   %s (%s)\nsocket: %s\nstate:  %s\n"):format(
      root or "-",
      reason,
      sock,
      chan and "session running" or "no session"
    )
  )
  os.exit(0)
end

if vim.env.NV_LIST == "1" then
  local dir = root_mod.socket_dir()
  local rows = {}
  for name in vim.fs.dir(dir) do
    if name:match("%.sock$") then
      local path = dir .. "/" .. name
      local ok, handle = pcall(vim.fn.sockconnect, "pipe", path, { rpc = true })
      if ok and handle and handle > 0 then
        local got, info = pcall(
          vim.rpcrequest,
          handle,
          "nvim_exec_lua",
          [[
          return { root = require("nv").root, pid = vim.uv.os_getpid(), uis = #vim.api.nvim_list_uis() }
        ]],
          {}
        )
        if got then
          rows[#rows + 1] = ("%-45s pid %-7d %s"):format(
            info.root or path,
            info.pid,
            info.uis > 0 and "attached" or "detached"
          )
        end
      else
        os.remove(path) -- a crashed session
      end
    end
  end
  table.sort(rows)
  io.stdout:write(#rows > 0 and (table.concat(rows, "\n") .. "\n") or "no sessions running\n")
  os.exit(0)
end

if vim.env.NV_KILL == "1" then
  if not chan then
    note("no session for " .. (root or sock))
    os.exit(0)
  end
  -- A notification, not a request: a session that obeys never answers, it
  -- just exits and drops the channel.
  vim.rpcnotify(chan, "nvim_command", "qa")
  local deadline = uv.hrtime() + 5e9
  while uv.hrtime() < deadline do
    uv.sleep(100)
    if not connect() then
      note("session ended: " .. (root or sock))
      os.exit(0)
    end
  end
  note("session is still running -- unsaved changes? (:qa! in it, or kill " .. tostring(root) .. "'s nvim)")
  os.exit(1)
end

--- Start this project's daemon and wait for it to answer.
local function start_daemon()
  local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "--listen", sock }, {
    cwd = root,
    detach = true,
    env = { NV_DAEMON = "1" },
  })
  if job <= 0 then
    return nil
  end
  local deadline = uv.hrtime() + 30e9
  while uv.hrtime() < deadline do
    uv.sleep(40)
    local handle = connect()
    if handle then
      return handle
    end
  end
end

if not chan and not nested then
  chan = start_daemon()
  if not chan then
    note("could not start a session for " .. tostring(root))
    run_locally()
  end
end
if not chan then
  run_locally()
end

-- One token per pane: the daemon binds it to our UI channel, and to the pid of
-- the TUI the wrapper is about to start.
local token = ("%d-%d"):format(uv.os_getpid(), os.time())
local wait = vim.env.NV_WAIT == "1" and files[1] ~= nil
local sentinel
if nested and wait then
  -- No UI of our own to wait on here, so fall back to a file the session
  -- deletes when the buffer closes.
  sentinel = ("%s/wait-%s"):format(vim.fs.dirname(sock), token)
  vim.fn.writefile({ files[1] }, sentinel)
end

if not nested then
  local ok, err = pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return require('nv').register(...)", { token })
  if not ok then
    note("session did not accept this pane: " .. tostring(err))
    run_locally()
  end
end

local ok, res = pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return require('nv').open(...)", {
  { files = files, line = line, col = col, wait = wait, token = token, sentinel = sentinel },
})
if not ok then
  if sentinel then
    os.remove(sentinel)
  end
  note("handoff to " .. sock .. " failed: " .. tostring(res))
  run_locally()
end

if not nested then
  io.stdout:write(sock .. "\n" .. token .. "\n")
  os.exit(EXIT_ATTACH)
end

-- Nested: the surrounding nvim now shows the file. Block if we were asked to.
if wait then
  local ticks = 0
  while uv.fs_stat(sentinel) do
    uv.sleep(100)
    ticks = ticks + 1
    if ticks % 10 == 0 and not pcall(vim.rpcrequest, chan, "nvim_eval", "1") then
      break -- the session went away mid-edit
    end
  end
  os.remove(sentinel)
end

os.exit(0)
