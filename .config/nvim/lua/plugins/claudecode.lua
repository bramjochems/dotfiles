return (vim.g.vscode and {}) or {
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = true,
  opts = {
    terminal_cmd = "claude",
    terminal = {
      provider = "snacks",
      snacks_win_opts = {
        position = "right",
        width = 0.4,
        -- height = 0.9,
        title = "Claude Code",
        title_pos = "center",
        border = "rounded",
      },
    },
    diff_opts = {
      auto_close_on_accept = true,
      vertical_split = true,
      open_in_current_tab = false,
    },
  },
  keys = {
    -- Claude in floating window
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Claude Code" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Focus" },

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
