-- nvime.bigchange.intake
--
-- Stage 2: the clarifying-decisions phase, presented as a Claude-Code-style
-- PLANNING surface. Instead of a prose Q&A, the agent emits a structured PLAN
-- (see agent.extract_plan) — a list of DECISIONS, each with selectable options.
-- The user resolves them right in the float:
--   <Space>/<CR>  toggle the option under the cursor (single = radio, multi = k/N)
--   1-9           toggle the Nth option of the decision under the cursor
--   c             attach a free-text note / type a text answer
--   <C-s>         submit all decisions → the agent refines or writes the spec
--   m             send the agent a free-form message (more comments / questions)
-- When the agent is confident it emits a <SPEC>; the user then approves (a),
-- edits it (e), or asks for more (m). On approval we hand off to the build stage.
-- The agent runs read-only ("critic" lane) in the real repo so it can read the
-- codebase to ask informed questions and ground the spec.

local agent = require("nvime.bigchange.agent")
local store = require("nvime.bigchange.store")
local uikit = require("nvime.bigchange.uikit")
local ui = require("nvime.ui")

local M = {}

local view = {
  session = nil,
  bufnr = nil,
  winid = nil,
  ns = vim.api.nvim_create_namespace("nvime.bigchange.intake"),
  busy = false,
  status = nil,
  row_to_opt = {}, -- bufrow → { qi, oi }   (oi == 0 means "text answer")
  row_to_q = {}, -- bufrow → qi            (any row belonging to a decision)
  first_select_row = nil,
  want_cursor_reset = false, -- jump to the first option on the next render
}

local function is_open()
  return view.winid and vim.api.nvim_win_is_valid(view.winid) and view.bufnr and vim.api.nvim_buf_is_valid(view.bufnr)
end

local function spec_ready(session)
  return session.spec and session.spec ~= ""
end

local function plan_active(session)
  return type(session.plan) == "table" and type(session.plan.questions) == "table" and #session.plan.questions > 0
end

