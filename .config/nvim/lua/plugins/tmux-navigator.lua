return (vim.g.vscode and {}) or {
  "christoomey/vim-tmux-navigator",
  lazy = false,

  keys = {
    -- Override LazyVim's default window navigation
    { "<C-h>", "<cmd>TmuxNavigateLeft<cr>", desc = "Go to left window" },
    { "<C-j>", "<cmd>TmuxNavigateDown<cr>", desc = "Go to lower window" },
    { "<C-k>", "<cmd>TmuxNavigateUp<cr>", desc = "Go to upper window" },
    { "<C-l>", "<cmd>TmuxNavigateRight<cr>", desc = "Go to right window" },
    { "<C-\\>", "<cmd>TmuxNavigatePrevious<cr>", desc = "Go to previous window" },
  },

  config = function()
    vim.g.tmux_navigator_save_on_switch = 2
    vim.g.tmux_navigator_disable_when_zoomed = 1
  end,
}
