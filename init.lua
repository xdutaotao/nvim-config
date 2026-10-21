require("config.lazy")
require("config.commands")
require("config.filetypes")
require("config.utils")
require("config.archive").setup()

if vim.g.vscode then
  vim.opt.shortmess:append("s")
  vim.opt.cmdheight = 1
end
