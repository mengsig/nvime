-- nvime.keyhelp
--
-- One reusable, themed keymap cheat-sheet overlay shared by every nvime
-- surface that owns a rich set of buffer-local keys (the conversation panels,
-- the diff review, the plan view). Before this module each surface advertised
-- its controls differently — a truncated footer, a clipped winbar banner, an
-- ephemeral `vim.notify` dump, or nothing at all — so the same `g?` keypress
-- meant something different (or nothing) everywhere. keyhelp gives them one
-- look and one toggle.
--
-- A surface calls `keyhelp.toggle({ title, sections, parent_winid })`. Each
-- section is `{ heading = "...", rows = { { "<CR>", "send the prompt" }, ... } }`.
-- Because the surface that BINDS the keys is also the one that describes them,
-- the help can't silently drift away from the real mappings.
--
-- Only one help float exists at a time (state.panels.keyhelp); `toggle` closes
-- it if open. The float is its own focusable window you `q`/`<Esc>`/`g?` out
-- of, mirroring the dashboard's help affordance.

local state = require("nvime.state")
local ui = require("nvime.ui")

local M = {}

local PANEL_KEY = "keyhelp"
local ns = vim.api.nvim_create_namespace("nvime.keyhelp")

local function panel()
  return state.panels[PANEL_KEY]
end

function M.is_open()
  local p = panel()
  return p ~= nil and p.winid ~= nil and vim.api.nvim_win_is_valid(p.winid)
end

function M.close()
  local p = panel()
  if not p then
    return
  end
  if p.winid and vim.api.nvim_win_is_valid(p.winid) then
    pcall(vim.api.nvim_win_close, p.winid, true)
  end
  if p.bufnr and vim.api.nvim_buf_is_valid(p.bufnr) then
    pcall(vim.api.nvim_buf_delete, p.bufnr, { force = true })
  end
  state.panels[PANEL_KEY] = nil
end

-- Widest key column across every row, measured in display cells so the
-- descriptions line up into a clean second column.
local function key_column_width(sections)
  local width = 0
  for _, section in ipairs(sections or {}) do
    for _, row in ipairs(section.rows or {}) do
      width = math.max(width, vim.fn.strdisplaywidth(tostring(row[1] or "")))
    end
  end
  return width
end

-- Build the buffer lines plus the extmark plan (kept separate so geometry can
-- be computed from the lines before any window exists). Returns lines, marks,
-- and the widest display width seen.
local function build_content(sections)
  local key_w = key_column_width(sections)
  local indent = "  "
  local gap = "   "
  local lines = {}
  local marks = {}
  local max_width = 0

  for index, section in ipairs(sections or {}) do
    if index > 1 then
      lines[#lines + 1] = ""
    end
    local heading = section.heading or ""
    local heading_row = #lines
    lines[#lines + 1] = heading
    marks[#marks + 1] = { row = heading_row, line_hl = "NvimeSectionBand" }
    marks[#marks + 1] = { row = heading_row, start_col = 0, end_col = #heading, hl = "NvimeSection" }
    max_width = math.max(max_width, vim.fn.strdisplaywidth(heading))

    for _, row in ipairs(section.rows or {}) do
      local keys = tostring(row[1] or "")
      local desc = tostring(row[2] or "")
      local pad = string.rep(" ", math.max(0, key_w - vim.fn.strdisplaywidth(keys)))
      local line = indent .. keys .. pad .. gap .. desc
      local lnum = #lines
      lines[#lines + 1] = line
      local key_start = #indent
      local key_end = key_start + #keys
      marks[#marks + 1] = { row = lnum, start_col = key_start, end_col = key_end, hl = "NvimeKey" }
      local desc_start = key_end + #pad + #gap
      marks[#marks + 1] = { row = lnum, start_col = desc_start, end_col = #line, hl = "NvimeRowDetail" }
      max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
    end
  end

  return lines, marks, max_width
end

local function compute_geometry(content_w, content_h, parent_winid)
  local has_parent = parent_winid and vim.api.nvim_win_is_valid(parent_winid)
  -- A window with relative ~= "" is itself a float; anchoring relative="win"
  -- to another float is supported, but the floating dashboard/panel is the
  -- common case and works fine.
  local avail_w, avail_h, relative, win
  if has_parent then
    avail_w = vim.api.nvim_win_get_width(parent_winid)
    avail_h = vim.api.nvim_win_get_height(parent_winid)
    relative = "win"
    win = parent_winid
  else
    avail_w = vim.o.columns
    avail_h = vim.o.lines
    relative = "editor"
  end

  local width = math.max(24, math.min(content_w + 2, math.max(24, avail_w - 4)))
  local height = math.max(1, math.min(content_h, math.max(1, avail_h - 4)))
  local row = math.max(0, math.floor((avail_h - height) / 2) - 1)
  local col = math.max(0, math.floor((avail_w - width) / 2))

  local cfg = {
    relative = relative,
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = ((state.config or {}).ui or {}).border or "rounded",
    focusable = true,
    zindex = 200,
    title = " " .. ui.icon("brand") .. "  ",
    title_pos = "center",
    footer = " q close ",
    footer_pos = "center",
  }
  if win then
    cfg.win = win
  end
  return cfg
end

-- Open (or replace) the help float. `spec`:
--   title         string shown in the border title (suffix after the brand mark)
--   sections      { { heading, rows = { {keys, desc}, ... } }, ... }
--   parent_winid  optional window to center within (defaults to the editor)
function M.open(spec)
  spec = spec or {}
  ui.ensure_highlights()
  M.close()

  local lines, marks, content_w = build_content(spec.sections or {})
  if #lines == 0 then
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "nvime"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local cfg = compute_geometry(content_w, #lines, spec.parent_winid)
  cfg.title = " " .. ui.icon("brand") .. "  " .. (spec.title or "keys") .. " "

  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, true, cfg)
  if not ok then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return
  end

  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].spell = false
  vim.wo[winid].winblend = 0
  vim.wo[winid].winhighlight =
    "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted"

  for _, mark in ipairs(marks) do
    local line = lines[mark.row + 1] or ""
    if mark.line_hl then
      vim.api.nvim_buf_set_extmark(bufnr, ns, mark.row, 0, { line_hl_group = mark.line_hl })
    else
      local start_col = math.max(0, math.min(mark.start_col, #line))
      local end_col = math.max(start_col, math.min(mark.end_col, #line))
      if end_col > start_col then
        vim.api.nvim_buf_set_extmark(bufnr, ns, mark.row, start_col, {
          end_col = end_col,
          hl_group = mark.hl,
        })
      end
    end
  end

  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  state.panels[PANEL_KEY] = { bufnr = bufnr, winid = winid }

  local opts = { buffer = bufnr, silent = true, nowait = true }
  for _, lhs in ipairs({ "q", "<Esc>", "g?", "?" }) do
    vim.keymap.set("n", lhs, M.close, opts)
  end
  -- If the user navigates away from the help float, dismiss it rather than
  -- leaving an orphan card hovering over the surface it documents.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = bufnr,
    once = true,
    callback = function()
      vim.schedule(M.close)
    end,
  })

  return winid
end

-- Open the overlay, or close it if it is already showing. The common binding:
--   vim.keymap.set("n", "g?", function() keyhelp.toggle(spec) end, ...)
function M.toggle(spec)
  if M.is_open() then
    M.close()
    return
  end
  M.open(spec)
end

return M