-- ---------------------------------------------------------------------------
-- plan ingest / selection model
-- ---------------------------------------------------------------------------
-- Normalize a raw agent PLAN into our editable model. Option indices are
-- 1-based internally; the agent's 0-based `recommended` becomes the initial
-- selection (and is remembered so the UI can star it).
local function ingest_plan(raw)
  local out = { summary = raw.summary and tostring(raw.summary) or nil, questions = {} }
  for _, q in ipairs(raw.questions or {}) do
    if type(q) == "table" then
      local options = {}
      for _, o in ipairs(q.options or {}) do
        if type(o) == "table" then
          options[#options + 1] =
            { label = tostring(o.label or "option"), detail = o.detail and tostring(o.detail) or nil }
        elseif type(o) == "string" then
          options[#options + 1] = { label = o }
        end
      end
      local kind = q.kind
      if kind ~= "single" and kind ~= "multi" and kind ~= "text" then
        kind = (#options > 0) and "single" or "text"
      end
      local recommended, selected = {}, {}
      for _, r in ipairs(q.recommended or {}) do
        local idx = tonumber(r)
        if idx ~= nil then
          idx = idx + 1 -- 0-based → 1-based
          if options[idx] then
            recommended[idx] = true
            selected[#selected + 1] = idx
          end
        end
      end
      if kind == "single" and #selected > 1 then
        selected = { selected[1] }
      end
      out.questions[#out.questions + 1] = {
        id = q.id and tostring(q.id) or nil,
        prompt = tostring(q.prompt or "Decision"),
        kind = kind,
        options = options,
        allow_custom = q.allow_custom ~= false,
        recommended = recommended,
        selected = selected,
        custom = "",
      }
    end
  end
  return out
end

local function is_selected(q, oi)
  for _, v in ipairs(q.selected or {}) do
    if v == oi then
      return true
    end
  end
  return false
end

local function toggle(q, oi)
  q.selected = q.selected or {}
  if q.kind == "single" then
    q.selected = { oi }
    return
  end
  local out, present = {}, false
  for _, v in ipairs(q.selected) do
    if v == oi then
      present = true
    else
      out[#out + 1] = v
    end
  end
  if not present then
    out[#out + 1] = oi
    table.sort(out)
  end
  q.selected = out
end

-- A human-readable summary of the resolved decisions, sent to the agent.
local function format_decisions(plan)
  local parts = {}
  for _, q in ipairs(plan.questions) do
    parts[#parts + 1] = "## " .. q.prompt
    if q.kind == "text" then
      parts[#parts + 1] = (q.custom ~= "") and ("Answer: " .. q.custom) or "Answer: (no preference — you decide)"
    else
      local labels = {}
      for _, oi in ipairs(q.selected or {}) do
        if q.options[oi] then
          labels[#labels + 1] = q.options[oi].label
        end
      end
      parts[#parts + 1] = (#labels > 0) and ("Selected: " .. table.concat(labels, ", "))
        or "Selected: (no preference — you decide)"
      if q.custom and q.custom ~= "" then
        parts[#parts + 1] = "Note: " .. q.custom
      end
    end
    parts[#parts + 1] = ""
  end
  return vim.trim(table.concat(parts, "\n"))
end

-- ---------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------
local function push(lines, marks, text, hl)
  lines[#lines + 1] = text
  if hl then
    marks[#marks + 1] = { #lines, 0, -1, hl }
  end
  return #lines
end

-- Footer hint row with the keys highlighted (shared ui.keyhint formatter), so
-- the intake controls read like every other nvime surface.
local function push_keyhint(lines, marks, items)
  local line, hints = ui.keyhint_line(items, { indent = "  " })
  lines[#lines + 1] = line
  for _, hint in ipairs(hints) do
    marks[#marks + 1] = { #lines, hint[1], hint[2], hint[3] }
  end
  return #lines
end

local function push_wrapped(lines, marks, text, hl, indent)
  indent = indent or "    "
  for _, paragraph in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if paragraph == "" then
      lines[#lines + 1] = ""
    else
      lines[#lines + 1] = indent .. paragraph
      if hl then
        marks[#marks + 1] = { #lines, 0, -1, hl }
      end
    end
  end
end

local function rule_width()
  if is_open() then
    return math.max(20, vim.api.nvim_win_get_width(view.winid) - 6)
  end
  return 50
end

local function hrule(n)
  return string.rep("─", n)
end

-- Render one decision as a bordered card with selectable option rows.
local function render_question(lines, marks, qi, q)
  local w = rule_width()
  local kind_tag = (q.kind == "single" and "pick one") or (q.kind == "multi" and "pick any") or "type an answer"

  local label = "─ Decision " .. qi .. " "
  local top = "  ╭" .. label .. hrule(math.max(3, w - vim.fn.strdisplaywidth(label))) .. "╮"
  push(lines, marks, top, "NvimeSection")
  view.row_to_q[#lines] = qi

  -- prompt line with the kind tag right-tagged
  local prow = push(lines, marks, "  │ " .. q.prompt, "NvimeHeader")
  view.row_to_q[prow] = qi
  -- append the tag at end of the prompt line
  lines[prow] = lines[prow] .. "   (" .. kind_tag .. ")"
  marks[#marks + 1] = { prow, #("  │ " .. q.prompt), -1, "NvimeMuted" }

  if q.kind == "text" then
    local val = (q.custom and q.custom ~= "") and q.custom or "(press <Space> or c to type your answer)"
    local hl = (q.custom and q.custom ~= "") and "NvimeUserText" or "NvimeMuted"
    local r = push(lines, marks, "  │   " .. ui.icon("edit") .. " " .. val, hl)
    view.row_to_q[r] = qi
    view.row_to_opt[r] = { qi, 0 }
    view.first_select_row = view.first_select_row or r
  else
    for oi, opt in ipairs(q.options) do
      local sel = is_selected(q, oi)
      local marker
      if q.kind == "single" then
        marker = sel and "●" or "○"
      else
        marker = sel and "[✓]" or "[ ]"
      end
      local body = string.format("  │   %s %d  %s", marker, oi, opt.label)
      local r = push(lines, marks, body)
      view.row_to_q[r] = qi
      view.row_to_opt[r] = { qi, oi }
      view.first_select_row = view.first_select_row or r
      -- marker highlight: selected pops green, otherwise muted
      marks[#marks + 1] = { r, 0, #("  │   " .. marker), sel and "NvimeStatusSuccess" or "NvimeMuted" }
      marks[#marks + 1] = { r, #("  │   " .. marker), -1, sel and "NvimeHeader" or "NvimeNormal" }
      if opt.detail and opt.detail ~= "" then
        push(lines, marks, "  │        " .. opt.detail, "NvimeMuted")
        view.row_to_q[#lines] = qi
      end
      if q.recommended and q.recommended[oi] then
        lines[r] = lines[r] .. "   ★ recommended"
        marks[#marks + 1] = { r, #body, -1, "NvimeKey" }
      end
    end
    -- note line
    local note = (q.custom and q.custom ~= "") and ("note: " .. q.custom) or "note: (press c to add a comment)"
    local nhl = (q.custom and q.custom ~= "") and "NvimeUserText" or "NvimeMuted"
    local nr = push(lines, marks, "  │   " .. ui.icon("edit") .. " " .. note, nhl)
    view.row_to_q[nr] = qi
  end

  push(lines, marks, "  ╰" .. hrule(w) .. "╯", "NvimeSection")
  view.row_to_q[#lines] = qi
end

local function render()
  if not is_open() then
    return
  end
  local session = view.session
  ui.ensure_highlights()
  -- Remember where the user was so a re-render (e.g. after a toggle) keeps their
  -- place instead of yanking the cursor back to the top.
  local prev_row = is_open() and vim.api.nvim_win_get_cursor(view.winid)[1] or nil
  local lines, marks = {}, {}
  view.row_to_opt = {}
  view.row_to_q = {}
  view.first_select_row = nil

  push(
    lines,
    marks,
    "  " .. ui.icon("brand") .. "  " .. (session.title or "Big Change") .. " — planning",
    "NvimeTitle"
  )
  local diff = store.DIFFICULTY[session.difficulty] or { label = session.difficulty, detail = "" }
  push(lines, marks, "  Difficulty: " .. (diff.label or "?") .. " — " .. (diff.detail or ""), "NvimeMuted")
  push(lines, marks, "  " .. hrule(rule_width()), "NvimeRule")
  push(lines, marks, "")

  -- Transcript of resolved rounds (compact).
  for _, turn in ipairs(session.intake_history or {}) do
    if turn.role == "user" then
      push(lines, marks, "  " .. ui.icon("key") .. " your decisions", "NvimeSection")
      push_wrapped(lines, marks, turn.content, "NvimeUserText")
    else
      push(lines, marks, "  " .. ui.icon("brand") .. " agent", "NvimeAgent")
      push_wrapped(lines, marks, turn.content, "NvimeNormal")
    end
    push(lines, marks, "")
  end

  if view.busy then
    push(lines, marks, "  ● " .. (view.status or "agent is thinking…"), "NvimeStatusRunning")
    push(lines, marks, "")
  end

  -- The live, interactive plan (only when no spec is on the table yet).
  if not spec_ready(session) and plan_active(session) and not view.busy then
    if session.plan.summary and session.plan.summary ~= "" then
      push_wrapped(lines, marks, session.plan.summary, "NvimeAgent", "  ")
      push(lines, marks, "")
    end
    for qi, q in ipairs(session.plan.questions) do
      render_question(lines, marks, qi, q)
      push(lines, marks, "")
    end
  end

  if spec_ready(session) then
    push(lines, marks, "  ┌─ Ready to build " .. hrule(math.max(3, rule_width() - 17)), "NvimeStatusSuccess")
    push_wrapped(lines, marks, session.spec, "NvimeNormal", "  │ ")
    push(lines, marks, "  └" .. hrule(rule_width()), "NvimeStatusSuccess")
    push(lines, marks, "")
    push_keyhint(lines, marks, {
      { "[a]", "approve & build" },
      { "[e]", "edit spec" },
      { "[m]", "more questions" },
      { "q", "close" },
    })
  elseif not view.busy and plan_active(session) then
    push(lines, marks, "  " .. hrule(rule_width()), "NvimeRule")
    push_keyhint(lines, marks, {
      { "<Space>/<CR>", "toggle" },
      { "1-9", "pick" },
      { "c", "comment" },
      { "<C-s>", "submit" },
    })
    push_keyhint(lines, marks, { { "m", "message agent" }, { "q", "close" } })
  elseif not view.busy then
    push_keyhint(lines, marks, { { "[m]", "message agent" }, { "q", "close" } })
  end

  vim.bo[view.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(view.bufnr, 0, -1, false, lines)
  vim.bo[view.bufnr].modifiable = false
  uikit.apply_marks(view.bufnr, view.ns, lines, marks)

  -- Cursor: on a fresh plan, park on the first selectable option so keys work
  -- immediately. On an ordinary re-render, restore the user's prior row (clamped)
  -- so toggling an option doesn't fling them back to the top.
  if is_open() then
    local target
    if view.want_cursor_reset or not prev_row then
      target = view.first_select_row or #lines
      view.want_cursor_reset = false
    else
      target = math.max(1, math.min(prev_row, #lines))
    end
    pcall(vim.api.nvim_win_set_cursor, view.winid, { target, 0 })
  end
end

-- ---------------------------------------------------------------------------
-- agent turns
-- ---------------------------------------------------------------------------
local function handle_response(text, result)
  view.busy = false
  view.status = nil
  local session = view.session
  if result and result.code and result.code ~= 0 and (not text or text == "") then
    session.intake_history[#session.intake_history + 1] =
      { role = "assistant", content = "[the agent run failed — press q, then reopen to retry]" }
    store.touch(session)
    render()
    return
  end

  local spec = agent.extract_spec(text)
  local plan = agent.extract_plan(text)

  if spec then
    session.spec = spec
    session.plan = nil
    local display = vim.trim((text or ""):gsub("<SPEC>.-</SPEC>", "📋 Spec ready — review below."))
    if display ~= "" then
      session.intake_history[#session.intake_history + 1] = { role = "assistant", content = display }
    end
  elseif plan then
    session.plan = ingest_plan(plan)
    session.spec = nil
    view.want_cursor_reset = true
    if session.plan.summary and session.plan.summary ~= "" then
      session.intake_history[#session.intake_history + 1] = { role = "assistant", content = session.plan.summary }
    end
  else
    -- Prose fallback: the agent ignored the protocol. Show it; the user can
    -- nudge with `m`.
    if text and vim.trim(text) ~= "" then
      session.intake_history[#session.intake_history + 1] = { role = "assistant", content = text }
    end
  end

  store.touch(session)
  render()
end

local function run_turn(prompt, resume)
  local session = view.session
  view.busy = true
  view.status = "agent is thinking…"
  render()
  agent.turn({
    session = session,
    lane = "critic",
    prompt = prompt,
    resume = resume,
    on_progress = function(line)
      view.status = vim.trim((line or ""):gsub("\n", " "))
      vim.schedule(render)
    end,
    on_done = handle_response,
  })
end

local function kickoff()
  run_turn(agent.intake_kickoff_prompt(view.session), false)
end

-- ---------------------------------------------------------------------------
-- interactions
-- ---------------------------------------------------------------------------
local function focused_question()
  if not is_open() then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(view.winid)[1]
  local qi = view.row_to_q[row]
  if not qi then
    return nil
  end
  return view.session.plan.questions[qi]
end

-- q.custom doubles as the persisted slot AND the live draft: autosaving on every
-- change means closing the box (or all of nvime) before <C-s> keeps the text.
local function edit_text_answer(q)
  uikit.input({
    title = q.prompt,
    initial = q.custom or "",
    height = 6,
    on_change = function(text)
      q.custom = text or ""
      store.touch(view.session)
    end,
    on_cancel = render,
  }, function(text)
    q.custom = text or ""
    store.touch(view.session)
    render()
  end)
end

local function comment(q)
  q = q or focused_question()
  if not q then
    return
  end
  if q.kind == "text" then
    edit_text_answer(q)
    return
  end
  uikit.input({
    title = "Comment on: " .. q.prompt,
    initial = q.custom or "",
    height = 6,
    on_change = function(text)
      q.custom = text or ""
      store.touch(view.session)
    end,
    on_cancel = render,
  }, function(text)
    q.custom = text or ""
    store.touch(view.session)
    render()
  end)
end

-- <Space>/<CR>: act on whatever is under the cursor.
local function activate()
  if view.busy or not plan_active(view.session) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(view.winid)[1]
  local target = view.row_to_opt[row]
  if target then
    local q = view.session.plan.questions[target[1]]
    if not q then
      return
    end
    if q.kind == "text" or target[2] == 0 then
      edit_text_answer(q)
    else
      toggle(q, target[2])
      store.touch(view.session)
      render()
    end
    return
  end
  -- Cursor on a header/note row of a text question → edit it.
  local q = focused_question()
  if q and q.kind == "text" then
    edit_text_answer(q)
  end
end

-- Number keys toggle the Nth option of the decision under the cursor.
local function pick_number(n)
  if view.busy or not plan_active(view.session) then
    return
  end
  local q = focused_question()
  if not q or q.kind == "text" or not q.options[n] then
    return
  end
  toggle(q, n)
  store.touch(view.session)
  render()
end

local function submit()
  if view.busy then
    vim.notify("nvime bigchange: agent is still thinking", vim.log.levels.INFO)
    return
  end
  if not plan_active(view.session) then
    return
  end
  local decisions = format_decisions(view.session.plan)
  view.session.intake_history[#view.session.intake_history + 1] = { role = "user", content = decisions }
  view.session.plan = nil
  view.session.spec = nil
  store.touch(view.session)
  run_turn(agent.intake_followup_prompt(decisions), true)
end

-- Free-form message to the agent (more comments / clarifications), valid in any
-- state — including alongside a proposed spec.
local function message_agent()
  if view.busy then
    vim.notify("nvime bigchange: agent is still thinking", vim.log.levels.INFO)
    return
  end
  uikit.input({
    title = "Message the agent",
    initial = view.session.message_draft or "",
    -- Cache the half-typed message so closing the box keeps it; cleared on send.
    on_change = function(text)
      view.session.message_draft = text or ""
      store.touch(view.session)
    end,
    on_cancel = render,
  }, function(text)
    if not text or text == "" then
      return
    end
    view.session.message_draft = nil
    view.session.intake_history[#view.session.intake_history + 1] = { role = "user", content = text }
    -- A fresh message invalidates any pending proposal so the agent re-derives.
    view.session.spec = nil
    view.session.plan = nil
    run_turn(agent.intake_followup_prompt(text), true)
  end)
end

local function edit_spec()
  if not spec_ready(view.session) then
    return
  end
  uikit.input({ title = "Edit spec", initial = view.session.spec, height = 16 }, function(text)
    view.session.spec = vim.trim(text)
    store.touch(view.session)
    render()
  end)
end

local function approve()
  if not spec_ready(view.session) then
    vim.notify("nvime bigchange: no spec to approve yet", vim.log.levels.INFO)
    return
  end
  view.session.spec_approved = true
  store.touch(view.session)
  M.close()
  require("nvime.bigchange.build").start(view.session)
end

-- ---------------------------------------------------------------------------
-- open / close
-- ---------------------------------------------------------------------------
function M.close()
  if view.winid and vim.api.nvim_win_is_valid(view.winid) then
    pcall(vim.api.nvim_win_close, view.winid, true)
  end
  view.winid = nil
end

local function install_keymaps(bufnr)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
  end
  map("<Space>", activate)
  map("<CR>", activate)
  map("o", activate)
  map("c", comment)
  map("<C-s>", submit)
  map("m", message_agent)
  map("i", message_agent)
  map("a", approve)
  map("e", edit_spec)
  map("q", M.close)
  map("<Esc>", M.close)
  for n = 1, 9 do
    map(tostring(n), function()
      pick_number(n)
    end)
  end
end

function M.open(session)
  view.session = session
  view.busy = false
  view.want_cursor_reset = true
  if not is_open() then
    view.bufnr, view.winid = uikit.open_float({
      title = ui.icon("brand") .. "  Planning",
      width_ratio = 0.8,
      height_ratio = 0.82,
      min_width = 64,
      min_height = 18,
      cursorline = true,
      wrap = true,
    })
    install_keymaps(view.bufnr)
  else
    vim.api.nvim_set_current_win(view.winid)
  end

  render()
  -- Auto-start the interrogation when this is a fresh intake.
  if
    #(session.intake_history or {}) == 0
    and not spec_ready(session)
    and not plan_active(session)
    and not view.busy
  then
    kickoff()
  end
end

return M
