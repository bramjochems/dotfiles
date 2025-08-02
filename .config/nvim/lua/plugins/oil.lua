return (vim.g.vscode and {}) or {
  "stevearc/oil.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  opts = {
    default_file_explorer = false,
    keymaps = {
      ["-"] = "actions.parent", -- Navigate to parent directory in oil
    },
    float = {
      padding = 2,
      max_width = 0.7,
      max_height = 0.5,
      border = "rounded",
      win_options = {
        winblend = 0,
      },
    },
  },
  keys = {
    {
      "-",
      function()
        require("oil").open_float()
      end,
      desc = "Open Oil file explorer",
    },
  },
}
