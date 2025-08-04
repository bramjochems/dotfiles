return (vim.g.vscode and {})
  or {
    "christoomey/vim-tmux-navigator",
    lazy = false,
    -- Try just the simple approach first
    keys = {
      { "<C-h>", "<cmd>TmuxNavigateLeft<cr>", desc = "Go to left window", mode = { "n", "t" } },
      { "<C-j>", "<cmd>TmuxNavigateDown<cr>", desc = "Go to lower window", mode = { "n", "t" } },
      { "<C-k>", "<cmd>TmuxNavigateUp<cr>", desc = "Go to upper window", mode = { "n", "t" } },
      { "<C-l>", "<cmd>TmuxNavigateRight<cr>", desc = "Go to right window", mode = { "n", "t" } },
      { "<C-\\>", "<cmd>TmuxNavigatePrevious<cr>", desc = "Go to previous window", mode = "n" },

      { "<Esc><Esc>", "<C-\\><C-n>", desc = "Exit terminal mode", mode = "t" },
    },
    config = function()
      vim.g.tmux_navigator_save_on_switch = 2
      vim.g.tmux_navigator_disable_when_zoomed = 1
    end,
  }
