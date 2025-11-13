-- https://github.com/qvalentin/helm-ls.nvim
return {
  "qvalentin/helm-ls.nvim",
  ft = "helm",
  opts = {
    conceal_templates = {
      -- enable the replacement of templates with virtual text of their current values
      enabled = false,   -- this might change to false in the future
    },
    indent_hints = {
      -- enable hints for indent and nindent functions
      enabled = false,
      -- show the hints only for the line the cursor is on
      only_for_current_line = true,
    },
  }
}
