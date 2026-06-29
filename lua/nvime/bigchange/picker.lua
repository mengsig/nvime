-- nvime.bigchange.picker
--
-- The <leader>nB landing surface: a floating list of Big Change sessions
-- (the "PRs" view). Mirrors the look of nvime's other panels (ui.lua palette +
-- icons) but is a self-contained float so it never touches the shared
-- chat/selection panel registry.
--
-- Keys: <CR>/o enter · n new · dd discard · r refresh · q/<Esc> close.

local store = require("nvime.bigchange.store")
local uikit = require("nvime.bigchange.uikit")
local ui = require("nvime.ui")

local M = {}

local view = {
  bufnr = nil,
  winid = nil,
  ns = vim.api.nvim_create_namespace("nvime.bigchange.picker"),
  row_to_session = {},
}

local STATUS_HL = {
  draft = "NvimeSection",
  intake = "NvimeStatusWarn",
  building = "NvimeStatusRunning",
  review = "NvimeStatusIdle",
  merged = "NvimeStatusSuccess",
}

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function block_progress(session)
  local blocks = session.blocks or {}
  local total = #blocks
  if total == 0 then
    return 0, 0
  end
  local cleared = 0
  for _, block in ipairs(blocks) do
    if block.state == "cleared" then
      cleared = cleared + 1
    end
  end
  return cleared, total
end

local function status_text(session)
  local st = session.status
  if st == store.STATUS.DRAFT then
    return "draft · editing brief"
  elseif st == store.STATUS.INTAKE then
    if session.spec and session.spec ~= "" then
      return "intake · spec ready"
    end
    return "intake · gathering requirements"
  elseif st == store.STATUS.BUILDING then
    return session.busy and "building…" or "building (paused)"
  elseif st == store.STATUS.REVIEW then
    local cleared, total = block_progress(session)
    local lock = (total > 0 and cleared == total) and "🔓 ready" or "🔒 locked"
    return string.format("review · %d/%d cleared · %s", cleared, total, lock)
  elseif st == store.STATUS.MERGED then
    return "merged → " .. (session.merged_branch or "?")
  end
  return st or "?"
end

-- ---------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------
local function render()
  if not (view.bufnr and vim.api.nvim_buf_is_valid(view.bufnr)) then
    return
  end
  ui.ensure_highlights()
  local sessions = store.list()
  view.row_to_session = {}

  local lines = {}
  local marks = {} -- { row(1-based), col_start, col_end, hl }

  local brand = ui.icon("brand")
  lines[#lines + 1] = "  " .. brand .. "  Big Changes"
  marks[#marks + 1] = { 1, 0, -1, "NvimeTitle" }
  lines[#lines + 1] = "  Let the agent go crazy — then earn the merge."
  marks[#marks + 1] = { 2, 0, -1, "NvimeSubtitle" }
  lines[#lines + 1] = ""

  if #sessions == 0 then
    lines[#lines + 1] = "  No Big Changes yet."
    marks[#marks + 1] = { #lines, 0, -1, "NvimeMuted" }
    lines[#lines + 1] = "  Press " .. "n" .. " to start one."
    marks[#marks + 1] = { #lines, 0, -1, "NvimeMuted" }
  else
    for _, session in ipairs(sessions) do
      local idle = ui.icon("idle")
      local active = ui.icon("active")
      local marker = session.busy and active or idle
      -- Primary line: marker  title          (difficulty)
      local diff = store.DIFFICULTY[session.difficulty] or { label = session.difficulty }
      local title_line = string.format("  %s  %s", marker, session.title or ("Big Change #" .. session.id))
      lines[#lines + 1] = title_line
      local prow = #lines
      view.row_to_session[prow] = session.id
      marks[#marks + 1] = { prow, 0, #title_line, "NvimeHeader" }
      local diff_label = "  (" .. (diff.label or "?") .. ")"
      lines[prow] = lines[prow] .. diff_label
      marks[#marks + 1] = { prow, #title_line, #lines[prow], "NvimeKey" }

      -- Detail line: status · updated
      local detail = string.format("       %s · %s", status_text(session), ui.relative_time(session.updated_at))
      lines[#lines + 1] = detail
      local drow = #lines
      view.row_to_session[drow] = session.id
      marks[#marks + 1] = { drow, 0, -1, STATUS_HL[session.status] or "NvimeMuted" }
      lines[#lines + 1] = ""
    end
  end

  lines[#lines + 1] =
    "  ───────────────────────────────────────────"
  marks[#marks + 1] = { #lines, 0, -1, "NvimeRule" }
  do
    local footer, hints = ui.keyhint_line({
      { "<CR>", "enter" },
      { "n", "new" },
      { "dd", "discard" },
      { "r", "refresh" },
      { "q", "close" },
    }, { indent = "  " })
    lines[#lines + 1] = footer
    for _, hint in ipairs(hints) do
      marks[#marks + 1] = { #lines, hint[1], hint[2], hint[3] }
    end
  end

  vim.bo[view.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(view.bufnr, 0, -1, false, lines)
  vim.bo[view.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(view.bufnr, view.ns, 0, -1)
  for _, mark in ipairs(marks) do
    local row, col_start, col_end, hl = mark[1], mark[2], mark[3], mark[4]
    local line = lines[row] or ""
    if col_end == -1 then
      col_end = #line
    end
    pcall(vim.api.nvim_buf_set_extmark, view.bufnr, view.ns, row - 1, col_start, {
      end_col = math.min(col_end, #line),
      hl_group = hl,
    })
  end
end

M.refresh = render

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------
local function session_at_cursor()
  if not (view.winid and vim.api.nvim_win_is_valid(view.winid)) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(view.winid)[1]
  local id = view.row_to_session[row]
  if not id then
    return nil
  end
  return store.get(id)
end

function M.close()
  if view.winid and vim.api.nvim_win_is_valid(view.winid) then
    pcall(vim.api.nvim_win_close, view.winid, true)
  end
  view.winid = nil
end

local function enter_session()
  local session = session_at_cursor()
  if not session then
    return
  end
  M.close()
  require("nvime.bigchange").open_session(session.id)
end

local function discard_session()
  local session = session_at_cursor()
  if not session then
    return
  end
  local choice =
    vim.fn.confirm(string.format("Discard Big Change '%s'? This removes its worktree.", session.title), "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end
  require("nvime.bigchange").discard(session.id)
  render()
end

-- ---------------------------------------------------------------------------
-- open
-- ---------------------------------------------------------------------------
local function install_keymaps(bufnr)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
  end
  map("<CR>", enter_session)
  map("o", enter_session)
  map("n", function()
    require("nvime.bigchange").create_interactive(render)
  end)
  map("dd", discard_session)
  map("r", render)
  map("q", M.close)
  map("<Esc>", M.close)
end

function M.open()
  store.load()
  if view.winid and vim.api.nvim_win_is_valid(view.winid) then
    vim.api.nvim_set_current_win(view.winid)
    render()
    return
  end

  view.bufnr, view.winid = uikit.open_float({
    title = ui.icon("brand") .. "  Big Changes",
    width_ratio = 0.6,
    height_ratio = 0.6,
    cursorline = true,
    wrap = false,
  })

  install_keymaps(view.bufnr)
  render()
end

return M
