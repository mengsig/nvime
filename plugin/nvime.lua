if vim.g.loaded_nvime == 1 then
  return
end

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("nvime requires Neovim 0.10+", vim.log.levels.ERROR)
  return
end

vim.g.loaded_nvime = 1

require("nvime").setup()
