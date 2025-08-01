return {
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = true,
  opts = {
    terminal_cmd = "claude",
    terminal = {
      ---@module "snacks"
      ---@type snacks.win.Config|{}
      snacks_win_opts = {
        position = "right", -- Sidebar for normal terminal
        width = 80,
      },
    },
    -- Add a separate config for focus mode
    focus_terminal = {
      snacks_win_opts = {
        position = "float", -- Popup instead of sidebar
        width = 0.9,
        height = 0.9,
      },
    },
  },
  keys = {
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Claude Sidebar" },

    -- Override Claude Focus to use float options
    {
      "<leader>af",
      function()
        require("claudecode").open({
          terminal = {
            snacks_win_opts = {
              position = "float",
              width = 0.9,
              height = 0.9,
            },
          },
        })
      end,
      desc = "Claude Popup Focus",
    },

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
