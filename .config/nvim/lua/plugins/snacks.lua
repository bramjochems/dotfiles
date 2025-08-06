return (vim.g.vscode and {})
  or {
    "folke/snacks.nvim",
    opts = {
      picker = {
        sources = {
          explorer = {
            hidden = true,
            ignored = true,
          },
          grep = {
            hidden = true,
            ignored = true,
          },
          files = {
            hidden = true,
            ignored = true,
          },
        },
      },
    },
    config = function(_, opts)
      -- Apply the existing Snacks options
      require("snacks").setup(opts)

      -- ✅ Add your custom keymap (Capital C) to set cwd from selected file
      vim.keymap.set("n", "<leader>C", function()
        local explorer = require("snacks.explorer")
        local entry = explorer.get_selected_entry and explorer.get_selected_entry()
        if not entry then
          vim.notify("No file selected in Snacks Explorer", vim.log.levels.WARN)
          return
        end
        local dir = vim.fn.fnamemodify(entry.path, ":h")
        vim.cmd("cd " .. dir)
        vim.notify("Changed cwd to: " .. dir)
      end, { desc = "Change CWD to selected file in Snacks Explorer" })
    end,
  }
