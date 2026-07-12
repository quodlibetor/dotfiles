--- Project-root detection shared by the nv client and server.
---
--- The rule: walk up from the starting directory, never crossing out of the
--- enclosing repository, and ask each language's own dominating-file
--- convention where its project begins. Each language's answer mirrors what
--- its tooling would say (`go env GOWORK`/`GOMOD`, `cargo locate-project
--- --workspace`, uv's workspace discovery, maven's aggregator pom) without
--- paying to shell out to it -- these are all "nearest/outermost file named X"
--- searches, which is what `vim.fs` does natively. Drop a `.nvroot` file to
--- override the guess for a directory tree.
local M = {}

local uv = vim.uv or vim.loop

--- `[workspace]` / `[workspace.foo]` at the start of a line.
local CARGO_WORKSPACE = "\n%s*%[workspace[%.%]]"
--- `[tool.uv.workspace]` at the start of a line.
local UV_WORKSPACE = "\n%s*%[tool%.uv%.workspace%]"

--- Bazel knows two units: the workspace and the package (any directory with a
--- BUILD file). The first is the whole monorepo, the second is every leaf java
--- package -- neither is an editing session. So take the nearest package that
--- builds something deployable, which lands on a service root in both the
--- BUILD-per-java-package layout and the glob-at-the-service-root layout.
--- Libraries are deliberately absent: matching them would key on leaf
--- packages. Add your monorepo's own macros here -- a wrapper like
--- `java_microservice(...)` is invisible to this list.
local BAZEL_DEPLOYABLES = {
  "oci_image",
  "oci_push",
  "container_image",
  "java_binary",
  "java_image",
  "pkg_tar",
}
local BAZEL_BUILD = { "BUILD.bazel", "BUILD" }
local BAZEL_WORKSPACE = { "MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE.bzlmod", "WORKSPACE" }

local function has(dir, name)
  return uv.fs_stat(dir .. "/" .. name) ~= nil
end

--- Head of a file, newline-prefixed so patterns can anchor to line starts.
--- Manifest tables we care about live in the first few KB.
local function head(path)
  local fd = io.open(path, "r")
  if not fd then
    return ""
  end
  local data = fd:read(64 * 1024) or ""
  fd:close()
  return "\n" .. data
end

--- Does `dir/file` declare the section matched by `pattern`?
local function declares(dir, file, pattern)
  return has(dir, file) and head(dir .. "/" .. file):find(pattern) ~= nil
end

--- Does this directory's BUILD file call one of `rules`? Anchored to the start
--- of a line and followed by `(`, so the `load()` that imports the rule by
--- name doesn't count as a use of it.
local function builds(dir, rules)
  for _, file in ipairs(BAZEL_BUILD) do
    if has(dir, file) then
      local text = head(dir .. "/" .. file)
      for _, rule in ipairs(rules) do
        if text:find("\n%s*" .. rule .. "%s*%(") then
          return true
        end
      end
      return false -- a package has one BUILD file; don't read BUILD too
    end
  end
  return false
end

