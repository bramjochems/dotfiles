return {
  { "ellisonleao/gruvbox.nvim" },

  {
    "sainnhe/gruvbox-material",
    lazy = false,
    priority = 1000,
    config = function()
      vim.g.gruvbox_material_better_performance = 1
      vim.g.gruvbox_material_foreground = "material"
      vim.g.gruvbox_material_background = "soft"
      vim.g.gruvbox_material_ui_contrast = "high"
      vim.g.gruvbox_material_float_style = "dim"
      vim.g.gruvbox_material_enable_italic = 0
      vim.g.gruvbox_material_disable_italic_comment = 1
      vim.g.gruvbox_material_cursor = "auto"
      vim.g.gruvbox_material_disable_terminal_colors = 1
      vim.g.gruvbox_material_dim_inactive_windows = 0
    end,
  },

  {
    "navarasu/onedark.nvim",
    opts = {
      style = "cool",
      colors = { bg0 = "#1a1c23" },
    },
  },

  {
    "nyoom-engineering/oxocarbon.nvim",
  },

  {
    "EdenEast/nightfox.nvim",
  },

  {
    "vague2k/vague.nvim",
  },

  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "gruvbox-material",
    },
  },
}
