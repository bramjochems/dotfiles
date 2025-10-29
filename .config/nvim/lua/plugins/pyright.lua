-- Disable LazyVim's default pyright and ruff servers
-- Custom Python LSP logic is handled in python-lsp.lua
return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      pyright = false,
      ruff = false,
    },
  },
}
