-- nvime.bigchange.uikit
--
-- Small shared UI helpers for the Big Change surfaces: a multiline input
-- popup (used for intake answers, block explanations, and critiques) and a
-- read-only scrollback float factory. Kept separate so intake.lua, build.lua
-- and review.lua share one look.

local ui = require("nvime.ui")

local M = {}

-- Multiline input popup. opts = { title, initial, height }. Calls
-- on_submit(text) on <C-s> (insert or normal), or opts.on_cancel on <Esc>/q.
function M.input(opts, on_submit)
  opts = opts or {}
  ui.ensure_highlights()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  if opts.initial and opts.initial ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.initial, "\n", { plain = true }))
  end

  local columns, lines_total = vim.o.columns, vim.o.lines
  local width = math.min(96, columns - 8)
  local height = math.max(3, math.min(opts.height or 8, lines_total - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = lines_total - height - 4,
    col = math.floor((columns - width) / 2),
    style = "minimal",
    border = (require("nvime.state").config.ui or {}).border or "rounded",
    title = " " .. (opts.title or "Input") .. " ",
    title_pos = "center",
    footer = " <C-s> submit · <Esc> cancel ",
    footer_pos = "center",
  })
  ui.configure_panel_window(win, { wrap = true, cursorline = false })

  local done = false
  local function finish(submit)
    if done then
      return
    end
    done = true
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if submit then
      on_submit(vim.trim(text))
    elseif type(opts.on_cancel) == "function" then
      opts.on_cancel()
    end
  end

  vim.keymap.set({ "i", "n" }, "<C-s>", function()
    finish(true)
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    finish(false)
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", function()
    finish(false)
  end, { buffer = buf, nowait = true })

  if opts.initial and opts.initial ~= "" then
    vim.cmd("normal! G$")
  else
    vim.cmd("startinsert")
  end
end

-- Create a centered scratch float with nvime's panel chrome. Returns
-- bufnr, winid. opts = { title, footer, width_ratio, height_ratio, min_width,
-- min_height, cursorline, wrap, filetype }. Shared by the picker, intake and
-- build surfaces so their geometry and chrome stay identical.
function M.open_float(opts)
  opts = opts or {}
  ui.ensure_highlights()
  local cfg = (require("nvime.state").config or {}).ui or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = opts.filetype or "nvime"
  local columns, lines_total = vim.o.columns, vim.o.lines
  local width = math.max(opts.min_width or 56, math.min(math.floor(columns * (opts.width_ratio or 0.7)), columns - 4))
  local height =
    math.max(opts.min_height or 14, math.min(math.floor(lines_total * (opts.height_ratio or 0.7)), lines_total - 4))
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((lines_total - height) / 2 - 1),
    col = math.floor((columns - width) / 2),
    style = "minimal",
    border = cfg.border or "rounded",
    title = " " .. (opts.title or "") .. " ",
    title_pos = "center",
    footer = opts.footer and (" " .. opts.footer .. " ") or nil,
    footer_pos = opts.footer and "center" or nil,
  })
  ui.configure_panel_window(win, { wrap = opts.wrap ~= false, cursorline = opts.cursorline == true })
  return bufnr, win
end

-- Apply an array of highlight marks to a buffer in a namespace.
-- marks: { { row(1-based), col_start, col_end(-1=eol), hl }, ... }
function M.apply_marks(bufnr, ns, lines, marks)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, mark in ipairs(marks) do
    local row, col_start, col_end, hl = mark[1], mark[2], mark[3], mark[4]
    local line = lines[row] or ""
    if col_end == -1 then
      col_end = #line
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row - 1, col_start, {
      end_col = math.min(col_end, #line),
      hl_group = hl,
    })
  end
end

return M
