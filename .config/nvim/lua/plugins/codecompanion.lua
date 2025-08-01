return {
  "olimorris/codecompanion.nvim",
  keys = {
    { "<leader>aq", "<cmd>CodeCompanionChat<cr>", desc = "AI Question" },
  },
  config = function()
    require("codecompanion").setup({
      adapters = {
        openai = function()
          return require("codecompanion.adapters").extend("openai", {
            env = {
              api_key = "cmd:~/.local/bin/bw-auto-auth get password 'OpenAI API Key NVIM'",
            },
          })
        end,
      },
      strategies = {
        chat = {
          adapter = "openai",
        },
      },
      extensions = {
        mcphub = {
          callback = "mcphub.extensions.codecompanion",
          opts = {
            make_tools = true, -- Make individual tools (@server__tool) and server groups (@server) from MCP servers
            show_server_tools_in_chat = true, -- Show individual tools in chat completion (when make_tools=true)
            add_mcp_prefix_to_tool_names = false, -- Add mcp__ prefix (e.g `@mcp__github`, `@mcp__neovim__list_issues`)
            format_tool = nil, -- function(tool_name:string, tool: CodeCompanion.Agent.Tool) : string Function to format tool names to show in the chat buffer
            show_result_in_chat = true, -- Show search results in chat
            make_vars = true, -- Convert resources to #variables
            make_slash_commands = true, -- Add prompts as /slash commands
          },
        },
      },
      display = {
        action_palette = {
          width = 95,
          height = 10,
        },
        chat = {
          window = {
            layout = "vertical", -- or "horizontal", "buffer"
            width = 0.45, -- percentage of screen width
            -- height = 0.8, -- percentage of screen height
            relative = "editor",
            opts = {
              breakindent = true,
              cursorcolumn = false,
              cursorline = false,
              foldcolumn = "0",
              linebreak = true,
              list = false,
              signcolumn = "no",
              spell = false,
              wrap = true,
            },
          },
          intro_message = "Welcome to CodeCompanion! How can I help you today?",
          separator = "─", -- Character used for separators
          show_settings = true, -- Show model settings in chat
          show_token_count = true, -- Show token usage
          render_headers = false,
        },
      },
      opts = {
        log_level = "ERROR", -- Reduce noise in messages
        send_code = true, -- Include code context automatically
        use_default_actions = true,
        use_default_prompts = true,
      },
      -- Enhanced highlighting
      highlight = {
        prefix = "AI",
      },
    })
  end,
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-treesitter/nvim-treesitter",
    {
      "MunifTanjim/nui.nvim", -- Better UI components
      lazy = true,
    },
    {
      "MeanderingProgrammer/render-markdown.nvim",
      ft = { "markdown", "codecompanion" }, -- Include codecompanion filetype
      opts = {
        render_modes = true, -- Render in all modes, not just normal
        sign = { enabled = false }, -- Turn off signs in gutter
      },
    },
    {
      "ravitemer/mcphub.nvim",
      build = "bundled_build.lua",
      config = function()
        require("mcphub").setup({
          use_bundled_binary = true, -- Let MCP Hub handle server installation
          log_level = "info", -- Change to "debug" when troubleshooting
        })
      end,
    },
  },
}
