---@type LazySpec
-- NOTE: Neovim LSP Configuration
return {
  "neovim/nvim-lspconfig",
  opts = function(_, opts)
    local custom_path = "plugins.lsp.settings"

    -- Diagnostics are provided by Neovim's builtin vim.diagnostic, not by a plugin.
    -- LazyVim enables underline + signs + virtual_text by default; disable all rendering.
    -- LSP still works (goto, completion, rename, format); use trouble.nvim to inspect diagnostics.
    opts.diagnostics = vim.tbl_deep_extend("force", opts.diagnostics or {}, {
      underline = false,
      virtual_text = false,
      virtual_lines = false,
      signs = false,
      update_in_insert = false,
    })

    local disabled_servers = {
      "phpactor",
      "rust_analyzer",
      "omnisharp",
      -- add more if needed
    }

    local function is_disabled(server)
      return vim.tbl_contains(disabled_servers, server)
    end

    local function extend_server(server)
      -- Skip disabled servers
      if is_disabled(server) then
        return
      end

      -- Try to load custom settings
      local ok, custom = pcall(require, custom_path .. "." .. server)
      if ok and type(custom) == "table" then
        opts.servers[server] = vim.tbl_deep_extend("force", opts.servers[server] or {}, custom)
      end
    end

    -- Dynamically detect all server config files
    local settings_dir = vim.fn.stdpath("config") .. "/lua/" .. custom_path:gsub("%.", "/")
    local files = vim.fn.glob(settings_dir .. "/*.lua", false, true)

    for _, file in ipairs(files) do
      local server = vim.fn.fnamemodify(file, ":t:r")
      extend_server(server)
    end

    return opts
  end,
}
