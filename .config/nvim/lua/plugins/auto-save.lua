return {
  "pocco81/auto-save.nvim",
  event = { "InsertLeave", "TextChanged" },
  keys = {
    {
      "<leader>ua",
      function()
        require("auto-save").toggle()
        vim.notify("Auto-save toggled")
      end,
      desc = "Toggle Auto-Save",
    },
  },
  opts = {
    enabled = false,
    execution_message = {
      message = function()
        return "💾 saved at " .. vim.fn.strftime("%H:%M:%S")
      end,
      dim = 0.18,
      cleaning_interval = 1250,
    },
    debounce_delay = 1350, -- time in ms after last change before save
    condition = function(buf)
      local fn = vim.fn
      local utils = require("auto-save.utils.data")
      return fn.getbufvar(buf, "&modifiable") == 1
        and utils.not_in(fn.getbufvar(buf, "&filetype"), { "NvimTree", "TelescopePrompt" })
    end,
  },
}
