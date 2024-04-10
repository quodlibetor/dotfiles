return {
  "stevearc/conform.nvim",
  opts = {
    formatters = {
      shfmt = {
        args = { "--indent", "4", "--case-indent", "--binary-next-line" },
      },
    },
  },
}
