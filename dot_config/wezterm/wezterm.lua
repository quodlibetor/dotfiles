local wezterm = require("wezterm")
local act = wezterm.action

local function basename(s)
  local trimmed = string.gsub(s, "/+$", "")
  local cut = string.gsub(trimmed, "(.*/)(.*)", "%2")
  return cut
end

-- Function to check if a .git directory exists in the given path
--
-- This doesn't work  in remote directories, it's just a fallback if the precmd isn't working
local function has_git_dir(path)
  path = string.gsub(path, "/+$", "")
  local git_path = path .. "/.git"
  -- ugh... I think this is my only option until https://github.com/wez/wezterm/pull/4493 gets merged
  local cmd = "test -d '" .. git_path .. "' && echo 'exists' || echo 'not found'"
  local handle = io.popen(cmd)
  if handle ~= nil then
    local result = handle:read("*a")
    handle:close()
    return result:find("exists") ~= nil
  else
    wezterm.log_info("no handle")
  end
  return false
end

local git_root_cache = {}
-- walk up directories and check for .git directory
local function find_git_root(start_path)
  -- Check if the result is already cached
  if git_root_cache[start_path] ~= nil then
    return git_root_cache[start_path]
  end

  local path = start_path
  while path do
    if has_git_dir(path) then
      git_root_cache[start_path] = path
      return path
    end

    -- Strip the trailing component from the path
    local parent = path:match("(.*/)[^/]+/?$")
    if parent == path or parent == nil or parent == "" then
      git_root_cache[start_path] = ""
      return ""
    end
    path = parent:sub(1, -2) -- Remove trailing slash
  end
end

local function git_root_dir(tabinfo)
  local pane = tabinfo.active_pane
  local workdir = pane.current_working_dir or ""
  local gitroot = nil
  if pane.current_working_dir ~= nil then
    workdir = pane.current_working_dir.path
    workdir = basename(workdir)

    gitroot = pane.user_vars.git_root
    if gitroot == nil or gitroot == "" then
      gitroot = find_git_root(pane.current_working_dir.path)
    end
  end
  if gitroot ~= nil and gitroot ~= "" then
    gitroot = basename(gitroot)
    if gitroot ~= workdir then
      workdir = gitroot .. ".." .. workdir
    end
  end

  return workdir
end

-- local theme = "Modus Vivendi (Gogh)"
local theme = "Modus-Vivendi"
local remote_theme = 'Modus-Vivendi-Tinted'

wezterm.on("user-var-changed", function(window, pane, name, value)
  if name == "OPEN_URL" then
    wezterm.open_with(value)
  elseif name == "BWM_COPY_TEXT" then
    window:copy_to_clipboard(value, "Clipboard")
  end
end)

wezterm.on('window-focus-changed', function(window, pane)
  local conf = window:get_config_overrides() or {}
  local domain_name = pane:get_domain_name()
  if domain_name and domain_name:find("coder") then
    conf['color_scheme'] = remote_theme
  end
  window:set_config_overrides(conf)
end)

local config = {}
if wezterm.config_builder then
  config = wezterm.config_builder()
end

local tabline = wezterm.plugin.require("https://github.com/michaelbrusegard/tabline.wez")
tabline.setup({
  options = {
    icons_enabled = true,
    theme = theme,
    color_overrides = {},
    section_separators = {
      left = wezterm.nerdfonts.pl_left_hard_divider,
      right = wezterm.nerdfonts.pl_right_hard_divider,
    },
    component_separators = {
      left = wezterm.nerdfonts.pl_left_soft_divider,
      right = wezterm.nerdfonts.pl_right_soft_divider,
    },
    tab_separators = {
      left = wezterm.nerdfonts.pl_left_hard_divider,
      right = wezterm.nerdfonts.pl_right_hard_divider,
    },
  },
  sections = {
    tabline_a = { 'hostname' },
    tabline_b = { 'workspace' },
    tabline_c = { ' ' },
    tab_active = {
      { 'zoomed', padding = 0 },
      '✨',
      'index',
      git_root_dir,
      ' ✨',
    },
    tab_inactive = {
      'index',
      git_root_dir,
      '->',
      { 'process', padding = { left = 0, right = 1 } },
    },
    tabline_x = {}, --'ram', 'cpu' },
    tabline_y = {}, --'datetime', 'battery' },
    tabline_z = { 'hostname' },
  },
  extensions = {},
})
tabline.apply_to_config(config)
config.font = wezterm.font("JetBrains Mono")

config.color_scheme = theme
config.use_ime = false
config.send_composed_key_when_right_alt_is_pressed = false
config.term = "wezterm"
config.default_prog = { "zsh" } -- don't launch as a login shell
config.ssh_domains = {
  {
    -- This name identifies the domain
    name = "coder.bwm",
    -- The hostname or address to connect to. Will be used to match settings
    -- from your ssh config file
    remote_address = "coder.bwm",
    -- The username to use on the remote host
    username = "coder",
  },
  {
    name = "coder.bwm-mega",
    remote_address = "coder.bwm-mega",
    -- The username to use on the remote host
    username = "coder",
  },
}
config.keys = {
  {
    key = "r",
    mods = "CMD|SHIFT",
    action = wezterm.action.ReloadConfiguration,
  },
  -- These two also depend on the `send_compose_key..` setting above so that
  -- opt-b and opt-f mean forward/backward word instead of greek letters
  -- Make Option-Left equivalent to Alt-b which many line editors interpret as backward-word
  { key = "LeftArrow",  mods = "OPT", action = wezterm.action({ SendString = "\x1bb" }) },
  -- Make Option-Right equivalent to Alt-f; forward-word
  { key = "RightArrow", mods = "OPT", action = wezterm.action({ SendString = "\x1bf" }) },
  {
    key = "-",
    mods = "CTRL",
    action = act.SplitVertical({ domain = "CurrentPaneDomain" }),
  },
  {
    key = "_",
    mods = "CTRL",
    action = act.SplitVertical({ domain = "CurrentPaneDomain" }),
  },
  {
    key = "%",
    mods = "CTRL",
    action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }),
  },
  {
    key = "|",
    mods = "CTRL|SHIFT",
    action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }),
  },
  {
    key = "\\", -- duplicate of | to reduce pinky strain
    mods = "CMD|CTRL",
    action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }),
  },
  -- Clears the scrollback and viewport, and then sends CTRL-L to ask the
  -- shell to redraw its prompt
  {
    key = "k",
    mods = "CMD",
    action = act.Multiple({
      act.ClearScrollback("ScrollbackAndViewport"),
      act.SendKey({ key = "L", mods = "CTRL" }),
    }),
  },
}
config.mouse_bindings = {
  {
    event = { Down = { streak = 3, button = "Left" } },
    action = wezterm.action.SelectTextAtMouseCursor("SemanticZone"),
    mods = "NONE",
  },
}

return config
