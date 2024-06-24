local wezterm = require 'wezterm'
local act = wezterm.action

function basename(s)
  return string.gsub(string.gsub(s, "/+$", ""), '(.*/)(.*)', '%2')
end

wezterm.on('format-tab-title', function(tab, tabs, panes, config, hover, max_width)
  local pane = tab.active_pane
  local active_process = basename(pane.foreground_process_name)
  local workdir = '?'
  local host = ''
  if pane.current_working_dir ~= nil then
    workdir = pane.current_working_dir.path
    workdir = basename(workdir)
    host = pane.current_working_dir.host
    if host == nil then
      host = ""
    end
  end
  local gitroot = pane.user_vars.gitroot
  if gitroot ~= nil and gitroot ~= "" then
    gitroot = basename(gitroot)
    if gitroot ~= workdir then
      workdir = gitroot .. ".." .. workdir
    end
  end

  return {
    -- {Background={Color="blue"}},
    -- {Foreground={Color="white"}},
    { Text = ' ' .. host .. ':' .. workdir .. '>' .. active_process .. ' ' },
  }
end)

wezterm.on('user-var-changed', function(window, pane, name, value)
  if name == 'OPEN_URL' then
    wezterm.open_with(value)
  elseif name == 'BWM_COPY_TEXT' then
    window:copy_to_clipboard(value, 'Clipboard')
  end
end)

config = {}
if wezterm.config_builder then
  config = wezterm.config_builder()
end

config.font = wezterm.font 'JetBrains Mono'
config.color_scheme = "Dracula"
config.use_ime = false
config.send_composed_key_when_right_alt_is_pressed = false
config.term = 'wezterm'
config.ssh_domains = {
  {
    -- This name identifies the domain
    name = 'coder.bwm',
    -- The hostname or address to connect to. Will be used to match settings
    -- from your ssh config file
    remote_address = 'coder.bwm',
    -- The username to use on the remote host
    username = 'coder',
  },
  {
    name = 'coder.bwm-mega',
    remote_address = 'coder.bwm-mega',
    -- The username to use on the remote host
    username = 'coder',
  },
}
config.keys = {
  {
    key = 'r',
    mods = 'CMD|SHIFT',
    action = wezterm.action.ReloadConfiguration,
  },
  -- These two also depend on the `send_compose_key..` setting above so that
  -- opt-b and opt-f mean forward/backward word instead of greek letters
  -- Make Option-Left equivalent to Alt-b which many line editors interpret as backward-word
  { key = "LeftArrow",  mods = "OPT", action = wezterm.action { SendString = "\x1bb" } },
  -- Make Option-Right equivalent to Alt-f; forward-word
  { key = "RightArrow", mods = "OPT", action = wezterm.action { SendString = "\x1bf" } },
  {
    key = '-',
    mods = 'CTRL',
    action = act.SplitVertical { domain = 'CurrentPaneDomain' },
  },
  {
    key = '_',
    mods = 'CTRL',
    action = act.SplitVertical { domain = 'CurrentPaneDomain' },
  },
  {
    key = '%',
    mods = 'CTRL',
    action = act.SplitHorizontal { domain = 'CurrentPaneDomain' },
  },
  {
    key = '|',
    mods = 'CTRL|SHIFT',
    action = act.SplitHorizontal { domain = 'CurrentPaneDomain' },
  },
  {
    key = '\\', -- duplicate of | to reduce pinky strain
    mods = 'CMD|CTRL',
    action = act.SplitHorizontal { domain = 'CurrentPaneDomain' },
  },
  -- Clears the scrollback and viewport, and then sends CTRL-L to ask the
  -- shell to redraw its prompt
  {
    key = 'k',
    mods = 'CMD',
    action = act.Multiple {
      act.ClearScrollback 'ScrollbackAndViewport',
      act.SendKey { key = 'L', mods = 'CTRL' },
    },
  },
}
config.mouse_bindings = {
  {
    event = { Down = { streak = 3, button = 'Left' } },
    action = wezterm.action.SelectTextAtMouseCursor 'SemanticZone',
    mods = 'NONE',
  },
}

return config
