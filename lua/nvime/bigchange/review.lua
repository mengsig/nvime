-- nvime.bigchange.review
--
-- Stage 4 (UI) + Stage 5 (FSM + grading): the forced-comprehension PR review.
-- A dedicated tabpage with two panes:
--   left  — a file tree of the agent-chosen semantic blocks + their state
--   right — the selected block's inline diff, your comment, and the agent's reply
--
-- Per-block you press `a` (approve) or `r` (request changes). Approve asks you
-- to explain the code; request-changes asks for a critique. Press `<C-s>` to
-- submit the round: every pending comment goes to the agent in ONE resumed turn, which
-- grades explanations against the difficulty threshold and, for valid critiques,
-- revises the code (we then re-capture the diff). The merge unlocks (`M`) only
-- when every block is cleared.

local blocks_mod = require("nvime.bigchange.blocks")
local fileview = require("nvime.bigchange.fileview")
local store = require("nvime.bigchange.store")
local uikit = require("nvime.bigchange.uikit")
local ui = require("nvime.ui")
local audit = require("nvime.audit")
local keyhelp = require("nvime.keyhelp")

local M = {}

local R = {
  session = nil,
  tabpage = nil,
  -- left pane: the block tree + control surface (approve / request-changes /
  -- submit / merge). right pane: the active block's REAL worktree file, opened
  -- as a normal navigable buffer (LSP, treesitter, gd, search all work) with
  -- the diff annotated inline; ]c / [c jump between its change chunks.
  left_win = nil,
  left_buf = nil,
  right_win = nil,
  right_buf = nil, -- bufnr currently shown in right_win (a real file, or the diff scratch)
  right_file = nil, -- worktree-relative path currently annotated (nil for placeholder)
  shown_id = nil, -- id of the block currently rendered in the right pane
  diff_buf = nil, -- reused scratch for the diff-only view (and not-on-disk files)
  anchors = {}, -- buffer lines starting each hunk in the shown file (for ]c/[c)
  -- "inline" = the real file with the diff annotated in place (full context,
  -- navigable); "diff" = just the change as diff text, like the old pane. Toggle
  -- with `t`; the choice persists on this module state across close/reopen.
  mode = "inline",
  ns_left = vim.api.nvim_create_namespace("nvime.bigchange.review.left"),
  ns_overlay = vim.api.nvim_create_namespace("nvime.bigchange.review.overlay"),
  row_to_block = {},
  active_block_id = nil,
  busy = false,
  status = nil,
}

-- Single source of truth for each block state's icon, highlight, and the
-- right-pane label. Adding a state means one entry here.
local STATE = {
  pending = { icon = "●", hl = "NvimeStatusWarn", label = "needs action" },
  explaining = { icon = "◐", hl = "NvimeStatusRunning", label = "explanation queued" },
  critiquing = { icon = "◐", hl = "NvimeStatusRunning", label = "critique queued" },
  cleared = { icon = "✓", hl = "NvimeStatusSuccess", label = "cleared" },
  needs_explanation = { icon = "✗", hl = "NvimeStatusError", label = "needs a better explanation" },
  critique_rejected = { icon = "⚠", hl = "NvimeStatusError", label = "critique rejected" },
}

local function state_meta(s)
  return STATE[s] or STATE.pending
end

-- A block's display meta. Trivial auto-clears get a distinct ⚡ badge; earned
-- clears keep the standard cleared ✓ meta.
local function block_meta(b)
  if b.trivial and b.state == "cleared" then
    return { icon = "⚡", hl = "NvimeMuted", label = "trivial · auto-cleared" }
  end
  return state_meta(b.state)
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function is_open()
  return R.tabpage and vim.api.nvim_tabpage_is_valid(R.tabpage)
end

local function difficulty(session)
  return store.DIFFICULTY[session.difficulty] or store.DIFFICULTY.medium
end

local function threshold(session)
  return difficulty(session).threshold -- nil means vibe (auto-clear)
end

-- The verb shown on the "all cleared" completion action (M). A plain Big Change
-- merges; a phased Plan overrides this (advance to implement / finalize) via a
-- runtime `session.review_complete` hook that is never serialized.
local function complete_label(session)
  local rc = session and session.review_complete
  if rc and rc.label and rc.label ~= "" then
    return rc.label
  end
  return "merge"
end

local function get_block(id)
  for _, b in ipairs(R.session.blocks or {}) do
    if b.id == id then
      return b
    end
  end
  return nil
end

local function all_cleared(session)
  local blocks = session.blocks or {}
  if #blocks == 0 then
    return false
  end
  for _, b in ipairs(blocks) do
    if b.state ~= "cleared" then
      return false
    end
  end
  return true
end

-- The block to focus by default: the first not-yet-cleared one, else the first.
local function default_active()
  for _, b in ipairs(R.session.blocks or {}) do
    if b.state ~= "cleared" then
      return b.id
    end
  end
  if R.session.blocks and R.session.blocks[1] then
    return R.session.blocks[1].id
  end
  return nil
end

