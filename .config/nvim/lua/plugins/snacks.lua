return (vim.g.vscode and {}) or {
  "folke/snacks.nvim",
  -- opts will be merged with the parent spec
  opts = {
    picker = {
      sources = {
        explorer = {
          hidden = true,
          ignored = true,
        },
      },
    },
  },
}