--- Every directory from `dir` up to `/`, innermost first.
local function ancestors(dir)
  local dirs = {}
  while true do
    dirs[#dirs + 1] = dir
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      return dirs
    end
    dir = parent
  end
end

--- Find the project root for `start`.
---@param start string? directory to search from (default: cwd)
---@return string root
---@return string reason what decided it, for `:NvRoot`
function M.detect(start)
  start = start or uv.cwd()
  start = uv.fs_realpath(start) or vim.fs.normalize(start)

  local dirs = ancestors(start)

  -- A repository is a hard ceiling: one nvim per repo at most, never an
  -- instance shared across two checkouts because they happen to sit under a
  -- common cargo workspace.
  local vcs
  for i, dir in ipairs(dirs) do
    if has(dir, ".jj") or has(dir, ".git") then
      vcs = dir
      dirs = vim.list_slice(dirs, 1, i)
      break
    end
  end

  --- Innermost directory holding any of `names`.
  local function nearest(names)
    for _, dir in ipairs(dirs) do
      for _, name in ipairs(names) do
        if has(dir, name) then
          return dir
        end
      end
    end
  end

  --- Outermost directory satisfying `pred` (dirs is innermost-first, so the
  --- last match wins).
  local function outermost(pred)
    local found
    for _, dir in ipairs(dirs) do
      if pred(dir) then
        found = dir
      end
    end
    return found
  end

  --- Innermost bazel package that builds something deployable.
  local function nearest_bazel_unit()
    for _, dir in ipairs(dirs) do
      if builds(dir, BAZEL_DEPLOYABLES) then
        return dir
      end
    end
  end

  for _, dir in ipairs(dirs) do
    if has(dir, ".nvroot") then
      return dir, ".nvroot"
    end
  end

  local found = {
    -- go: a workspace wins over the module, both nearest-wins, as `go env
    -- GOWORK` / `go env GOMOD` resolve them.
    go = nearest({ "go.work" }) or nearest({ "go.mod" }),
    -- rust: the outermost manifest declaring `[workspace]`, else this crate.
    rust = outermost(function(dir)
      return declares(dir, "Cargo.toml", CARGO_WORKSPACE)
    end) or nearest({ "Cargo.toml" }),
    -- python: a uv workspace root, else whatever marks this project.
    python = outermost(function(dir)
      return declares(dir, "pyproject.toml", UV_WORKSPACE)
    end) or nearest({ "uv.toml", "uv.lock", "pyproject.toml", "setup.py", "setup.cfg" }),
    -- bazel: the nearest deployable package, else the workspace itself.
    bazel = nearest_bazel_unit() or nearest({ ".bazelproject" }) or nearest(BAZEL_WORKSPACE),
    -- java: maven aggregates upward, so the outermost pom is the build root;
    -- gradle names its root project directly.
    java = outermost(function(dir)
      return has(dir, "pom.xml")
    end) or nearest({ "settings.gradle", "settings.gradle.kts" }) or nearest({
      "build.gradle",
      "build.gradle.kts",
    }),
  }

  -- Each language already widened to its own workspace root, so between
  -- languages take the most specific answer.
  local depth = {}
  for i, dir in ipairs(dirs) do
    depth[dir] = i
  end
  local root, reason
  for lang, dir in pairs(found) do
    if dir and (not root or depth[dir] < depth[root]) then
      root, reason = dir, lang
    end
  end

  if root then
    return root, reason
  elseif vcs then
    return vcs, has(vcs, ".jj") and "jj" or "git"
  end
  return start, "cwd"
end

--- Where the instance for `root` listens.
---
--- Unix socket paths are capped at ~104 bytes on macOS and nvim refuses to
--- `--listen` on anything longer, so the name stays short and the whole path
--- is length-checked before it is handed out.
---@param root string
---@return string path
--- Where sockets live. Per-user by construction: $XDG_RUNTIME_DIR and macOS's
--- $TMPDIR are both private.
function M.socket_dir()
  return ((vim.env.XDG_RUNTIME_DIR or vim.env.TMPDIR or "/tmp"):gsub("/+$", "")) .. "/nv"
end

function M.socket(root)
  local dir = M.socket_dir()
  local digest = vim.fn.sha256(root):sub(1, 8)
  local slug = vim.fs.basename(root):gsub("[^%w%._-]", "-"):sub(1, 20)

  local candidates = {
    ("%s/%s-%s.sock"):format(dir, slug ~= "" and slug or "root", digest),
    ("%s/%s.sock"):format(dir, digest),
    ("/tmp/nv-%d/%s.sock"):format(uv.getuid and uv.getuid() or 0, digest),
  }
  for _, path in ipairs(candidates) do
    if #path <= 100 then
      vim.fn.mkdir(vim.fs.dirname(path), "p", tonumber("700", 8))
      return path
    end
  end
  error("nv: no socket path short enough for " .. root)
end

return M
