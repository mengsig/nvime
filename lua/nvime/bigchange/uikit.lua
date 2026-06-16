-- nvime.bigchange.uikit
--
-- Small shared UI helpers for the Big Change surfaces: a multiline input
-- popup (used for intake answers, block explanations, and critiques) and a
-- read-only scrollback float factory. Kept separate so intake.lua, build.lua
-- and review.lua share one look.

local ui = require("nvime.ui")

local M = {}

-- Block the usual ways to paste text into `buf`. Used by the forced-
-- comprehension review so an explanation has to be TYPED, not pasted from the
-- block title or the diff. This is a deterrent, not a vault: bracketed paste
-- from the terminal still streams characters in, so the grader-side check
-- (review.lua) is the real defense. We disable the in-editor paste verbs and
-- the register-paste keys, and neutralize bracketed-paste at the buffer level.
local function block_paste(buf)
  local nop = function() end
  -- Normal-mode paste verbs.
  for _, lhs in ipairs({ "p", "P", "gp", "gP" }) do
    vim.keymap.set("n", lhs, nop, { buffer = buf, nowait = true, silent = true })
  end
  -- Insert/cmdline register-paste and system-clipboard / mouse paste keys.
  for _, lhs in ipairs({ "<C-r>", "<C-v>", "<S-Insert>", "<D-v>", "<C-S-v>", "<MiddleMouse>", "<2-MiddleMouse>" }) do
    vim.keymap.set({ "i" }, lhs, nop, { buffer = buf, nowait = true, silent = true })
  end
  vim.keymap.set("n", "<MiddleMouse>", nop, { buffer = buf, nowait = true, silent = true })
  -- Bracketed paste arrives via the `<Paste>` pseudo-key on modern Neovim.
  vim.keymap.set({ "i", "n" }, "<Paste>", nop, { buffer = buf, nowait = true, silent = true })
end

-- Multiline input popup. opts = { title, initial, height, no_paste, on_change }.
-- Calls on_submit(text) on <C-s> (insert or normal), or opts.on_cancel on
-- <Esc>/q. When opts.no_paste is set, paste keys are disabled in the popup (see
-- block_paste) so the text must be typed. When opts.on_change(text) is given it
-- fires (debounced) as the user types — used to cache an in-progress draft so
-- closing the popup before submit doesn't lose the work.
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
    footer = opts.no_paste and " <C-s> submit · <Esc> cancel · paste disabled " or " <C-s> submit · <Esc> cancel ",
    footer_pos = "center",
  })
  ui.configure_panel_window(win, { wrap = true, cursorline = false })
  if opts.no_paste then
    block_paste(buf)
  end

  -- Live draft autosave: debounce buffer changes onto opts.on_change so the
  -- caller can stash an in-progress draft. Cancelling (Esc/q) then keeps the
  -- last autosaved text instead of throwing the work away.
  if type(opts.on_change) == "function" then
    local timer
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = buf,
      callback = function()
        if timer then
          pcall(function()
            timer:stop()
          end)
        end
        timer = vim.defer_fn(function()
          timer = nil
          if vim.api.nvim_buf_is_valid(buf) then
            opts.on_change(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
          end
        end, 250)
      end,
    })
  end

  local done = false
  local function finish(submit)
    if done then
      return
    end
    done = true
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    -- Flush the latest text to the draft sink before the buffer is wiped, so no
    -- final keystrokes are lost to the debounce window.
    if type(opts.on_change) == "function" then
      pcall(opts.on_change, text)
    end
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
