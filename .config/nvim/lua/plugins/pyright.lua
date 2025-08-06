return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      -- Disable automatic setup for Python LSPs - we'll handle them manually
      pyright = false,
      ruff = false,
    },
  },
  config = function()
    -- Track client objects by root directory and server type
    local clients = {}
    -- Track buffer attachments to prevent redundant attachments
    local buffer_attachments = {}

    local function get_root_and_python(fname)
      local path = vim.fs.dirname(fname)

      -- Priority 1: pyrightconfig.json (pyright-specific)
      local pyright_config = vim.fs.find("pyrightconfig.json", { upward = true, path = path })[1]
      if pyright_config then
        local root = vim.fs.dirname(pyright_config)
        local python = vim.fs.joinpath(root, ".venv", "bin", "python")
        return root, vim.fn.executable(python) == 1 and python or nil
      end

      -- Priority 2: pyproject.toml (common for both pyright and ruff)
      local pyproject = vim.fs.find("pyproject.toml", { upward = true, path = path })[1]
      if pyproject then
        local root = vim.fs.dirname(pyproject)
        local python = vim.fs.joinpath(root, ".venv", "bin", "python")
        return root, vim.fn.executable(python) == 1 and python or nil
      end

      -- Priority 3: ruff.toml or .ruff.toml (ruff-specific)
      local ruff_config = vim.fs.find({ "ruff.toml", ".ruff.toml" }, { upward = true, path = path })[1]
      if ruff_config then
        local root = vim.fs.dirname(ruff_config)
        local python = vim.fs.joinpath(root, ".venv", "bin", "python")
        return root, vim.fn.executable(python) == 1 and python or nil
      end

      -- Priority 4: .venv directory (virtual environment marker)
      local function has_venv(dir)
        local stat = vim.uv.fs_stat(dir .. "/.venv/bin/python")
        return stat and stat.type == "file"
      end
      local venv_root = vim.fs.find(function(_, dir)
        return has_venv(dir)
      end, { upward = true, path = path })[1]
      if venv_root then
        local python = vim.fs.joinpath(venv_root, ".venv", "bin", "python")
        return venv_root, python
      end

      -- Priority 5: .git root (fallback)
      local git_dir = vim.fs.find(".git", { upward = true, path = path })[1]
      if git_dir then
        local root = vim.fs.dirname(git_dir)
        -- Try to find python in git root
        local python = vim.fs.joinpath(root, ".venv", "bin", "python")
        return root, vim.fn.executable(python) == 1 and python or nil
      end

      return nil, nil
    end

    local function setup_keymaps(client, bufnr)
      -- Get LazyVim's default LSP keymaps if available
      local has_lazyvim, lazyvim_lsp = pcall(require, "lazyvim.plugins.lsp.keymaps")
      if has_lazyvim and lazyvim_lsp.on_attach then
        lazyvim_lsp.on_attach(client, bufnr)
        return
      end

      -- Fallback to our own keymaps
      local function map(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
      end

      map("n", "gd", vim.lsp.buf.definition, "Go to Definition")
      map("n", "gr", vim.lsp.buf.references, "References")
      map("n", "gD", vim.lsp.buf.declaration, "Go to Declaration")
      map("n", "gI", vim.lsp.buf.implementation, "Go to Implementation")
      map("n", "gy", vim.lsp.buf.type_definition, "Go to Type Definition")
      map("n", "K", vim.lsp.buf.hover, "Hover Documentation")
      map("n", "gK", vim.lsp.buf.signature_help, "Signature Help")
      map("i", "<C-k>", vim.lsp.buf.signature_help, "Signature Help")
      map("n", "<leader>cr", vim.lsp.buf.rename, "Rename")
      map({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, "Code Action")

      if client.supports_method("textDocument/formatting") then
        map("n", "<leader>cf", function()
          vim.lsp.buf.format({ bufnr = bufnr })
        end, "Format Document")
      end

      vim.bo[bufnr].omnifunc = "v:lua.vim.lsp.omnifunc"
    end

    local function get_lazyvim_capabilities()
      -- Try to get LazyVim's default capabilities
      local ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
      local capabilities = ok and cmp_lsp.default_capabilities() or vim.lsp.protocol.make_client_capabilities()

      -- Fix position encoding conflicts between pyright (UTF-16) and ruff (UTF-8)
      -- Force both to use UTF-16 for consistency
      capabilities.general = capabilities.general or {}
      capabilities.general.positionEncodings = { "utf-16", "utf-8" }

      return capabilities
    end

    local function start_python_lsp(server_name, bufnr, root_dir, python_path)
      local client_key = server_name .. ":" .. root_dir

      -- Check if we already have this client
      if clients[client_key] and not clients[client_key].is_stopped() then
        vim.lsp.buf_attach_client(bufnr, clients[client_key].id)
        buffer_attachments[bufnr .. ":" .. client_key] = clients[client_key].id
        return
      end

      -- Clean up stopped client
      if clients[client_key] and clients[client_key].is_stopped() then
        clients[client_key] = nil
      end

      local config = {
        name = server_name .. "-" .. vim.fn.fnamemodify(root_dir, ":t"),
        root_dir = root_dir,
        filetypes = { "python" },
        single_file_support = false,
        capabilities = get_lazyvim_capabilities(),
        on_attach = setup_keymaps,
      }

      if server_name == "pyright" then
        config.cmd = { "pyright-langserver", "--stdio" }
        config.settings = {
          python = {
            pythonPath = python_path,
            analysis = {
              autoSearchPaths = true,
              useLibraryCodeForTypes = true,
              diagnosticMode = "workspace",
            },
          },
        }
      elseif server_name == "ruff" then
        config.cmd = { "ruff", "server", "--preview" }
        config.init_options = {
          settings = {
            interpreter = { python_path or "python" },
            -- Add any specific ruff settings here
          },
        }
      end

      local client_id = vim.lsp.start(config, { bufnr = bufnr })

      if client_id then
        local client = vim.lsp.get_client_by_id(client_id)
        clients[client_key] = client
        buffer_attachments[bufnr .. ":" .. client_key] = client_id
        local py_info = python_path and (" (Python: " .. python_path .. ")") or ""
        vim.notify("Started " .. config.name .. " for: " .. root_dir .. py_info, vim.log.levels.INFO)
      end
    end

    local function ensure_python_lsps_attached(bufnr)
      bufnr = bufnr or vim.api.nvim_get_current_buf()
      local fname = vim.api.nvim_buf_get_name(bufnr)

      -- Use vim.filetype.match for better filetype detection
      if fname == "" or vim.filetype.match({ buf = bufnr, filename = fname }) ~= "python" then
        return
      end

      local root_dir, python_path = get_root_and_python(fname)
      if not root_dir then
        vim.notify("No Python project root found for: " .. fname, vim.log.levels.WARN)
        return
      end

      -- Start both pyright and ruff for this project
      start_python_lsp("pyright", bufnr, root_dir, python_path)
      start_python_lsp("ruff", bufnr, root_dir, python_path)
    end

    -- Handle files opened before config loads and new files
    vim.api.nvim_create_autocmd("BufEnter", {
      pattern = "*.py",
      callback = function(args)
        ensure_python_lsps_attached(args.buf)
      end,
    })

    -- Clean up when buffers are deleted or unloaded
    vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
      pattern = "*.py",
      callback = function(args)
        local bufnr = args.buf

        -- Clean up buffer attachments and unused clients
        for key, client_id in pairs(buffer_attachments) do
          if key:match("^" .. bufnr .. ":") then
            buffer_attachments[key] = nil

            -- Extract server and root from key: "bufnr:server:root"
            local _, server_root = key:match("^" .. bufnr .. ":(.*)")

            -- Check if any other buffers are using this client
            local client_still_needed = false
            for other_key, _ in pairs(buffer_attachments) do
              if other_key:match(":" .. vim.pesc(server_root) .. "$") then
                client_still_needed = true
                break
              end
            end

            -- If no other buffers need this client, clean it up
            if not client_still_needed and clients[server_root] then
              if not clients[server_root].is_stopped() then
                clients[server_root].stop()
              end
              clients[server_root] = nil
            end
          end
        end
      end,
    })

    -- Ensure LSP attaches to already open Python files
    vim.schedule(function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
          local fname = vim.api.nvim_buf_get_name(bufnr)
          if fname ~= "" and vim.filetype.match({ buf = bufnr, filename = fname }) == "python" then
            ensure_python_lsps_attached(bufnr)
          end
        end
      end
    end)

    -- Command to manually restart Python LSPs for current buffer
    vim.api.nvim_create_user_command("PythonLspRestart", function()
      local bufnr = vim.api.nvim_get_current_buf()
      local fname = vim.api.nvim_buf_get_name(bufnr)
      local root_dir = get_root_and_python(fname)

      if root_dir then
        -- Stop both pyright and ruff clients for this root
        for _, server in ipairs({ "pyright", "ruff" }) do
          local client_key = server .. ":" .. root_dir
          if clients[client_key] and not clients[client_key].is_stopped() then
            clients[client_key].stop()
          end
          clients[client_key] = nil
        end

        -- Clear all buffer attachments for this root
        for key, _ in pairs(buffer_attachments) do
          if key:match(":" .. vim.pesc(root_dir) .. "$") then
            buffer_attachments[key] = nil
          end
        end

        vim.notify("Restarting Python LSPs for: " .. root_dir, vim.log.levels.INFO)
        vim.schedule(function()
          ensure_python_lsps_attached(bufnr)
        end)
      end
    end, { desc = "Restart Python LSPs for current project" })
  end,
}
