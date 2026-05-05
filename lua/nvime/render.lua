local ui = require("nvime.ui")

local M = {}

local function provider_group(provider)
  if provider == "claude" then
    return "NvimeProviderClaude"
  end
  if provider == "codex" then
    return "NvimeProviderCodex"
  end
  return "NvimePrompt"
end

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
    local line_len = #(lines[row + 1] or "")
    start_col = math.max(0, math.min(start_col, line_len))
    end_col = math.max(start_col, math.min(end_col, line_len))
    if start_col == end_col then
      return
    end
    opts = opts or {}
    opts.end_col = end_col
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

  local function label(row, text, group)
    if row < 0 or row >= #lines then
      return
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      virt_text = { { text, group or "NvimeMuted" } },
      virt_text_pos = "right_align",
      priority = 120,
    })
  end

  for index, line in ipairs(lines) do
    local row = index - 1
    if line:match("^```") then
      mark(row, 0, #line, "NvimeCodeFence")
      local lang = vim.trim(line:gsub("^```", ""))
      if lang ~= "" then
        label(row, lang, "NvimeMuted")
      end
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
      local provider = line:match("^%[([^%s%]]+)")
      local finish = line:find("%$") or #line
      mark(row, 0, finish + 1, "NvimePrompt")
      if provider then
        mark(row, 1, 1 + #provider, provider_group(provider))
      end
      if finish + 1 < #line then
        mark(row, finish + 1, #line, "NvimeUserText")
      end
      label(row, "user", "NvimeMuted")
    elseif line:match("^%[[^%]]+ response%]$") then
      local provider = line:match("^%[([^%s%]]+)")
      mark(row, 0, #line, "NvimeAgent")
      if provider then
        mark(row, 1, 1 + #provider, provider_group(provider))
      end
      label(row, ui.icon("review") .. " agent", "NvimeAgent")
    elseif line:match("^%[[^%]]+ selection question%]$") then
      mark(row, 0, #line, "NvimeAgent")
      label(row, ui.icon("selection") .. " selection", "NvimeAgent")
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

function M.input(bufnr, ns, prompt_prefix, start_lnum, opts)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  opts = opts or {}
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  start_lnum = start_lnum or 1
  local prompt_lnum = start_lnum
  if lines[start_lnum] and not vim.startswith(lines[start_lnum], prompt_prefix) then
    vim.api.nvim_buf_set_extmark(bufnr, ns, start_lnum - 1, 0, {
      end_col = #lines[start_lnum],
      hl_group = "NvimeInputStatus",
    })
    prompt_lnum = start_lnum + 1
  end
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
    elseif opts.show_ghost ~= false then
      vim.api.nvim_buf_set_extmark(bufnr, ns, prompt_lnum - 1, #prompt_prefix, {
        virt_text = { { opts.ghost or "type a message", "NvimeInputGhost" } },
        virt_text_pos = "eol",
        priority = 90,
      })
    end
    if opts.divider ~= false then
      local rule_width = opts.rule_width or vim.o.columns
      local winid = vim.fn.bufwinid(bufnr)
      if winid > 0 then
        rule_width = vim.api.nvim_win_get_width(winid)
      end
      rule_width = math.max(20, rule_width - 2)
      local virt_lines = {}
      if opts.busy_status and opts.busy_status ~= "" then
        local pad = math.max(0, rule_width - vim.fn.strdisplaywidth(opts.busy_status))
        virt_lines[#virt_lines + 1] = {
          { string.rep(" ", pad), "" },
          { opts.busy_status, "NvimeStatusRunning" },
        }
      end
      virt_lines[#virt_lines + 1] = { { string.rep("─", rule_width), "NvimeRule" } }
      vim.api.nvim_buf_set_extmark(bufnr, ns, prompt_lnum - 1, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
        priority = 80,
      })
    end
  end
end

function M.spinner_text(seed)
  local cfg = (require("nvime.state").config or {}).ui or {}
  local frames = cfg.spinner_frames
  if type(frames) ~= "table" or #frames == 0 then
    frames = cfg.ascii_icons == true and { "-", "\\", "|", "/" } or { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  end
  if tonumber(seed) then
    seed = tonumber(seed)
  else
    local uv = vim.uv or vim.loop
    seed = uv and uv.hrtime and math.floor(uv.hrtime() / 120000000) or os.time()
  end
  return frames[(seed % #frames) + 1]
end

return M
