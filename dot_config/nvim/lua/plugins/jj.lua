vim.api.nvim_create_user_command("JJdiff", function()
  local left_contents = vim.api.nvim_buf_get_lines(0, 0, -1, true)
  -- close $left
  vim.cmd.diffoff()
  vim.cmd.close()
  -- put contents of $left into $output
  vim.api.nvim_buf_set_lines(0, 0, -1, true, left_contents)
end, { desc = "jj diff setup" })

return {
  {
    "rafikdraoui/jj-diffconflicts",
  }
}
