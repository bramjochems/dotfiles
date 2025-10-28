return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      pyright = false,
      ruff = false,
    },
  },
  config = function()
    -- Prefer .git over LSP root to avoid LazyVim overriding cwd in mono-repos
    vim.g.root_spec = { { ".git", "lua" }, "lsp", "cwd" }

    local DEBUG = false
    local function log(msg, lvl)
      if DEBUG then
        vim.notify(msg, lvl or vim.log.levels.INFO)
      end
    end

    local is_windows = vim.loop.os_uname().version:match("Windows")
    local function venv_python(root)
      if is_windows then
        local p = root .. "/.venv/Scripts/python.exe"
        return (vim.fn.executable(p) == 1) and p or nil
      else
        local p = root .. "/.venv/bin/python"
        return (vim.fn.executable(p) == 1) and p or nil
      end
    end

    -- Cache root -> python for this session
    local python_cache = {}

    local clients = {} -- key: "<server>:<root>" -> client
    local buffer_attachments = {} -- bufnr -> { [client_key]=client_id }

    local function get_root_and_python(fname)
      local path = vim.fs.dirname(fname)

      -- 1) pyrightconfig.json
      local pyright_config = vim.fs.find("pyrightconfig.json", { upward = true, path = path })[1]
      if pyright_config then
        local root = vim.fs.dirname(pyright_config)
        python_cache[root] = python_cache[root] or venv_python(root)
        return root, python_cache[root]
      end

      -- 2) pyproject.toml
      local pyproject = vim.fs.find("pyproject.toml", { upward = true, path = path })[1]
      if pyproject then
        local root = vim.fs.dirname(pyproject)
        python_cache[root] = python_cache[root] or venv_python(root)
        return root, python_cache[root]
      end

      -- 3) ruff.toml / .ruff.toml
      local ruff_config = vim.fs.find({ "ruff.toml", ".ruff.toml" }, { upward = true, path = path })[1]
      if ruff_config then
        local root = vim.fs.dirname(ruff_config)
        python_cache[root] = python_cache[root] or venv_python(root)
        return root, python_cache[root]
      end

      -- 4) climb until a directory that contains .venv python
      local function has_venv(dir)
        if is_windows then
          local st = vim.uv.fs_stat(dir .. "/.venv/Scripts/python.exe")
          return st and st.type == "file"
        else
          local st = vim.uv.fs_stat(dir .. "/.venv/bin/python")
          return st and st.type == "file"
        end
      end
      local venv_root = vim.fs.find(function(_, dir)
        return has_venv(dir)
      end, { upward = true, path = path })[1]
      if venv_root then
        python_cache[venv_root] = python_cache[venv_root] or venv_python(venv_root)
        return venv_root, python_cache[venv_root]
      end

      -- 5) fallback: .git
      local git_dir = vim.fs.find(".git", { upward = true, path = path })[1]
      if git_dir then
        local root = vim.fs.dirname(git_dir)
        python_cache[root] = python_cache[root] or venv_python(root)
        return root, python_cache[root]
      end

      return nil, nil
    end

    local function capabilities()
      local ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
      return ok and cmp_lsp.default_capabilities() or vim.lsp.protocol.make_client_capabilities()
    end

    local lazy_on_attach = function(client, bufnr)
      local ok, keymaps = pcall(require, "lazyvim.plugins.lsp.keymaps")
      if ok and keymaps.on_attach then
        keymaps.on_attach(client, bufnr)
      end
    end

    local function can_exec(bin)
      return vim.fn.executable(bin) == 1
    end

    local function start_python_lsp(server, bufnr, root_dir, python_path)
      local client_key = server .. ":" .. root_dir

      if clients[client_key] and not clients[client_key].is_stopped() then
        vim.lsp.buf_attach_client(bufnr, clients[client_key].id)
        buffer_attachments[bufnr] = buffer_attachments[bufnr] or {}
        buffer_attachments[bufnr][client_key] = clients[client_key].id
        return
      end
      if clients[client_key] and clients[client_key].is_stopped() then
        clients[client_key] = nil
      end

      local cfg = {
        name = server .. "-" .. vim.fn.fnamemodify(root_dir, ":t"),
        root_dir = root_dir,
        filetypes = { "python" },
        single_file_support = false,
        capabilities = capabilities(),
        on_attach = lazy_on_attach,
      }

      if server == "pyright" then
        if not can_exec("pyright-langserver") then
          log("pyright-langserver not found on PATH, skipping", vim.log.levels.WARN)
          return
        end
        cfg.cmd = { "pyright-langserver", "--stdio" }
        cfg.settings = {
          python = {
            pythonPath = python_path or "python",
            analysis = {
              autoSearchPaths = true,
              useLibraryCodeForTypes = true,
              diagnosticMode = "workspace",
            },
          },
        }
      elseif server == "ruff" then
        -- You can switch to ruff-lsp by using cmd = { "ruff-lsp" } if you prefer.
        if not can_exec("ruff") then
          log("ruff not found on PATH, skipping", vim.log.levels.WARN)
          return
        end
        cfg.cmd = { "ruff", "server", "--preview" }
        cfg.init_options = { settings = { interpreter = { python_path or "python" } } }
      end

      local id = vim.lsp.start(cfg, { bufnr = bufnr })
      if id then
        local client = vim.lsp.get_client_by_id(id)
        clients[client_key] = client
        buffer_attachments[bufnr] = buffer_attachments[bufnr] or {}
        buffer_attachments[bufnr][client_key] = id
        log(
          ("Started %s for %s%s"):format(cfg.name, root_dir, python_path and (" (python: " .. python_path .. ")") or "")
        )
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
        log("No Python project root for " .. fname, vim.log.levels.WARN)
        return
      end

      start_python_lsp("pyright", bufnr, root_dir, python_path)
      start_python_lsp("ruff", bufnr, root_dir, python_path)
    end

    vim.api.nvim_create_autocmd("BufEnter", {
      pattern = "*.py",
      callback = function(args)
        ensure_attached(args.buf)
      end,
    })

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

          for client_key, _ in pairs(bucket) do
            bucket[client_key] = nil
            local still_needed = false
            for other_buf, other_bucket in pairs(buffer_attachments) do
              if other_buf ~= bufnr and other_bucket and other_bucket[client_key] then
                still_needed = true
                break
              end
            end
            if not still_needed and clients[client_key] then
              local ok, stopped = pcall(function()
                return clients[client_key].is_stopped()
              end)
              if ok and not stopped then
                pcall(clients[client_key].stop, clients[client_key])
              end
              clients[client_key] = nil
              log("Stopped " .. client_key)
            end
          end

          buffer_attachments[bufnr] = nil
        end)
      end,
    })

    -- Reattach after venv change (venv-selector.nvim)
    vim.api.nvim_create_autocmd("User", {
      pattern = "VenvSelectActivated",
      callback = function()
        local b = vim.api.nvim_get_current_buf()
        -- Clear cached python for this root; next attach will pick the new venv
        local fname = vim.api.nvim_buf_get_name(b)
        local root = (function()
          local r = { get_root_and_python(fname) }
          return r[1]
        end)()
        if root then
          python_cache[root] = nil
        end
        ensure_attached(b)
      end,
    })

    -- Attach for already-open Python buffers
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

    vim.api.nvim_create_user_command("PythonLspRestart", function()
      local b = vim.api.nvim_get_current_buf()
      local f = vim.api.nvim_buf_get_name(b)
      local r = { get_root_and_python(f) }
      local root = r[1]
      if not root then
        vim.notify("No Python project root for current buffer.", vim.log.levels.WARN)
        return
      end
      for _, server in ipairs({ "pyright", "ruff" }) do
        local key = server .. ":" .. root
        if clients[key] and not clients[key].is_stopped() then
          pcall(clients[key].stop, clients[key])
        end
        clients[key] = nil
      end
      for bufnr, bucket in pairs(buffer_attachments) do
        if bucket then
          for key, _ in pairs(bucket) do
            if key:sub(-#root) == root then
              bucket[key] = nil
            end
          end
        end
      end
      python_cache[root] = nil
      vim.notify("Restarting Python LSPs for: " .. root, vim.log.levels.INFO)
      vim.schedule(function()
        ensure_attached(b)
      end)
    end, { desc = "Restart Python LSPs for current project" })
  end,
}
