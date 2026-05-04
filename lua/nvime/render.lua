local M = {}

function M.scrollback(bufnr, ns)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_code = false
  local code_lang = nil

  local function mark(row, start_col, end_col, group, opts)
    if row < 0 or row >= #lines then
      return
    end
    opts = opts or {}
    opts.end_col = math.min(end_col, #(lines[row + 1] or ""))
    opts.hl_group = group
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, start_col, opts)
  end

  local function mark_line(row, group)
    if row < 0 or row >= #lines then
      return
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      end_col = #(lines[row + 1] or ""),
      hl_group = group,
      hl_eol = true,
    })
  end

  for index, line in ipairs(lines) do
    local row = index - 1
    if line:match("^```") then
      mark(row, 0, #line, "NvimeCodeFence")
      if in_code then
        in_code = false
        code_lang = nil
      else
        in_code = true
        code_lang = vim.trim(line:gsub("^```", ""))
      end
    elseif in_code then
      if code_lang == "diff" and line:match("^%+") and not line:match("^%+%+%+") then
        mark_line(row, "NvimeDiffAdd")
      elseif code_lang == "diff" and line:match("^%-") and not line:match("^%-%-%-") then
        mark_line(row, "NvimeDiffDelete")
      elseif code_lang == "diff" and line:match("^@@") then
        mark_line(row, "NvimeDiffHunk")
      else
        mark_line(row, "NvimeCode")
      end
    elseif line:match("^%[[^%]]+%]%$") then
      local finish = line:find("%$") or #line
      mark(row, 0, finish + 1, "NvimePrompt")
      if finish + 1 < #line then
        mark(row, finish + 1, #line, "NvimeUserText")
      end
    elseif line:match("^%[[^%]]+ response%]$") then
      mark(row, 0, #line, "NvimeAgent")
    elseif line:match("^%[[^%]]+ selection question%]$") then
      mark(row, 0, #line, "NvimeAgent")
    elseif line:match("^%[nvime%]") then
      mark(row, 0, #line, "NvimeExit")
    elseif line:match("^%[error%]") or line:match("^%[failed%]") then
      mark(row, 0, #line, "NvimeError")
    elseif line:match("^#+%s+") then
      mark(row, 0, #line, "NvimeMarkdownHeading")
    elseif line:match("^%s*[-*]%s+") then
      local start_col = line:find("[-*]")
      if start_col then
        mark(row, start_col - 1, start_col + 1, "NvimeBullet")
      end
    elseif line:match("^%s*>%s+") then
      mark(row, 0, #line, "NvimeQuote")
    elseif line:match("^@@") then
      mark_line(row, "NvimeDiffHunk")
    elseif line:match("^%+") and not line:match("^%+%+%+") then
      mark_line(row, "NvimeDiffAdd")
    elseif line:match("^%-") and not line:match("^%-%-%-") and not line:match("^%-%-+$") then
      mark_line(row, "NvimeDiffDelete")
    elseif line:match("^[=-]+$") then
      mark(row, 0, #line, "NvimeRule")
    end

    local search_from = 1
    while true do
      local strong_start, strong_end = line:find("%*%*.-%*%*", search_from)
      if not strong_start then
        break
      end
      mark(row, strong_start - 1, strong_end, "NvimeMarkdownStrong")
      search_from = strong_end + 1
    end
  end
end

function M.input(bufnr, ns, prompt_prefix, start_lnum)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  start_lnum = start_lnum or 1
  if lines[start_lnum] then
    vim.api.nvim_buf_set_extmark(bufnr, ns, start_lnum - 1, 0, {
      end_col = #lines[start_lnum],
      hl_group = "NvimeInputStatus",
    })
  end
  local prompt_lnum = start_lnum + 1
  local prompt_line = lines[prompt_lnum] or ""
  if vim.startswith(prompt_line, prompt_prefix) then
    vim.api.nvim_buf_set_extmark(bufnr, ns, prompt_lnum - 1, 0, {
      end_col = #prompt_prefix,
      hl_group = "NvimeInputPrompt",
    })
    if #prompt_line > #prompt_prefix then
      vim.api.nvim_buf_set_extmark(bufnr, ns, prompt_lnum - 1, #prompt_prefix, {
        end_col = #prompt_line,
        hl_group = "NvimeUserText",
      })
    end
  end
end

return M
