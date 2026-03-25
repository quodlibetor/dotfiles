return {
  { "miikanissi/modus-themes.nvim", priority = 1000 },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = vim.o.background == "light" and "modus_operandi" or "modus_vivendi",
    },
  },
}
