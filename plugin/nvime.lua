if vim.g.loaded_nvime == 1 then
  return
end

vim.g.loaded_nvime = 1

require("nvime").setup()