local function progress(session)
  local cleared, total = 0, #(session.blocks or {})
  for _, b in ipairs(session.blocks or {}) do
    if b.state == "cleared" then
      cleared = cleared + 1
    end
  end
  return cleared, total
end

-- Your comprehension grade out of 100. Each block scores its graded value;
-- a cleared block with no numeric grade (e.g. a vibe-difficulty auto-clear, or
-- a block cleared via an accepted critique) counts as 100; anything not yet
-- attempted counts as 0 so the grade reflects real, demonstrated coverage.
-- Trivial auto-clears are self-evident and excluded entirely (both numerator
-- and denominator) so they neither inflate nor dilute the demonstrated grade.
-- Returns (percent:int, scored:int, nontrivial:int), or nil when there are no
-- gradeable (non-trivial) blocks.
local function overall_grade(session)
  local blocks = session.blocks or {}
  local sum, scored, nontrivial = 0, 0, 0
  for _, b in ipairs(blocks) do
    if not b.trivial then
      nontrivial = nontrivial + 1
      local g
      if type(b.grade) == "number" then
        g = b.grade
      elseif b.state == "cleared" then
        g = 100
      end
      if g ~= nil then
        sum = sum + g
        scored = scored + 1
      end
    end
  end
  if nontrivial == 0 then
    return nil
  end
  return math.floor(sum / nontrivial + 0.5), scored, nontrivial
end

-- Highlight band for a 0-100 grade: green when passing the difficulty bar,
-- yellow when partway, red when far below.
local function grade_hl(session, pct)
  local bar = threshold(session) or 100
  if pct >= bar then
    return "NvimeStatusSuccess"
  elseif pct >= math.floor(bar / 2) then
    return "NvimeStatusWarn"
  end
  return "NvimeStatusError"
end

