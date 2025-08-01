return {
  "pocco81/auto-save.nvim",
  event = { "InsertLeave", "VimLeavePre" },
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
    enabled = true,
    execution_message = {
      message = function()
        return "💾 saved at " .. vim.fn.strftime("%H:%M:%S")
      end,
      dim = 0.18,
      debounce_delay = 2000,
      cleaning_interval = 750,
    },
    debounce_delay = 1350, -- time in ms after last change before save
    condition = function(buf)
      local fn = vim.fn
      local utils = require("auto-save.utils.data")
      return fn.getbufvar(buf, "&modifiable") == 1
        and utils.not_in(fn.getbufvar(buf, "&filetype"), { "NvimTree", "TelescopePrompt", "Oil" })
        and fn.getbufvar(buf, "&buftype") == "" -- Don't save special buffers
    end,
  },
}
