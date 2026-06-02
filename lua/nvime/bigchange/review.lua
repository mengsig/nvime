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
local store = require("nvime.bigchange.store")
local uikit = require("nvime.bigchange.uikit")
local ui = require("nvime.ui")

local M = {}

local R = {
  session = nil,
  tabpage = nil,
  left_win = nil,
  left_buf = nil,
  right_win = nil,
  right_buf = nil,
  ns_left = vim.api.nvim_create_namespace("nvime.bigchange.review.left"),
  ns_right = vim.api.nvim_create_namespace("nvime.bigchange.review.right"),
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
    lines[#lines + 1] = "  a approve · r request-changes"
    marks[#marks + 1] = { #lines, 0, -1, "NvimeHelp" }
    lines[#lines + 1] = "  <C-s> submit · M merge · q close"
    marks[#marks + 1] = { #lines, 0, -1, "NvimeHelp" }
  end

  vim.bo[R.left_buf].modifiable = true
  vim.api.nvim_buf_set_lines(R.left_buf, 0, -1, false, lines)
  vim.bo[R.left_buf].modifiable = false
  uikit.apply_marks(R.left_buf, R.ns_left, lines, marks)
end

-- ---------------------------------------------------------------------------
-- right pane: block diff + comment
-- ---------------------------------------------------------------------------
local function render_right()
  if not (R.right_buf and vim.api.nvim_buf_is_valid(R.right_buf)) then
    return
  end
  local session = R.session
  ui.ensure_highlights()
  local lines, marks = {}, {}
  local block = R.active_block_id and get_block(R.active_block_id) or nil

  if not block then
    lines[#lines + 1] = "  Select a block on the left (<CR>) to review it."
    marks[#marks + 1] = { 1, 0, -1, "NvimeMuted" }
    vim.bo[R.right_buf].modifiable = true
    vim.api.nvim_buf_set_lines(R.right_buf, 0, -1, false, lines)
    vim.bo[R.right_buf].modifiable = false
    uikit.apply_marks(R.right_buf, R.ns_right, lines, marks)
    return
  end

  local meta = block_meta(block)
  local grade = block.grade and (" · " .. block.grade .. "%") or ""
  lines[#lines + 1] = string.format("  Block %d · %s · %s", block.id, block.title, block.file)
  marks[#marks + 1] = { #lines, 0, -1, "NvimeHeader" }
  lines[#lines + 1] = "  [" .. meta.label .. grade .. "]"
  marks[#marks + 1] = { #lines, 0, -1, meta.hl }
  lines[#lines + 1] =
    "  ───────────────────────────────────────────────"
  marks[#marks + 1] = { #lines, 0, -1, "NvimeRule" }

  for _, h in ipairs(blocks_mod.block_hunks(session, block)) do
    lines[#lines + 1] = "  " .. h.header
    marks[#marks + 1] = { #lines, 0, -1, "NvimeSection" }
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

  -- An unsubmitted draft (typed but not yet committed with <C-s>). Surfaced so
  -- the user can see their cached work after leaving and reopening the review.
  local pending_draft = block.draft and block.draft ~= ""
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

  vim.bo[R.right_buf].modifiable = true
  vim.api.nvim_buf_set_lines(R.right_buf, 0, -1, false, lines)
  vim.bo[R.right_buf].modifiable = false
  uikit.apply_marks(R.right_buf, R.ns_right, lines, marks)
end

local function render()
  render_left()
  render_right()
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

local function approve()
  if R.busy then
    return
  end
  local block = target_block()
  if not block then
    return
  end
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
    render()
    if R.right_win and vim.api.nvim_win_is_valid(R.right_win) then
      vim.api.nvim_set_current_win(R.right_win)
    end
  end
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
    "MISSED — e.g. \"What happens to the second branch when the list is empty?\" — and",
    "NEVER state the correct explanation, name the answer, or quote the fix. A reader",
    "should still have to think. One line, no spoilers.",
    "",
    "Output ONLY a JSON array wrapped in <JSON></JSON>:",
    '  [{"id": <int>, "action": "approve"|"request_changes",',
    '    "grade": <int 0-100>, "verdict": "...", "hint": "...",',
    '    "valid": <bool>, "revised": <bool>, "response": "..."}]',
    "",
  }
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
      local function finish()
        R.busy = false
        R.status = nil
        store.touch(session)
        render()
        if all_cleared(session) then
          local pct = overall_grade(session)
          vim.notify(
            string.format(
              "nvime bigchange: all blocks cleared — final grade %d%% — press M to merge 🔓",
              pct or 100
            ),
            vim.log.levels.INFO
          )
        end
      end
      if need_recapture then
        R.status = "re-capturing revised diff…"
        render()
        blocks_mod.recapture(session, function()
          finish()
        end)
      else
        finish()
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
      string.format("nvime bigchange: merge locked 🔒 (%d/%d blocks cleared)", cleared, total),
      vim.log.levels.WARN
    )
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
end

local function install_keymaps(bufnr)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
  end
  map("<CR>", select_block)
  map("o", select_block)
  map("a", approve)
  map("r", request_changes)
  map("<C-s>", submit_round)
  map("M", merge)
  map("q", M.close)
end

function M.open(session)
  R.session = session
  if is_open() then
    vim.api.nvim_set_current_tabpage(R.tabpage)
    render()
    return
  end

  vim.cmd("tabnew")
  R.tabpage = vim.api.nvim_get_current_tabpage()
  R.right_win = vim.api.nvim_get_current_win()
  R.right_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[R.right_buf].bufhidden = "wipe"
  vim.bo[R.right_buf].filetype = "nvime"
  vim.api.nvim_win_set_buf(R.right_win, R.right_buf)

  vim.cmd("topleft vsplit")
  R.left_win = vim.api.nvim_get_current_win()
  R.left_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[R.left_buf].bufhidden = "wipe"
  vim.bo[R.left_buf].filetype = "nvime"
  vim.api.nvim_win_set_buf(R.left_win, R.left_buf)
  pcall(vim.api.nvim_win_set_width, R.left_win, 44)

  ui.ensure_highlights()
  ui.configure_panel_window(R.left_win, { wrap = false, cursorline = true })
  ui.configure_panel_window(R.right_win, { wrap = true, cursorline = false })

  install_keymaps(R.left_buf)
  install_keymaps(R.right_buf)

  -- Default the active block to the first not-yet-cleared one.
  R.active_block_id = nil
  for _, b in ipairs(session.blocks or {}) do
    if b.state ~= "cleared" then
      R.active_block_id = b.id
      break
    end
  end
  if not R.active_block_id and session.blocks and session.blocks[1] then
    R.active_block_id = session.blocks[1].id
  end

  vim.api.nvim_set_current_win(R.left_win)
  render()
end

-- Test-only export.
M._overall_grade = overall_grade

return M
