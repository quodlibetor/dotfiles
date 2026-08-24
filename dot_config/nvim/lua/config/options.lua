-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Format on write (conform.nvim; stylua for lua). Explicit so it doesn't ride
-- on a LazyVim default. Toggle per-buffer/globally with <leader>uf / <leader>uF.
vim.g.autoformat = true

vim.g.lazyvim_python_lsp = "basedpyright"
