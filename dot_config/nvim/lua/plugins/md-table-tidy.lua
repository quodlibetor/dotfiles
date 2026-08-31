local ns = vim.api.nvim_create_namespace("TableTidyJJComments")

-- Markdown highlights at treesitter's usual 100, so everything here outranks
-- it. Within our own marks the JJ: block wins over the diff, because the
-- "lines starting with JJ: will be removed" trailer sits inside the diff region.
local DIFF_PRIORITY = 200
local COMMENT_PRIORITY = 210
local STATUS_PRIORITY = 211

-- Matching syntax/jjdescription.vim, which we lose to the markdown highlighter.
local STATUS = { A = "Added", D = "Removed", M = "Changed" }

---Highlight the diff jj appends after JJ: ignore-rest, which markdown would
---otherwise render as prose and indented code.
---@param buf integer
---@param first_row integer 0-based row of the first diff line
---@param lines string[]
local function mark_diff(buf, first_row, lines)
  if #lines == 0 then
    return
  end
  local text = table.concat(lines, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "diff")
  if not ok then
    return
  end
  local tree = (parser:parse() or {})[1]
  local query = vim.treesitter.query.get("diff", "highlights")
  if not tree or not query then
    return
  end

  -- Blank the markdown highlighting out first: a context line reads as an
  -- indented code block to the markdown grammar, and diff has no capture of
  -- its own to put over it.
  vim.api.nvim_buf_set_extmark(buf, ns, first_row, 0, {
    end_row = first_row + #lines,
    end_col = 0,
    hl_group = "Normal",
    priority = DIFF_PRIORITY - 1,
  })

  -- Query order is precedence order, and equal-priority extmarks resolve by
  -- age, so setting them in iteration order keeps treesitter's own semantics.
  for id, node in query:iter_captures(tree:root(), text) do
    local start_row, start_col, end_row, end_col = node:range()
    vim.api.nvim_buf_set_extmark(buf, ns, first_row + start_row, start_col, {
      end_row = first_row + end_row,
      end_col = end_col,
      hl_group = "@" .. query.captures[id],
      priority = DIFF_PRIORITY,
    })
  end
end

---@param buf integer
local function mark_jj(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    if line:find("^JJ:%s*ignore%-rest") then
      mark_diff(buf, i, vim.list_slice(lines, i + 1))
      break
    end
  end

  for row, line in ipairs(lines) do
    if line:find("^JJ:") then
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
        end_col = #line,
        hl_group = "Comment",
        priority = COMMENT_PRIORITY,
      })
      local col, kind = line:match("^JJ:%s+()([ADM]) ")
      if col then
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, col - 1, {
          end_col = #line,
          hl_group = STATUS[kind],
          priority = STATUS_PRIORITY,
        })
      end
    end
  end
end

return {
  "timantipov/md-table-tidy.nvim",
  opts = {
    padding = 1, -- number of spaces for cell padding
    keymap = {
      table_tidy = "<leader>TT", -- key for command :TableTidy<CR>
      table_tidy_all = "<leader>TA", -- key for command :TableTidyAll<CR>
    },
  },
  config = function(_, opts)
    local tidy = require("md-table-tidy")
    tidy.setup(opts)

    -- setup() only arms markdown buffers, but jj describe writes a
    -- .jjdescription file and its tables are markdown.
    vim.treesitter.language.register("markdown", "jjdescription")
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("TableTidyJJ", { clear = true }),
      pattern = "jjdescription",
      callback = function(args)
        -- :TableTidy finds the table via vim.treesitter.get_node(), which reads
        -- whatever tree is already parsed rather than parsing one itself. In a
        -- markdown buffer the highlighter keeps that tree fresh; here nothing
        -- would, so a parse-once would go stale on the first edit and tidy the
        -- table as it looked when the buffer opened. :TableTidyAll parses for
        -- itself and works either way.
        vim.treesitter.start(args.buf, "markdown")
        tidy.register_user_commands(args.buf)
        tidy.register_keymap(args.buf)

        mark_jj(args.buf)
        -- A buffer-local autocmd dies with its buffer, so the group stays the
        -- one group; the flag is only to survive a second FileType on the
        -- same buffer without doubling up.
        if not vim.b[args.buf].md_table_tidy_jj then
          vim.b[args.buf].md_table_tidy_jj = true
          vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            group = "TableTidyJJ",
            buffer = args.buf,
            callback = function()
              mark_jj(args.buf)
            end,
          })
        end
      end,
    })
  end,
}
