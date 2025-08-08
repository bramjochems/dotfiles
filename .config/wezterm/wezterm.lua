local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- ===== BASIC APPEARANCE =====
config.font = wezterm.font("JetBrains Mono", { weight = "Regular" }) -- Cascadia Mono
config.font_size = 11.0
config.debug_key_events = true
-- Disable ligatures (only calt as requested)
config.harfbuzz_features = { "calt=1", "clig=1", "liga=1" }
-- Window appearance
config.window_padding = {
  left = 8,
  right = 9,
  top = 8,
  bottom = 8,
}

config.window_background_opacity = 0.98
config.window_decorations = "TITLE|RESIZE"
config.use_fancy_tab_bar = true
config.tab_bar_at_bottom = false
config.hide_tab_bar_if_only_one_tab = false
config.enable_kitty_graphics = true
-- ===== SHELL CONFIGURATION =====
-- Default to WSL
config.default_prog = { "wsl.exe", "~" }

-- Define different shell programs (Windows)
config.launch_menu = {
  {
    label = "WSL",
    args = { "wsl.exe" },
  },
  {
    label = "PowerShell",
    args = { "powershell.exe" },
  },
  {
    label = "PowerShell (Admin)",
    args = { "powershell.exe", "-Command", "Start-Process", "powershell.exe", "-Verb", "RunAs" },
  },
  {
    label = "Command Prompt",
    args = { "cmd.exe" },
  },
}

wezterm.on("new-tab-button-click", function(window, pane, button, default_action)
  if default_action then
    window:perform_action(wezterm.action.ShowLauncher, pane)
  end
  return false -- Prevent default action
end)

-- ===== KEY BINDINGS =====
config.keys = {
  -- Shell switching
  {
    key = "!",
    mods = "CTRL|SHIFT",
    action = wezterm.action.SpawnCommandInNewTab({
      args = { "wsl.exe", "~" },
    }),
  },
  {
    key = "@",
    mods = "CTRL|SHIFT",
    action = wezterm.action.SpawnCommandInNewTab({
      args = { "powershell.exe" },
    }),
  },
  {
    key = "#",
    mods = "CTRL|SHIFT",
    action = wezterm.action.ShowLauncher,
  },
  {
    key = "$",
    mods = "CTRL|SHIFT",
    action = wezterm.action.SpawnCommandInNewTab({
      args = { "cmd.exe" },
    }),
  },
  {
    key = "+", -- Shift+= is usually the '+' key
    mods = "CTRL|SHIFT",
    action = wezterm.action.IncreaseFontSize,
  },

  -- Font size decrease
  {
    key = "_", -- Shift+- is usually the '_' key
    mods = "CTRL|SHIFT",
    action = wezterm.action.DecreaseFontSize,
  },

  -- Optional: Reset font size
  {
    key = "0",
    mods = "CTRL",
    action = wezterm.action.ResetFontSize,
  },

  -- Utilities
  {
    key = "h",
    mods = "CTRL|ALT",
    action = wezterm.action.ActivateCommandPalette,
  },
  {
    key = "l",
    mods = "CTRL|ALT",
    action = wezterm.action.ShowLauncher,
  },
}

-- ===== MOUSE CONFIGURATION =====
-- Set up hyperlink rules with custom browser handling
config.hyperlink_rules = wezterm.default_hyperlink_rules()

-- Platform-specific browser opener
wezterm.on("open-uri", function(window, pane, uri)
  local is_wsl = os.getenv("WSL_DISTRO_NAME") ~= nil or os.getenv("WSLENV") ~= nil

  if is_wsl then
    -- In WSL, use Windows browser via cmd.exe
    local success, exit_code, stdout, stderr = wezterm.run_child_process({
      "powershell.exe",
      "-Command",
      "Start-Process",
      "-FilePath",
      uri,
    })
    if success then
      return false -- Prevent default handling
    end
  else
    -- On native Linux, use xdg-open
    local success, exit_code, stdout, stderr = wezterm.run_child_process({
      "xdg-open",
      uri,
    })
    if success then
      return false -- Prevent default handling
    end
  end

  -- If our custom handling fails, return true to allow default behavior
  return true
end)

config.mouse_bindings = {
  {
    event = { Up = { streak = 1, button = "Left" } },
    mods = "CTRL",
    action = wezterm.action.OpenLinkAtMouseCursor,
  },
}

-- ===== PERFORMANCE =====
config.max_fps = 60
config.animation_fps = 1
config.cursor_blink_rate = 500

