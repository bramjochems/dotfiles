return {
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = true,
  opts = {
    terminal_cmd = "claude",
  },
  terminal = {
    split_side = "right", -- "left" or "right"
    split_width_percentage = 0.30,
    provider = "auto", -- "auto", "snacks", "native", or custom provider table
    auto_close = true,
    snacks_win_opts = {}, -- Opts to pass to `Snacks.terminal.open()` - see Floating Window section below
  },

  -- Diff Integration
  diff_opts = {
    auto_close_on_accept = true,
    vertical_split = true,
    open_in_current_tab = false,
  },
  keys = {
    -- Claude in sidebar
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Claude Sidebar" },

    -- Claude in floating window
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Float" },

    -- File operations
    { "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil", "snacks_explorer" },
    },

    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
}
