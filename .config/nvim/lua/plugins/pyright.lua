-- ~/.config/nvim/lua/plugins/pyright.lua
return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      -- We'll manage these manually
      pyright = false,
      ruff = false,
    },
  },
  config = function()
    -- Prefer .git for project root, then LSP, then cwd (LazyVim respects this)
    vim.g.root_spec = { { ".git", "lua" }, "lsp", "cwd" }

    -- Track running clients by "<server>:<root_dir>"
    local clients = {}
    -- Track which clients are attached to which buffers: buffer_attachments[bufnr][client_key] = client_id
    local buffer_attachments = {}

    local function get_root_and_python(fname)
      local path = vim.fs.dirname(fname)

      -- 1) pyrightconfig.json
      local pyright_config = vim.fs.find("pyrightconfig.json", { upward = true, path = path })[1]
      if pyright_config then
        local root = vim.fs.dirname(pyright_config)
        local py = vim.fs.joinpath(root, ".venv", "bin", "python")
        return root, (vim.fn.executable(py) == 1 and py or nil)
      end

      -- 2) pyproject.toml
      local pyproject = vim.fs.find("pyproject.toml", { upward = true, path = path })[1]
      if pyproject then
        local root = vim.fs.dirname(pyproject)
        local py = vim.fs.joinpath(root, ".venv", "bin", "python")
        return root, (vim.fn.executable(py) == 1 and py or nil)
      end

      -- 3) ruff.{toml} / .ruff.toml
      local ruff_config = vim.fs.find({ "ruff.toml", ".ruff.toml" }, { upward = true, path = path })[1]
      if ruff_config then
        local root = vim.fs.dirname(ruff_config)
        local py = vim.fs.joinpath(root, ".venv", "bin", "python")
        return root, (vim.fn.executable(py) == 1 and py or nil)
      end

      -- 4) climb until a directory that contains .venv/bin/python
      local function has_venv(dir)
        local st = vim.uv.fs_stat(dir .. "/.venv/bin/python")
        return st and st.type == "file"
      end
      local venv_root = vim.fs.find(function(_, dir)
        return has_venv(dir)
      end, { upward = true, path = path })[1]
      if venv_root then
        local py = vim.fs.joinpath(venv_root, ".venv", "bin", "python")
        return venv_root, py
      end

      -- 5) fallback: .git root
      local git_dir = vim.fs.find(".git", { upward = true, path = path })[1]
      if git_dir then
        local root = vim.fs.dirname(git_dir)
        local py = vim.fs.joinpath(root, ".venv", "bin", "python")
        return root, (vim.fn.executable(py) == 1 and py or nil)
      end

      return nil, nil
    end

    local function setup_keymaps(client, bufnr)
      -- Delegate to LazyVim defaults if available
      local ok, lazyvim_lsp = pcall(require, "lazyvim.plugins.lsp.keymaps")
      if ok and lazyvim_lsp.on_attach then
        lazyvim_lsp.on_attach(client, bufnr)
        return
      end

      -- Minimal fallbacks
      local function map(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
      end
      map("n", "gd", vim.lsp.buf.definition, "Go to Definition")
      map("n", "gr", vim.lsp.buf.references, "References")
      map("n", "gD", vim.lsp.buf.declaration, "Go to Declaration")
      map("n", "gI", vim.lsp.buf.implementation, "Go to Implementation")
      map("n", "gy", vim.lsp.buf.type_definition, "Go to Type Definition")
      map("n", "K", vim.lsp.buf.hover, "Hover")
      map("n", "<leader>cr", vim.lsp.buf.rename, "Rename")
      map({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, "Code Action")
      if client.supports_method("textDocument/formatting") then
        map("n", "<leader>cf", function()
          vim.lsp.buf.format({ bufnr = bufnr })
        end, "Format")
      end
      vim.bo[bufnr].omnifunc = "v:lua.vim.lsp.omnifunc"
    end

    local function capabilities()
      local ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
      local caps = ok and cmp_lsp.default_capabilities() or vim.lsp.protocol.make_client_capabilities()
      -- Encourage consistent encoding between pyright(UTF-16) and ruff
      caps.general = caps.general or {}
      caps.general.positionEncodings = { "utf-16", "utf-8" }
      return caps
    end

    local function start_python_lsp(server, bufnr, root_dir, python_path)
      local client_key = server .. ":" .. root_dir

      -- Reuse existing client if present
      if clients[client_key] and not clients[client_key].is_stopped() then
        vim.lsp.buf_attach_client(bufnr, clients[client_key].id)
        buffer_attachments[bufnr] = buffer_attachments[bufnr] or {}
        buffer_attachments[bufnr][client_key] = clients[client_key].id
        return
      end

      -- Remove tombstone
      if clients[client_key] and clients[client_key].is_stopped() then
        clients[client_key] = nil
      end

      local cfg = {
        name = server .. "-" .. vim.fn.fnamemodify(root_dir, ":t"),
        root_dir = root_dir,
        filetypes = { "python" },
        single_file_support = false,
        capabilities = capabilities(),
        on_attach = setup_keymaps,
      }

      if server == "pyright" then
        cfg.cmd = { "pyright-langserver", "--stdio" }
        cfg.settings = {
          python = {
            pythonPath = python_path,
            analysis = {
              autoSearchPaths = true,
              useLibraryCodeForTypes = true,
              diagnosticMode = "workspace",
            },
          },
        }
      elseif server == "ruff" then
        cfg.cmd = { "ruff", "server", "--preview" }
        cfg.init_options = {
          settings = {
            interpreter = { python_path or "python" },
          },
        }
      end

      local client_id = vim.lsp.start(cfg, { bufnr = bufnr })
      if client_id then
        local client = vim.lsp.get_client_by_id(client_id)
        clients[client_key] = client
        buffer_attachments[bufnr] = buffer_attachments[bufnr] or {}
        buffer_attachments[bufnr][client_key] = client_id
        local py_info = python_path and (" (Python: " .. python_path .. ")") or ""
        vim.notify("Started " .. cfg.name .. " for " .. root_dir .. py_info, vim.log.levels.INFO)
      end
    end

    local function ensure_attached(bufnr)
      bufnr = bufnr or vim.api.nvim_get_current_buf()
      local fname = vim.api.nvim_buf_get_name(bufnr)
      if fname == "" then
        return
      end
      if vim.filetype.match({ buf = bufnr, filename = fname }) ~= "python" then
        return
      end

      local root_dir, python_path = get_root_and_python(fname)
      if not root_dir then
        vim.notify("No Python project root found for: " .. fname, vim.log.levels.WARN)
        return
      end

      start_python_lsp("pyright", bufnr, root_dir, python_path)
      start_python_lsp("ruff", bufnr, root_dir, python_path)
    end

    -- Attach on Python buffer enter
    vim.api.nvim_create_autocmd("BufEnter", {
      pattern = "*.py",
      callback = function(args)
        ensure_attached(args.buf)
      end,
    })

    -- Cleanup when buffers go away
    vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
      pattern = "*.py",
      callback = function(args)
        local bufnr = args.buf
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        vim.schedule(function()
          local bucket = buffer_attachments[bufnr]
          if not bucket then
            return
          end

          -- For each client this buffer used…
          for client_key, _ in pairs(bucket) do
            bucket[client_key] = nil

            -- …check if any other buffer still uses it
            local still_needed = false
            for other_bufnr, other_bucket in pairs(buffer_attachments) do
              if other_bufnr ~= bufnr and other_bucket and other_bucket[client_key] then
                still_needed = true
                break
              end
            end

            -- Stop the LSP if nobody else needs it
            if not still_needed and clients[client_key] then
              local ok, stopped = pcall(function()
                return clients[client_key].is_stopped()
              end)
              if ok and not stopped then
                pcall(clients[client_key].stop, clients[client_key])
              end
              clients[client_key] = nil
            end
          end

          buffer_attachments[bufnr] = nil
        end)
      end,
    })

    -- Attach for already-open Python buffers (when config loads)
    vim.schedule(function()
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
          local f = vim.api.nvim_buf_get_name(b)
          if f ~= "" and vim.filetype.match({ buf = b, filename = f }) == "python" then
            ensure_attached(b)
          end
        end
      end
    end)

    -- Manual restart command for current project
    vim.api.nvim_create_user_command("PythonLspRestart", function()
      local bufnr = vim.api.nvim_get_current_buf()
      local fname = vim.api.nvim_buf_get_name(bufnr)
      local root_dir = (function()
        local r = { get_root_and_python(fname) }
        return r[1]
      end)()
      if not root_dir then
        vim.notify("No Python project root for current buffer.", vim.log.levels.WARN)
        return
      end

      for _, server in ipairs({ "pyright", "ruff" }) do
        local client_key = server .. ":" .. root_dir
        if clients[client_key] and not clients[client_key].is_stopped() then
          pcall(clients[client_key].stop, clients[client_key])
        end
        clients[client_key] = nil
      end

      -- clear any buffer->client mappings for this root
      for b, bucket in pairs(buffer_attachments) do
        if bucket then
          for client_key, _ in pairs(bucket) do
            if client_key:sub(-#root_dir) == root_dir then
              bucket[client_key] = nil
            end
          end
        end
      end

      vim.notify("Restarting Python LSPs for: " .. root_dir, vim.log.levels.INFO)
      vim.schedule(function()
        ensure_attached(bufnr)
      end)
    end, { desc = "Restart Python LSPs for current project" })
  end,
}