-- ===== ADVANCED FEATURES =====
--config.term = 'wezterm'
config.scrollback_lines = 10000
config.hyperlink_rules = wezterm.default_hyperlink_rules()

-- Bell settings
config.audible_bell = "Disabled"
config.visual_bell = {
  fade_in_function = "EaseIn",
  fade_in_duration_ms = 150,
  fade_out_function = "EaseOut",
  fade_out_duration_ms = 150,
}

local color_schemes = {
  onedark = {
    foreground = "#abb2bf",
    background = "#282c34",
    cursor_bg = "#61afef",
    cursor_border = "#61afef",
    cursor_fg = "#282c34",
    selection_bg = "#61afef",
    selection_fg = "#282c34",

    ansi = {
      "#1e2127", -- black
      "#e06c75", -- red
      "#98c379", -- green
      "#d19a66", -- yellow
      "#61afef", -- blue
      "#c678dd", -- magenta
      "#56b6c2", -- cyan
      "#abb2bf", -- white
    },

    brights = {
      "#5c6370", -- bright black
      "#e06c75", -- bright red
      "#98c379", -- bright green
      "#e5c07b", -- bright yellow
      "#61afef", -- bright blue
      "#c678dd", -- bright magenta
      "#56b6c2", -- bright cyan
      "#ffffff", -- bright white
    },

    tab_bar = {
      background = "#282c34",
      active_tab = {
        bg_color = "#61afef",
        fg_color = "#282c34",
        intensity = "Bold",
      },
      inactive_tab = {
        bg_color = "#3e4451",
        fg_color = "#abb2bf",
      },
      inactive_tab_hover = {
        bg_color = "#4e5461",
        fg_color = "#ffffff",
      },
    },

    scrollbar_thumb = "#5c6370",
    split = "#3e4451",
  },

  gruvbox = {
    foreground = "#ebdbb2",
    background = "#282828",
    cursor_bg = "#fabd2f",
    cursor_border = "#fabd2f",
    cursor_fg = "#282828",
    selection_bg = "#fabd2f",
    selection_fg = "#282828",

    ansi = {
      "#282828", -- black
      "#cc241d", -- red
      "#98971a", -- green
      "#d79921", -- yellow
      "#458588", -- blue
      "#b16286", -- magenta
      "#689d6a", -- cyan
      "#a89984", -- white
    },

    brights = {
      "#928374", -- bright black
      "#fb4934", -- bright red
      "#b8bb26", -- bright green
      "#fabd2f", -- bright yellow
      "#83a598", -- bright blue
      "#d3869b", -- bright magenta
      "#8ec07c", -- bright cyan
      "#ebdbb2", -- bright white
    },

    tab_bar = {
      background = "#282828",
      active_tab = {
        bg_color = "#fabd2f",
        fg_color = "#282828",
        intensity = "Bold",
      },
      inactive_tab = {
        bg_color = "#3c3836",
        fg_color = "#ebdbb2",
      },
      inactive_tab_hover = {
        bg_color = "#504945",
        fg_color = "#ffffff",
      },
    },

    scrollbar_thumb = "#928374",
    split = "#3c3836",
  },

  atom_dark = {
    foreground = "#c5c8c6",
    background = "#1d1f21",
    cursor_bg = "#c5c8c6",
    cursor_border = "#c5c8c6",
    cursor_fg = "#1d1f21",
    selection_bg = "#373b41",
    selection_fg = "#c5c8c6",

    ansi = {
      "#1d1f21", -- black
      "#cc6666", -- red
      "#b5bd68", -- green
      "#f0c674", -- yellow
      "#81a2be", -- blue
      "#b294bb", -- magenta
      "#8abeb7", -- cyan
      "#c5c8c6", -- white
    },

    brights = {
      "#969896", -- bright black
      "#cc6666", -- bright red
      "#b5bd68", -- bright green
      "#f0c674", -- bright yellow
      "#81a2be", -- bright blue
      "#b294bb", -- bright magenta
      "#8abeb7", -- bright cyan
      "#ffffff", -- bright white
    },

    tab_bar = {
      background = "#1d1f21",
      active_tab = {
        bg_color = "#81a2be",
        fg_color = "#1d1f21",
        intensity = "Bold",
      },
      inactive_tab = {
        bg_color = "#282a2e",
        fg_color = "#c5c8c6",
      },
      inactive_tab_hover = {
        bg_color = "#373b41",
        fg_color = "#ffffff",
      },
    },

    scrollbar_thumb = "#969896",
    split = "#282a2e",
  },
}

config.colors = color_schemes.atom_dark

return config