-- ---------------------------------------------------------------------------
-- left pane: block tree
-- ---------------------------------------------------------------------------
local function render_left()
  if not (R.left_buf and vim.api.nvim_buf_is_valid(R.left_buf)) then
    return
  end
  local session = R.session
  ui.ensure_highlights()
  local lines, marks = {}, {}
  R.row_to_block = {}

  local cleared, total = progress(session)
  local d = difficulty(session)
  local lock = all_cleared(session) and "🔓" or "🔒"
  lines[#lines + 1] = "  " .. ui.icon("brand") .. " " .. (session.title or "Big Change")
  marks[#marks + 1] = { #lines, 0, -1, "NvimeTitle" }
  lines[#lines + 1] = string.format("  %s · %d/%d cleared %s", d.label or "?", cleared, total, lock)
  marks[#marks + 1] = { #lines, 0, -1, all_cleared(session) and "NvimeStatusSuccess" or "NvimeStatusWarn" }

  -- Overall comprehension grade — the headline number out of 100. Trivial
  -- auto-clears are excluded, so the denominator is the non-trivial count.
  local pct, scored, gradeable = overall_grade(session)
  if pct ~= nil then
    local bar = threshold(session)
    local suffix = bar and ("  (pass ≥ " .. bar .. "%)") or ""
    lines[#lines + 1] = string.format("  Grade: %d%%  · %d/%d graded%s", pct, scored, gradeable, suffix)
    marks[#marks + 1] = { #lines, 0, 14, grade_hl(session, pct) }
    marks[#marks + 1] = { #lines, 14, -1, "NvimeMuted" }
  end
  if session.status == store.STATUS.MERGED then
    lines[#lines + 1] = "  merged → " .. (session.merged_branch or "?")
    marks[#marks + 1] = { #lines, 0, -1, "NvimeStatusSuccess" }
  end
  lines[#lines + 1] = "  ─────────────────────────────"
  marks[#marks + 1] = { #lines, 0, -1, "NvimeRule" }

  -- Group blocks by file, preserving block order.
  local file_order, by_file = {}, {}
  for _, b in ipairs(session.blocks or {}) do
    if not by_file[b.file] then
      by_file[b.file] = {}
      file_order[#file_order + 1] = b.file
    end
    table.insert(by_file[b.file], b)
  end

  for _, file in ipairs(file_order) do
    lines[#lines + 1] = "  ▾ " .. file
    marks[#marks + 1] = { #lines, 0, -1, "NvimeSection" }
    for _, b in ipairs(by_file[file]) do
      local meta = block_meta(b)
      local grade = b.grade and (" " .. tostring(b.grade) .. "%") or ""
      local sel = (b.id == R.active_block_id) and "›" or " "
      local text = string.format("  %s  %s %d %s%s", sel, meta.icon, b.id, b.title, grade)
      lines[#lines + 1] = text
      R.row_to_block[#lines] = b.id
      marks[#marks + 1] = { #lines, 0, 7, meta.hl }
      marks[#marks + 1] = { #lines, 7, -1, (b.id == R.active_block_id) and "NvimeHeader" or "NvimeNormal" }
    end
  end

  lines[#lines + 1] = "  ─────────────────────────────"
  marks[#marks + 1] = { #lines, 0, -1, "NvimeRule" }
  if R.busy then
    lines[#lines + 1] = "  ● " .. (R.status or "submitting…")
    marks[#marks + 1] = { #lines, 0, -1, "NvimeStatusRunning" }
  else
    local other = (R.mode == "inline") and "diff" or "inline"
    lines[#lines + 1] = string.format("  <CR> open · ]c/[c hunks · t → %s view", other)
    marks[#marks + 1] = { #lines, 0, -1, "NvimeHelp" }
    lines[#lines + 1] = "  a approve · r request-changes"
    marks[#marks + 1] = { #lines, 0, -1, "NvimeHelp" }
    lines[#lines + 1] = "  <C-s> submit · M " .. complete_label(session) .. " · q close · g? keys"
    marks[#marks + 1] = { #lines, 0, -1, "NvimeHelp" }
  end

  vim.bo[R.left_buf].modifiable = true
  vim.api.nvim_buf_set_lines(R.left_buf, 0, -1, false, lines)
  vim.bo[R.left_buf].modifiable = false
  uikit.apply_marks(R.left_buf, R.ns_left, lines, marks)
end

-- ---------------------------------------------------------------------------
-- right pane: the active block's REAL file, navigably annotated
-- ---------------------------------------------------------------------------

-- Worktree-absolute path for a block's file, or nil when unresolvable.
local function file_path(session, file)
  local wt = session.worktree
  if not wt or wt == "" or not file or file == "" then
    return nil
  end
  return wt .. "/" .. file
end

-- A normal editor window (NOT panel chrome): syntax/treesitter foreground must
-- show through, and we need a signcolumn for the "+" change signs.
local function configure_file_window(winid)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return
  end
  vim.wo[winid].signcolumn = "yes:1"
  vim.wo[winid].number = true
  vim.wo[winid].relativenumber = false
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = true
  vim.wo[winid].winhighlight = ""
end

-- The status / comment / agent-reply box drawn as virtual lines above the
-- block's first changed line, so the review feedback rides along with the code.
local function overlay_lines(block)
  local meta = block_meta(block)
  local out = {}
  local grade = block.grade and (" · " .. block.grade .. "%") or ""
  out[#out + 1] = {
    { "╭─ ", "NvimeAgent" },
    { string.format("Block %d · %s", block.id, block.title), "NvimeHeader" },
    { "  [" .. meta.label .. grade .. "]", meta.hl },
  }

  -- An unsubmitted draft (typed but not yet committed with <C-s>).
  local pending_draft = block.draft
    and block.draft ~= ""
    and block.state ~= "explaining"
    and block.state ~= "critiquing"
  if pending_draft then
    out[#out + 1] = { { "│ ", "NvimeAgent" }, { "draft (unsubmitted) — a/r to resume", "NvimeStatusWarn" } }
    for _, cl in ipairs(vim.split(block.draft, "\n", { plain = true })) do
      out[#out + 1] = { { "│   ", "NvimeAgent" }, { cl, "NvimeUserText" } }
    end
  end

  if block.comment and block.comment ~= "" then
    local title = block.action == "request_changes" and "your critique" or "your explanation"
    local foot = block.state == "explaining" and " · ⏳ awaiting grade"
      or block.state == "critiquing" and " · ⏳ awaiting agent"
      or ""
    out[#out + 1] = { { "│ ", "NvimeAgent" }, { title .. foot, "NvimeSection" } }
    for _, cl in ipairs(vim.split(block.comment, "\n", { plain = true })) do
      out[#out + 1] = { { "│   ", "NvimeAgent" }, { cl, "NvimeUserText" } }
    end
  end

  if block.agent_response and block.agent_response ~= "" then
    out[#out + 1] = { { "│ ", "NvimeAgent" }, { "agent", "NvimeAgent" } }
    for _, cl in ipairs(vim.split(block.agent_response, "\n", { plain = true })) do
      out[#out + 1] = { { "│   ", "NvimeAgent" }, { cl, "NvimeNormal" } }
    end
  end

  if block.hint and block.hint ~= "" and block.state == "needs_explanation" then
    out[#out + 1] = { { "│ hint: ", "NvimeAgent" }, { block.hint, "NvimeStatusWarn" } }
  end

  -- Grading history: when a block took more than one attempt, show the trail of
  -- grades so the work it took to demonstrate comprehension is visible.
  if type(block.grading_history) == "table" and #block.grading_history > 1 then
    local marks = {}
    for _, h in ipairs(block.grading_history) do
      marks[#marks + 1] = string.format("%d%%%s", h.grade or 0, h.passed and "✓" or "✗")
    end
    out[#out + 1] = { { "│ attempts: ", "NvimeAgent" }, { table.concat(marks, " · "), "NvimeMuted" } }
  end

  out[#out + 1] = { { "╰─ a approve · r request-changes · X explain-anyway (left pane) ─", "NvimeMuted" } }
  return out
end

-- Draw the overlay box for `block` above buffer line `anchor`.
local function render_overlay(bufnr, block, anchor)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, R.ns_overlay, 0, -1)
  if not (block and anchor and anchor >= 1) then
    return
  end
  ui.ensure_highlights()
  pcall(vim.api.nvim_buf_set_extmark, bufnr, R.ns_overlay, anchor - 1, 0, {
    virt_lines = overlay_lines(block),
    virt_lines_above = true,
  })
end

local function install_file_keymaps(bufnr)
  vim.keymap.set("n", "]c", function()
    fileview.jump(R.right_win, R.anchors, 1)
  end, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "[c", function()
    fileview.jump(R.right_win, R.anchors, -1)
  end, { buffer = bufnr, silent = true })
end

-- A reusable scratch buffer for the diff-only view (and the placeholder / files
-- that aren't on disk, which can only be shown as diff text).
local function ensure_diff_buf()
  if R.diff_buf and vim.api.nvim_buf_is_valid(R.diff_buf) then
    return R.diff_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "nvime"
  R.diff_buf = buf
  install_file_keymaps(buf)
  return buf
end

-- Show a one-line message in the right window (no block selected).
local function placeholder(msg)
  if not (R.right_win and vim.api.nvim_win_is_valid(R.right_win)) then
    return
  end
  local buf = ensure_diff_buf()
  ui.ensure_highlights()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  " .. msg })
  vim.bo[buf].modifiable = false
  uikit.apply_marks(buf, R.ns_overlay, { "  " .. msg }, { { 1, 0, -1, "NvimeMuted" } })
  vim.api.nvim_win_set_buf(R.right_win, buf)
  ui.configure_panel_window(R.right_win, { wrap = true, cursorline = false })
  R.right_buf, R.right_file, R.anchors, R.shown_id = buf, nil, {}, nil
end

-- The diff-only view: render the block's change as diff text, with the draft /
-- comment / agent-reply / hint boxes inline (the pre-file-view layout). Used by
-- "diff" mode, and as the fallback for files that aren't on disk. `on_disk` is
-- false when the file is gone/binary, which adds a small note to the header.
local function show_diff(block, on_disk)
  if not (R.right_win and vim.api.nvim_win_is_valid(R.right_win)) then
    return
  end
  local buf = ensure_diff_buf()
  ui.ensure_highlights()
  local meta = block_meta(block)
  local grade = block.grade and (" · " .. block.grade .. "%") or ""
  local lines, marks, anchors = {}, {}, {}
  local note = (on_disk == false) and "  (not on disk)" or ""
  lines[#lines + 1] = string.format("  Block %d · %s · %s%s", block.id, block.title, block.file, note)
  marks[#marks + 1] = { #lines, 0, -1, "NvimeHeader" }
  lines[#lines + 1] = "  [" .. meta.label .. grade .. "]"
  marks[#marks + 1] = { #lines, 0, -1, meta.hl }
  lines[#lines + 1] =
    "  ───────────────────────────────────────────────"
  marks[#marks + 1] = { #lines, 0, -1, "NvimeRule" }

  for _, h in ipairs(blocks_mod.block_hunks(R.session, block)) do
    lines[#lines + 1] = "  " .. h.header
    anchors[#anchors + 1] = #lines
    marks[#marks + 1] = { #lines, 0, -1, "NvimeDiffHunk" }
    for _, l in ipairs(h.lines) do
      local sigil = (l.kind == "add" and "+") or (l.kind == "del" and "-") or " "
      lines[#lines + 1] = "  " .. sigil .. " " .. l.text
      if l.kind == "add" then
        marks[#marks + 1] = { #lines, 0, -1, "NvimeDiffAdd" }
      elseif l.kind == "del" then
        marks[#marks + 1] = { #lines, 0, -1, "NvimeDiffDelete" }
      end
    end
  end

  -- An unsubmitted draft (typed but not yet committed with <C-s>).
  local pending_draft = block.draft
    and block.draft ~= ""
    and block.state ~= "explaining"
    and block.state ~= "critiquing"
  if pending_draft then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  ╭─ draft (unsubmitted) ──────────────────"
    marks[#marks + 1] = { #lines, 0, -1, "NvimeStatusWarn" }
    for _, cl in ipairs(vim.split(block.draft, "\n", { plain = true })) do
      lines[#lines + 1] = "  │ " .. cl
      marks[#marks + 1] = { #lines, 0, -1, "NvimeUserText" }
    end
    lines[#lines + 1] = "  ╰─ a/r to resume ───────────────────────"
    marks[#marks + 1] = { #lines, 0, -1, "NvimeMuted" }
  end

  if block.comment and block.comment ~= "" then
    lines[#lines + 1] = ""
    local title = block.action == "request_changes" and "your critique" or "your explanation"
    lines[#lines + 1] = "  ╭─ " .. title .. " ───────────────────────"
    marks[#marks + 1] = { #lines, 0, -1, "NvimeSection" }
    for _, cl in ipairs(vim.split(block.comment, "\n", { plain = true })) do
      lines[#lines + 1] = "  │ " .. cl
      marks[#marks + 1] = { #lines, 0, -1, "NvimeUserText" }
    end
    local foot = block.state == "explaining" and "⏳ awaiting grade"
      or block.state == "critiquing" and "⏳ awaiting agent"
      or "─"
    lines[#lines + 1] = "  ╰─ " .. foot .. " ──────────────────────"
    marks[#marks + 1] = { #lines, 0, -1, "NvimeMuted" }
  end

  if block.agent_response and block.agent_response ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] =
      "  ╭─ agent ──────────────────────────────"
    marks[#marks + 1] = { #lines, 0, -1, "NvimeAgent" }
    for _, cl in ipairs(vim.split(block.agent_response, "\n", { plain = true })) do
      lines[#lines + 1] = "  │ " .. cl
      marks[#marks + 1] = { #lines, 0, -1, "NvimeNormal" }
    end
    lines[#lines + 1] =
      "  ╰──────────────────────────────────────"
    marks[#marks + 1] = { #lines, 0, -1, "NvimeAgent" }
  end

  if block.hint and block.hint ~= "" and block.state == "needs_explanation" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  hint: " .. block.hint
    marks[#marks + 1] = { #lines, 0, -1, "NvimeStatusWarn" }
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  uikit.apply_marks(buf, R.ns_overlay, lines, marks)
  vim.api.nvim_win_set_buf(R.right_win, buf)
  ui.configure_panel_window(R.right_win, { wrap = false, cursorline = true })
  R.right_buf, R.right_file, R.anchors, R.shown_id = buf, block.file, anchors, block.id
end

-- Load the active block's real worktree file into the right window, annotate
-- its diff in place, draw the feedback overlay, and jump to the block's first
-- hunk. Falls back to the diff-text view when the file isn't on disk.
-- opts.reload forces a disk reload (after the agent revised code).
local function show_file(block, opts)
  opts = opts or {}
  local path = file_path(R.session, block.file)
  if not path or vim.fn.filereadable(path) ~= 1 then
    show_diff(block, false)
    if R.anchors[1] then
      pcall(vim.api.nvim_win_set_cursor, R.right_win, { R.anchors[1], 0 })
    end
    return
  end

  -- :edit loads the real file (reloading from disk when unmodified, so agent
  -- revisions are picked up); :edit! forces it after a grading round revised code.
  local cmd = opts.reload and "edit!" or "edit"
  pcall(vim.api.nvim_win_call, R.right_win, function()
    vim.cmd(cmd .. " " .. vim.fn.fnameescape(path))
  end)
  local bufnr = vim.api.nvim_win_get_buf(R.right_win)
  R.right_buf, R.right_file, R.shown_id = bufnr, block.file, block.id
  configure_file_window(R.right_win)
  install_file_keymaps(bufnr)

  local res = fileview.apply(bufnr, fileview.hunks_for_file(R.session, block.file))
  R.anchors = res.anchors
  local first_id = block.hunk_ids and block.hunk_ids[1]
  local anchor = (first_id and res.by_hunk[first_id]) or res.anchors[1]
  render_overlay(bufnr, block, anchor or 1)
  if anchor and vim.api.nvim_win_is_valid(R.right_win) then
    pcall(vim.api.nvim_win_set_cursor, R.right_win, { anchor, 0 })
    pcall(vim.api.nvim_win_call, R.right_win, function()
      vim.cmd("normal! zz")
    end)
  end
end

-- Show the active block in the right window using the current view mode.
-- opts.focus moves the cursor into the right window; opts.reload forces a disk
-- reload of the real file (inline mode only).
local function show_active(opts)
  opts = opts or {}
  if not (R.right_win and vim.api.nvim_win_is_valid(R.right_win)) then
    return
  end
  local block = R.active_block_id and get_block(R.active_block_id) or nil
  if not block then
    placeholder("Select a block on the left (<CR>) to review it.")
    return
  end
  if R.mode == "diff" then
    show_diff(block, true)
    if R.anchors[1] then
      pcall(vim.api.nvim_win_set_cursor, R.right_win, { R.anchors[1], 0 })
    end
  else
    show_file(block, opts)
  end
  if opts.focus and vim.api.nvim_win_is_valid(R.right_win) then
    vim.api.nvim_set_current_win(R.right_win)
  end
end

-- Re-render the active block in the right window WITHOUT moving focus — used on
-- cheap re-renders (grading progress, state changes). In inline mode, when the
-- shown file is unchanged, just re-annotate + redraw the overlay so the cursor
-- doesn't jump; otherwise re-show the active block in the current mode.
local function refresh_right()
  local block = R.active_block_id and get_block(R.active_block_id) or nil
  if not block then
    if R.right_file ~= nil then
      placeholder("Select a block on the left (<CR>) to review it.")
    end
    return
  end
  if not (R.right_buf and vim.api.nvim_buf_is_valid(R.right_buf)) then
    show_active()
    return
  end
  -- In-place inline refresh: same real file already shown, cursor preserved.
  if R.mode == "inline" and R.right_file == block.file and R.right_buf ~= R.diff_buf then
    local res = fileview.apply(R.right_buf, fileview.hunks_for_file(R.session, block.file))
    R.anchors = res.anchors
    local first_id = block.hunk_ids and block.hunk_ids[1]
    render_overlay(R.right_buf, block, (first_id and res.by_hunk[first_id]) or res.anchors[1] or 1)
    return
  end
  -- Diff mode (or file changed / not yet shown): re-render the active block.
  show_active()
end

local function render()
  render_left()
  refresh_right()
end

-- ---------------------------------------------------------------------------
-- per-block actions (FSM)
-- ---------------------------------------------------------------------------
local function target_block()
  if R.left_win and vim.api.nvim_get_current_win() == R.left_win then
    local row = vim.api.nvim_win_get_cursor(R.left_win)[1]
    local id = R.row_to_block[row]
    if id then
      R.active_block_id = id
      return get_block(id)
    end
  end
  return R.active_block_id and get_block(R.active_block_id) or nil
end

-- Ensure the active block is shown in the right pane (without stealing focus)
-- before we act on it — so approving/critiquing from the left tree keeps the
-- change in view, in whichever mode is active.
local function ensure_shown(block)
  R.active_block_id = block.id
  if R.shown_id ~= block.id then
    show_active({ focus = false })
  end
end

local function approve()
  if R.busy then
    return
  end
  local block = target_block()
  if not block then
    return
  end
  ensure_shown(block)
  if threshold(R.session) == nil then
    -- vibe: approve clears instantly, no explanation.
    block.state = "cleared"
    block.action = "approve"
    block.comment = nil
    block.grade = nil
    store.touch(R.session)
    render()
    return
  end
  uikit.input({
    title = "Explain block " .. block.id .. ": " .. block.title,
    no_paste = true,
    -- Prefill with any cached draft (or a prior explanation) so re-opening the
    -- box keeps your work; autosave keystrokes so closing before submit is safe.
    initial = block.draft or block.comment or "",
    on_change = function(t)
      block.draft = t
      store.touch(R.session)
    end,
    on_cancel = render,
  }, function(text)
    if not text or text == "" then
      return
    end
    block.action = "approve"
    block.comment = text
    block.draft = nil -- consumed by submit
    block.state = "explaining"
    block.hint = nil
    block.agent_response = nil
    store.touch(R.session)
    render()
  end)
end

local function request_changes()
  if R.busy then
    return
  end
  local block = target_block()
  if not block then
    return
  end
  ensure_shown(block)
  uikit.input({
    title = "Request changes on block " .. block.id .. ": " .. block.title,
    no_paste = true,
    initial = block.draft or block.comment or "",
    on_change = function(t)
      block.draft = t
      store.touch(R.session)
    end,
    on_cancel = render,
  }, function(text)
    if not text or text == "" then
      return
    end
    block.action = "request_changes"
    block.comment = text
    block.draft = nil -- consumed by submit
    block.state = "critiquing"
    block.hint = nil
    block.agent_response = nil
    store.touch(R.session)
    render()
  end)
end

local function select_block()
  local block = target_block()
  if block then
    R.active_block_id = block.id
    render_left()
    show_active({ focus = true })
  end
end

-- Flip between the inline (real-file, full-context) and diff-only views.
local function toggle_mode()
  R.mode = (R.mode == "inline") and "diff" or "inline"
  render_left()
  show_active({ focus = false })
end

-- ---------------------------------------------------------------------------
-- batched grading round
-- ---------------------------------------------------------------------------
local function grade_prompt(session, pending)
  local d = difficulty(session)
  local lines = {
    "You are grading a forced-comprehension review of code YOU implemented.",
    string.format("Difficulty: %s — explanations should demonstrate: %s.", d.label, d.detail),
    string.format("Passing grade is %s%% or higher.", tostring(d.threshold)),
    "",
    "For each block below:",
    "- action=approve: the user EXPLAINS the code. Grade 0-100 how accurately and",
    "  completely their explanation matches what the code actually DOES and WHY, at",
    "  this difficulty. Reward genuine understanding in the user's OWN words.",
    "  ANTI-CHEAT — grade these <= 15 (failing) regardless of difficulty:",
    "    * the explanation merely restates or lightly rephrases the block TITLE,",
    "    * it parrots identifiers/comments/strings copied verbatim from the diff",
    "      without saying what they mean or why they're there,",
    "    * it is generic boilerplate that would fit almost any code change.",
    "  An explanation must add information not already visible in the title/diff to",
    "  pass. If below passing, give a SOCRATIC hint (see below).",
    "- action=request_changes: the user CRITIQUES your code. If the critique is valid,",
    "  FIX the code now (edit the files in this worktree) and set revised=true. If the",
    "  critique is wrong or misguided, set valid=false and explain why in response.",
    "",
    "HINTS must be Socratic: pose a question or point at the concept/area the user",
    'MISSED — e.g. "What happens to the second branch when the list is empty?" — and',
    "NEVER state the correct explanation, name the answer, or quote the fix. A reader",
    "should still have to think. One line, no spoilers.",
    "",
    "Output ONLY a JSON array wrapped in <JSON></JSON>:",
    '  [{"id": <int>, "action": "approve"|"request_changes",',
    '    "grade": <int 0-100>, "verdict": "...", "hint": "...",',
    '    "valid": <bool>, "revised": <bool>, "response": "..."}]',
    "",
  }
  -- A lane-specific note (e.g. the Plan scaffold phase tells the agent the user
  -- may have hand-edited the worktree files, which are the source of truth).
  if session.review_prompt_note and session.review_prompt_note ~= "" then
    lines[#lines + 1] = session.review_prompt_note
    lines[#lines + 1] = ""
  end
  for _, b in ipairs(pending) do
    lines[#lines + 1] = string.format("### Block %d — %s (%s) — action=%s", b.id, b.title, b.file, b.action)
    lines[#lines + 1] = "diff:"
    for _, h in ipairs(blocks_mod.block_hunks(session, b)) do
      lines[#lines + 1] = h.header
      for _, l in ipairs(h.lines) do
        local sigil = (l.kind == "add" and "+") or (l.kind == "del" and "-") or " "
        lines[#lines + 1] = sigil .. l.text
      end
    end
    lines[#lines + 1] = "user " .. (b.action == "request_changes" and "critique" or "explanation") .. ":"
    lines[#lines + 1] = b.comment or ""
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

local function apply_results(session, results, pending)
  local by_id = {}
  for _, r in ipairs(results or {}) do
    if r.id then
      by_id[tonumber(r.id)] = r
    end
  end
  local need_recapture = false
  local bar = threshold(session)
  for _, b in ipairs(pending) do
    local r = by_id[b.id]
    if not r then
      b.agent_response = "[no grade returned — resubmit]"
    elseif b.action == "approve" then
      b.grade = tonumber(r.grade) or 0
      b.agent_response = r.verdict or r.response
      if bar and b.grade >= bar then
        b.state = "cleared"
        b.hint = nil
      else
        b.state = "needs_explanation"
        b.hint = r.hint or "add more detail about what the code does and why"
      end
      -- Record every grading attempt: the per-block history shows how many
      -- tries comprehension took (a real signal), and the audit event makes the
      -- forced-comprehension gate itself accountable months later.
      local passed = b.state == "cleared"
      b.grading_history = b.grading_history or {}
      b.grading_history[#b.grading_history + 1] = {
        grade = b.grade,
        threshold = bar,
        passed = passed,
        ts = os.time(),
      }
      audit.write({
        event = "bigchange_block_graded",
        project = session.id or session.title,
        block_id = b.id,
        block_title = b.title,
        file = b.file,
        difficulty = session.difficulty,
        grade = b.grade,
        threshold = bar,
        passed = passed,
        attempt = #b.grading_history,
      })
    elseif b.action == "request_changes" then
      b.agent_response = r.response or (r.revised and "fixed" or "critique declined")
      if r.revised == true then
        -- Code revised — diff will change; recapture and let the block reset.
        need_recapture = true
      else
        -- Either the agent explicitly declined (valid=false) or it reported no
        -- code change. Both leave the block uncleared: the user must approve +
        -- explain to clear it. Only an explicit revised=true triggers recapture,
        -- so an omitted flag never silently discards the critique.
        b.state = "critique_rejected"
      end
    end
  end
  store.touch(session)
  return need_recapture
end

local function submit_round()
  if R.busy then
    return
  end
  local session = R.session
  local pending = {}
  for _, b in ipairs(session.blocks or {}) do
    if b.state == "explaining" or b.state == "critiquing" then
      pending[#pending + 1] = b
    end
  end
  if #pending == 0 then
    vim.notify("nvime bigchange: nothing to submit (approve or request-changes first)", vim.log.levels.INFO)
    return
  end

  R.busy = true
  R.status = "grading round " .. (session.review_round + 1) .. "…"
  render()

  require("nvime.bigchange.agent").turn({
    session = session,
    lane = "bigchange", -- write access so valid critiques can revise code
    cwd = session.worktree,
    prompt = grade_prompt(session, pending),
    resume = true,
    scope = "worktree",
    on_progress = function(line)
      R.status = vim.trim((line or ""):gsub("\n", " "))
      vim.schedule(render)
    end,
    on_done = function(text)
      local results = require("nvime.bigchange.agent").extract_json(text)
      local need_recapture = apply_results(session, results, pending)
      session.review_round = (session.review_round or 0) + 1
      local function finish(did_recapture)
        R.busy = false
        R.status = nil
        store.touch(session)
        render()
        if did_recapture then
          -- The agent rewrote files on disk and blocks were re-grouped: re-resolve
          -- the active block and reload its buffer so the view reflects the
          -- revised code instead of stale annotations on stale content.
          R.active_block_id = default_active()
          show_active({ reload = true })
        end
        if all_cleared(session) then
          local pct = overall_grade(session)
          vim.notify(
            string.format(
              "nvime: all blocks cleared — final grade %d%% — press M to %s 🔓",
              pct or 100,
              complete_label(session)
            ),
            vim.log.levels.INFO
          )
        end
      end
      if need_recapture then
        R.status = "re-capturing revised diff…"
        render()
        blocks_mod.recapture(session, function()
          finish(true)
        end)
      else
        finish(false)
      end
    end,
  })
end

local function merge()
  if R.busy then
    return
  end
  if not all_cleared(R.session) then
    local cleared, total = progress(R.session)
    vim.notify(
      string.format("nvime: %s locked 🔒 (%d/%d blocks cleared)", complete_label(R.session), cleared, total),
      vim.log.levels.WARN
    )
    return
  end
  local rc = R.session.review_complete
  if rc and type(rc.run) == "function" then
    rc.run(R.session, function()
      render()
    end)
    return
  end
  require("nvime.bigchange.merge").start(R.session, function()
    render()
  end)
end

-- ---------------------------------------------------------------------------
-- open / close
-- ---------------------------------------------------------------------------
function M.close()
  if is_open() then
    pcall(function()
      vim.api.nvim_set_current_tabpage(R.tabpage)
      vim.cmd("tabclose")
    end)
  end
  R.tabpage = nil
  R.right_buf, R.right_file, R.anchors, R.shown_id = nil, nil, {}, nil
end

-- Re-lock a self-evident, auto-cleared block so it must be explained anyway.
-- The trivial relaxation is a convenience, not a ceiling: if you want to prove
-- you understand a block the heuristic waved through, you can demand the gate.
-- Returns true when the block was a trivial auto-clear and got re-locked.
local function override_trivial(session, block)
  if not (block and block.trivial and block.state == "cleared") then
    return false
  end
  block.trivial = false
  block.state = "pending"
  block.action = nil
  block.grade = nil
  block.comment = nil
  block.hint = nil
  store.touch(session)
  audit.write({
    event = "bigchange_trivial_overridden",
    project = session.id or session.title,
    block_id = block.id,
    file = block.file,
  })
  return true
end

M._override_trivial = override_trivial

local function explain_anyway()
  if R.busy then
    return
  end
  local block = target_block()
  if not block then
    return
  end
  if not override_trivial(R.session, block) then
    vim.notify("nvime big change: only a trivial auto-cleared block can be re-locked", vim.log.levels.INFO)
    return
  end
  vim.notify("nvime big change: block " .. block.id .. " now requires an explanation", vim.log.levels.INFO)
  render()
end

-- The g? cheat-sheet for the Big Change review's left control tree. Mirrors the
-- keys bound in install_left_keymaps so the help tracks the real mappings.
local function review_help_sections()
  return {
    {
      heading = "Blocks",
      rows = {
        { "<CR>  o", "open the block under the cursor" },
        { "a", "approve — then explain the code" },
        { "r", "request changes — write a critique" },
        { "X", "re-lock a trivial auto-cleared block" },
      },
    },
    {
      heading = "Round",
      rows = {
        { "<C-s>", "submit the round to the agent" },
        { "M", complete_label(R.session) .. " (unlocks once every block is cleared)" },
      },
    },
    {
      heading = "Window",
      rows = {
        { "t", "toggle inline / file-view mode" },
        { "<Tab>", "jump to the file pane" },
        { "q", "close the review" },
        { "g?", "toggle this help" },
      },
    },
  }
end

-- Control keys live on the LEFT tree only — the right pane is a real file, so
-- clobbering a/r/o/q there would break normal editing and navigation.
local function install_left_keymaps(bufnr)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
  end
  map("<CR>", select_block)
  map("o", select_block)
  map("a", approve)
  map("r", request_changes)
  map("X", explain_anyway)
  map("<C-s>", submit_round)
  map("M", merge)
  map("q", M.close)
  map("t", toggle_mode)
  map("g?", function()
    keyhelp.toggle({
      title = "big change keys",
      sections = review_help_sections(),
      parent_winid = vim.api.nvim_get_current_win(),
    })
  end)
  -- Convenience: hop to the file pane to navigate / find definitions.
  map("<Tab>", function()
    if R.right_win and vim.api.nvim_win_is_valid(R.right_win) then
      vim.api.nvim_set_current_win(R.right_win)
    end
  end)
end

function M.open(session)
  R.session = session
  if is_open() then
    vim.api.nvim_set_current_tabpage(R.tabpage)
    render()
    return
  end

  -- New tab. The initial window becomes the right (file) pane; show_active will
  -- render the active block into it in the current view mode.
  vim.cmd("tabnew")
  R.tabpage = vim.api.nvim_get_current_tabpage()
  R.right_win = vim.api.nvim_get_current_win()
  R.right_buf, R.right_file, R.anchors, R.shown_id = nil, nil, {}, nil

  vim.cmd("topleft vsplit")
  R.left_win = vim.api.nvim_get_current_win()
  R.left_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[R.left_buf].bufhidden = "wipe"
  vim.bo[R.left_buf].filetype = "nvime"
  vim.api.nvim_win_set_buf(R.left_win, R.left_buf)
  pcall(vim.api.nvim_win_set_width, R.left_win, 44)

  ui.ensure_highlights()
  ui.configure_panel_window(R.left_win, { wrap = false, cursorline = true })

  install_left_keymaps(R.left_buf)

  R.active_block_id = default_active()
  show_active({ focus = false })

  vim.api.nvim_set_current_win(R.left_win)
  render()
end

-- Test-only export.
M._overall_grade = overall_grade
M._apply_results = apply_results
M._help_sections = review_help_sections
M._complete_label = complete_label
M._grade_prompt = grade_prompt

return M
