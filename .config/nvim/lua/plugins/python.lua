return {
  {
    "linux-cultist/venv-selector.nvim",
    enabled = true,
    ft = "python",
    opts = {
      name = ".venv",
      search = true,
      auto_refresh = true,
    },
    keys = {
      { "<leader>cv", "<cmd>VenvSelect<cr>", desc = "Select Virtualenv" },
    },
    config = function(_, opts)
      local venv_selector = require("venv-selector")
      venv_selector.setup(opts)

      -- 🔹 Update Pyright, DAP, and Neotest when venv changes
      vim.api.nvim_create_autocmd("User", {
        pattern = "VenvSelectActivated",
        callback = function()
          local venv = venv_selector.get_active_venv()
          if not venv then
            return
          end
          local python_bin = venv .. "/bin/python"

          -- Update Pyright dynamically
          local pyright_client
          for _, c in pairs(vim.lsp.get_clients()) do
            if c.name == "pyright" then
              pyright_client = c
              break
            end
          end
          if pyright_client then
            local new_settings = vim.tbl_deep_extend("force", pyright_client.config.settings or {}, {
              python = { pythonPath = python_bin },
            })
            pyright_client.notify("workspace/didChangeConfiguration", { settings = new_settings })
            vim.notify("Pyright now using: " .. python_bin, vim.log.levels.INFO)
          end

          -- Update DAP-Python to use the venv interpreter
          local ok_dap, dap_python = pcall(require, "dap-python")
          if ok_dap then
            dap_python.setup(python_bin)
            vim.notify("DAP-Python now using: " .. python_bin, vim.log.levels.INFO)
          end

          -- Reconfigure Neotest Python adapter
          local ok_neotest, neotest = pcall(require, "neotest")
          if ok_neotest then
            neotest.setup({
              adapters = {
                require("neotest-python")({
                  dap = { justMyCode = false },
                  runner = "pytest",
                  python = python_bin,
                }),
              },
            })
            vim.notify("Neotest now using Python: " .. python_bin, vim.log.levels.INFO)
          end
        end,
      })
    end,
  },

  {
    "nvim-neotest/neotest-python",
    ft = "python",
  },

  {
    "mfussenegger/nvim-dap",
    config = function() end,
  },

  {
    "mfussenegger/nvim-dap-python",
    ft = "python",
    dependencies = { "mfussenegger/nvim-dap" },
    config = function()
      local ok_dap, dap_python = pcall(require, "dap-python")
      if ok_dap then
        dap_python.setup("python3", { test_runner = "pytest" }) -- use system Python initially
      else
        vim.notify("DAP-Python could not be initialized", vim.log.levels.WARN)
      end
    end,
  },
}
