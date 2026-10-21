---@type LazySpec
-- NOTE: nvim-dap has no `setup()` function.
-- LazyVim's `lang.clangd` extra declares it with `opts = function() ... end`
-- (registers codelldb adapters/configurations) but no `config`. lazy.nvim then falls
-- back to `require("dap").setup(opts)`, which errors at startup because nvim-dap's
-- configuration API is just the `dap.adapters` / `dap.configurations` tables.
-- Declaring `config` here makes lazy.nvim use it instead of guessing `setup()`.
-- The clangd extra's `opts` function still runs beforehand through lazy.nvim's spec merge.
return {
  "mfussenegger/nvim-dap",
  config = function() end,
}
